#!/bin/bash
set -euo pipefail

einfo() { echo ">>> $*"; }
ewarn() { echo "!!! $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

must_be_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Run as root (sudo su -)."
  fi
}

target_user() {
  local u="${TARGET_USER:-${SUDO_USER:-}}"
  [[ -z "$u" ]] && u="$(logname 2>/dev/null || true)"
  [[ -z "$u" ]] && die "Could not determine target user; set TARGET_USER."
  echo "$u"
}

ensure_pkg() {
  # emerge quietly but fail on error
  emerge --quiet --noreplace --autounmask-continue=y "$@"
}

remove_desktops() {
  einfo "Removing GNOME/KDE meta packages (best effort)"
  emerge --quiet --unmerge \
    gnome-base/gnome gnome-base/gdm gnome-shell gnome-extra/gnome-tweaks \
    gnome-extra/gnome-shell-extensions app-eselect/eselect-gnome-shell-extensions \
    kde-plasma/plasma-meta kde-apps/dolphin kde-plasma/sddm kde-plasma/kdeplasma-addons kde-apps/kdecore-meta \
    || ewarn "Unmerge returned non-zero; continuing"

  einfo "Depcleaning leftovers"
  emerge --quiet --depclean || ewarn "depclean returned non-zero; review manually"
}

install_base_packages() {
  einfo "Setting USE flag seatd:server"
  mkdir -p /etc/portage/package.use
  echo "sys-auth/seatd server" > /etc/portage/package.use/seatd

  local pkgs=(
    gui-wm/hyprland
    sys-auth/seatd
    x11-themes/papirus-icon-theme
    kde-frameworks/breeze-icons
    x11-themes/adwaita-icon-theme
    media-fonts/symbols-nerd-font
    x11-libs/xcb-util-cursor
  )
  ensure_pkg "${pkgs[@]}"
}

enable_seatd() {
  if command -v systemctl >/dev/null 2>&1; then
    # Create unit if missing (binary installed by seatd)
    if ! systemctl list-unit-files | grep -q '^seatd\.service'; then
      cat > /etc/systemd/system/seatd.service <<'UNIT'
[Unit]
Description=Seat management daemon (seatd)
After=local-fs.target
ConditionVirtualization=!container

[Service]
ExecStart=/usr/bin/seatd -g seat
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT
      systemctl daemon-reload
    fi
    systemctl enable --now seatd.service || ewarn "seatd enable failed"
  fi
}

add_groups() {
  local user="$1"
  for grp in seat video render; do
    getent group "$grp" >/dev/null || groupadd -r "$grp"
    id -nG "$user" | tr ' ' '\n' | grep -q "^$grp$" || gpasswd -a "$user" "$grp"
  done
}

sync_dots() {
  local user="$1" home dir src
  home="$(eval echo "~$user")"
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  einfo "Updating submodules"
  git -C "$dir" submodule update --init --recursive

  src="$dir/dots-hyperland/dots/.config"
  if [[ -d "$src" ]]; then
    einfo "Syncing Hyprland/Quickshell dots to $home/.config"
    rsync -a --delete "$src"/ "$home/.config/"
    chown -R "$user":"$user" "$home/.config"
    # Comment legacy window/layer rules that break recent Hyprland
    sed -i 's/^[[:space:]]*\(windowrulev\{0,1\}\|layerrule\)/# &/' "$home/.config/hypr/hyprland/rules.conf" 2>/dev/null || true
    sed -i '/border_color/d' "$home/.config/hypr/hyprland/colors.conf" 2>/dev/null || true
  else
    ewarn "dots-hyperland not found at $src; skipped config sync"
  fi
}

build_quickshell() {
  local user="$1" home dir
  home="$(eval echo "~$user")"
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if [[ ! -d "$dir/quickshell" ]]; then
    ewarn "quickshell submodule missing; skipping build"
    return
  fi

  einfo "Ensuring build deps for quickshell"
  ensure_pkg dev-build/meson dev-build/ninja dev-util/pkgconf dev-vcs/git \
    dev-qt/qtbase:6[wayland] dev-qt/qtdeclarative:6 dev-qt/qtwayland:6 \
    dev-qt/qtquickcontrols2:6 dev-qt/qt5compat:6

  if qlist -I | grep -q '^quickshell$'; then
    ewarn "Removing distro quickshell to avoid conflicts"
    emerge --quiet --unmerge quickshell || true
  fi

  einfo "Building quickshell from submodule"
  sudo -u "$user" bash -lc "cd '$dir/quickshell' && rm -rf build && meson setup --prefix=/usr --buildtype=release build && ninja -C build"
  ninja -C "$dir/quickshell/build" install
}

install_material_symbols() {
  local user="$1" home fonts
  home="$(eval echo "~$user")"
  fonts="$home/.local/share/fonts/material-symbols"
  mkdir -p "$fonts"
  einfo "Installing Material Symbols fonts locally for $user"
  sudo -u "$user" bash -lc "set -e; cd '$fonts'; \
    curl -L -f https://github.com/google/material-design-icons/raw/master/variablefont/MaterialSymbolsRounded%5BFILL,GRAD,opsz,wght%5D.ttf -o MaterialSymbolsRounded.ttf; \
    curl -L -f https://github.com/google/material-design-icons/raw/master/variablefont/MaterialSymbolsOutlined%5BFILL,GRAD,opsz,wght%5D.ttf -o MaterialSymbolsOutlined.ttf; \
    curl -L -f https://github.com/google/material-design-icons/raw/master/variablefont/MaterialSymbolsSharp%5BFILL,GRAD,opsz,wght%5D.ttf -o MaterialSymbolsSharp.ttf; \
    fc-cache -f '$home/.local/share/fonts'"
}

main() {
  must_be_root
  local user; user="$(target_user)"

  remove_desktops
  install_base_packages
  enable_seatd
  add_groups "$user"
  sync_dots "$user"
  build_quickshell "$user"
  install_material_symbols "$user"

  einfo "Done. Reboot or relogin as $user, then run ~/start.sh to launch the themed Hyprland."
}

main "$@"

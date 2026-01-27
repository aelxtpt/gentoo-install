#!/bin/bash
set -euo pipefail

# Ensure seatd + permissions + XDG runtime dir and start Hyprland with logging

if ! command -v emerge >/dev/null 2>&1; then
  echo "Run on Gentoo system." >&2; exit 1
fi

# 1) Install seatd if missing
mkdir -p /etc/portage/package.use
echo "sys-auth/seatd server" > /etc/portage/package.use/seatd
if ! qlist -I | grep -q '^sys-auth/seatd$'; then
  emerge --noreplace --quiet sys-auth/seatd
else
  emerge --quiet --newuse --noreplace sys-auth/seatd
fi

# 2) Enable seatd (systemd)
if command -v systemctl >/dev/null 2>&1; then
  if ! systemctl list-unit-files | grep -q '^seatd\.service'; then
    mkdir -p /etc/systemd/system
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
  systemctl enable --now seatd.service
fi

# 3) Add primary user to 'seat' group
user="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [ -z "$user" ]; then
  echo "Could not determine user" >&2; exit 1
fi
if ! getent group seat >/dev/null; then
  groupadd -r seat
fi
if ! id -nG "$user" | tr ' ' '\n' | grep -q '^seat$'; then
  gpasswd -a "$user" seat
fi

echo "Seatd set. Log out and back in (or reboot) for group change to apply."

echo "After relogin, start Hyprland with:" 
echo "  XDG_RUNTIME_DIR=/run/user/$(id -u "$user") Hyprland > ~/hyprland.log 2>&1"

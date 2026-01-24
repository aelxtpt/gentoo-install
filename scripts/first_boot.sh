# Standalone helpers (avoid relying on installer env)
set -euo pipefail

einfo() { echo ">>> $*"; }
ewarn() { echo "!!! $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }
file_exists() { [[ -e "$1" ]]; }
file_has_string() { grep -qF "$1" "$2" 2>/dev/null; }
append_if_missing() {
	local file="$1" line="$2"
	grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}
ask() {
	local prompt="$1"
	read -rp "$prompt (Y/n) " ans
	[[ -z "$ans" || "$ans" =~ ^[Yy] ]] && return 0
	return 1
}
try() { "$@" || die "Command failed: $*"; }
state_get() {
	local key="$1"
	local line
	line="$(grep -E "^${key}=" "$STATE_FILE" 2>/dev/null | tail -n1 || true)"
	echo "${line#*=}"
	return 0
}
state_set() {
	local key="$1" val="$2"
	mkdir -p "$STATE_DIR"
	echo "${key}=${val}" >> "$STATE_FILE"
}
stage_done() {
	local key="$1"
	[[ "$(state_get "$key")" == "done" ]]
}
mark_stage_done() {
	local key="$1"
	stage_done "$key" || state_set "$key" "done"
}
log_run() {
	local desc="$1"; shift
	local log="${FIRST_BOOT_LOG:-/tmp/first_boot.log}"
	touch "$log"
	chmod 600 "$log" || true
	einfo "$desc (log: $log; tail -f \"$log\" for live output)"
	("$@" 2>&1 | tee -a "$log"); return ${PIPESTATUS[0]}
}

kernel_config_path() {
	# Prefer the build tree config if present, then fall back to the running kernel.
	if [[ -r /usr/src/linux/.config ]]; then
		echo /usr/src/linux/.config
		return 0
	fi
	if [[ -r /proc/config.gz ]]; then
		echo /proc/config.gz
		return 0
	fi
	return 1
}

has_kernel_option() {
	local cfg="$1" opt="$2"
	if [[ "$cfg" == *.gz ]]; then
		zgrep -qE "^${opt}=|^# ${opt} " "$cfg" 2>/dev/null
	else
		grep -qE "^${opt}=|^# ${opt} " "$cfg" 2>/dev/null
	fi
}

kernel_option_value() {
	local cfg="$1" opt="$2"
	local line=""
	if [[ "$cfg" == *.gz ]]; then
		line="$(zgrep -E "^${opt}=" "$cfg" 2>/dev/null | head -n1 || true)"
	else
		line="$(grep -E "^${opt}=" "$cfg" 2>/dev/null | head -n1 || true)"
	fi
	echo "${line#*=}"
}

require_kernel_option() {
	local cfg="$1" opt="$2"; shift 2
	local allowed=("$@")
	if ! has_kernel_option "$cfg" "$opt"; then
		ewarn "Kernel option $opt not found; set it to one of: ${allowed[*]}"
		return 0
	fi
	local val
	val="$(kernel_option_value "$cfg" "$opt")"
	local ok=false
	local a
	for a in "${allowed[@]}"; do
		if [[ "$val" == "$a" ]]; then
			ok=true; break
		fi
	done
	if [[ "$ok" != true ]]; then
		ewarn "Kernel option $opt=$val, expected one of: ${allowed[*]}"
	fi
	return 0
}

forbid_kernel_option() {
	local cfg="$1" opt="$2"
	if has_kernel_option "$cfg" "$opt"; then
		local val
		val="$(kernel_option_value "$cfg" "$opt")"
		if [[ -n "$val" ]]; then
			ewarn "Kernel option $opt is enabled ($val); disable it for NVIDIA proprietary drivers."
		fi
	fi
	return 0
}

ACCEPT_LICENSE="*"
# Wayland-first (keep X for fallback)
PACKAGES_BASE="x11-base/xorg-drivers x11-base/xorg-server x11-drivers/nvidia-drivers media-video/pipewire media-video/wireplumber"
VIDEO_CARDS="nvidia"
USE="X suid xvmc nvidia pipewire pulseaudio egl wayland kms gbm opengl alsa"
INPUT_DEVICES="libinput"

DESKTOP_KDE_APPS=(kde-apps/ark kde-apps/dolphin kde-apps/kcalc kde-apps/konsole app-text/foliate www-client/firefox kde-plasma/plasma-nm kde-misc/latte-dock)
DESKTOP_GNOME_APPS=(www-client/firefox gnome-extra/gnome-tweaks)

QEMU_PACKAGES=("app-emulation/qemu app-emulation/libvirt net-misc/bridge-utils app-emulation/virt-manager app-emulation/virt-viewer app-emulation/spice-vdagent")

function tune_kernel_for_nvidia() {
	local cfg
	if ! cfg="$(kernel_config_path)"; then
		ewarn "Could not find kernel .config to tune for NVIDIA; skipping."
		return
	fi
	if [[ ! -x /usr/src/linux/scripts/config ]]; then
		ewarn "Missing /usr/src/linux/scripts/config; skipping kernel tweaks for NVIDIA."
		return
	fi

	einfo "Tuning kernel config for NVIDIA proprietary driver"
	(
		cd /usr/src/linux || exit 0
		set +e
		# Ensure module support and DRM helpers
		./scripts/config --enable MODULES || true
		./scripts/config --module DRM || true
		./scripts/config --module DRM_KMS_HELPER || true
		./scripts/config --module DRM_TTM || true
		./scripts/config --enable FB || true
		./scripts/config --enable FB_SIMPLE || true
		# Disable conflicting drivers
		./scripts/config --disable DRM_NOUVEAU || true
		./scripts/config --disable NOUVEAU || true
		./scripts/config --disable FB_NVIDIA || true
		# Settle deps
		make olddefconfig >/dev/null || true
	)

	# Report current status
	local cfg_after="/usr/src/linux/.config"
	require_kernel_option "$cfg_after" "CONFIG_MODULES" "y"
	require_kernel_option "$cfg_after" "CONFIG_DRM" "y" "m"
		require_kernel_option "$cfg_after" "CONFIG_DRM_KMS_HELPER" "y" "m"
		require_kernel_option "$cfg_after" "CONFIG_DRM_TTM" "y" "m"
	forbid_kernel_option "$cfg_after" "CONFIG_DRM_NOUVEAU"
	forbid_kernel_option "$cfg_after" "CONFIG_NOUVEAU"
	forbid_kernel_option "$cfg_after" "CONFIG_FB_NVIDIA"
}

function first_boot() {
	# Prepare log location
	FIRST_BOOT_LOG="${FIRST_BOOT_LOG:-/tmp/first_boot.log}"
	touch "$FIRST_BOOT_LOG" 2>/dev/null || true
	chmod 600 "$FIRST_BOOT_LOG" 2>/dev/null || true
	einfo "Logging detailed output to $FIRST_BOOT_LOG (tip: tail -f $FIRST_BOOT_LOG)"
	echo "=== $(date -u '+%F %T %Z') first_boot start ===" >> "$FIRST_BOOT_LOG"
	umask 0022

	STATE_DIR="/var/lib/gentoo-install"
	STATE_FILE="$STATE_DIR/first_boot.state"

	# Desktop choice
	local desktop_choice=""
	local prev_desktop
	prev_desktop="$(state_get desktop)"
	echo "Choose desktop environment:"
	echo "  1) KDE Plasma"
	echo "  2) GNOME"
	if [[ -n "$prev_desktop" ]]; then
		echo "Detected previous choice: $prev_desktop"
	fi
	read -rp "Select 1 or 2 (default: ${prev_desktop:-KDE}): " desktop_choice
	if [[ -z "$desktop_choice" ]]; then
		if [[ "$prev_desktop" == "gnome" ]]; then
			desktop_choice="gnome"
		else
			desktop_choice="kde"
		fi
	elif [[ "$desktop_choice" == "2" || "$desktop_choice" =~ ^[Gg] ]]; then
		desktop_choice="gnome"
	else
		desktop_choice="kde"
	fi
	einfo "Selected desktop: ${desktop_choice^^}"
	state_set desktop "$desktop_choice"

	# Show all profiles (avoid color parsing issues) and let the user pick.
	einfo "Available profiles:"
	eselect profile list || ewarn "Could not list profiles"
	read -rp "Choose profile number or name (blank to skip): " choice
	if [[ -n "${choice:-}" ]]; then
		einfo "Selecting profile $choice"
		if ! eselect profile set "$choice"; then
			ewarn "Failed to set profile '$choice'; leaving current profile unchanged."
		fi
	else
		ewarn "No profile selected; skipping profile selection."
	fi

	if ask "Add VIDEO_CARDS, USE, INPUT_DEVICES, ACCEPT_LICENSE to make.conf?"; then
		append_if_missing /etc/portage/make.conf "ACCEPT_LICENSE=\"$ACCEPT_LICENSE\"" \
			|| die "Could not add ACCEPT_LICENSE on /etc/portage/make.conf"
		append_if_missing /etc/portage/make.conf "USE=\"$USE\"" \
			|| die "Could not add USE on /etc/portage/make.conf"
		append_if_missing /etc/portage/make.conf "VIDEO_CARDS=\"$VIDEO_CARDS\"" \
			|| die "Could not add VIDEO_CARDS on /etc/portage/make.conf"
		append_if_missing /etc/portage/make.conf "INPUT_DEVICES=\"$INPUT_DEVICES\"" \
			|| die "Could not add INPUT_DEVICES on /etc/portage/make.conf"
	fi

	# because we copy from kernel_config/config and this file probrably has wrong permissions
	einfo "Resolving permissions on kernel src"
	chmod a+r /usr/src/linux

	einfo "Configuring PipeWire defaults"
	mkdir -p /etc/portage/package.use
	cat > /etc/portage/package.use/pipewire <<'EOF'
media-video/pipewire X pulseaudio sound-server pipewire-alsa
media-video/wireplumber systemd
media-libs/libcanberra alsa pulseaudio udev
media-plugins/alsa-plugins pulseaudio
EOF

# Break common circular dep between tiff<->libwebp seen with KDE/NVIDIA stacks.
	cat > /etc/portage/package.use/graphics <<'EOF'
media-libs/tiff -webp
media-libs/libwebp -tiff
EOF

tune_kernel_for_nvidia

	# Ensure kernel build artifacts are world-readable for module builds (nvidia, etc).
	if [[ -d /usr/src/linux ]]; then
		einfo "Relaxing permissions on kernel tree for module builds"
		# Need read + traverse for Portage user when building out-of-tree modules (e.g. NVIDIA).
		find -L /usr/src/linux -type d -exec chmod go+rx {} + 2>/dev/null || true
		# Executables need execute bits for portage (e.g. scripts/basic/fixdep).
		find -L /usr/src/linux -type f -perm -u=x -exec chmod go+rx {} + 2>/dev/null || true
		find -L /usr/src/linux -type f ! -perm -u=x -exec chmod go+r {} + 2>/dev/null || true
	fi

	einfo "Blacklisting nouveau and enabling nvidia-drm modeset"
	mkdir -p /etc/modprobe.d
	echo -e "blacklist nouveau\noptions nouveau modeset=0" > /etc/modprobe.d/blacklist-nouveau.conf
	echo "options nvidia-drm modeset=1" > /etc/modprobe.d/nvidia.conf
	mkdir -p /etc/modules-load.d
	cat > /etc/modules-load.d/nvidia.conf <<'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

	if stage_done kernel_rebuilt; then
		einfo "Skipping kernel rebuild (already done)"
	else
		einfo "Rebuilding kernel with NVIDIA settings"
		if [[ -x /usr/src/linux/compile_kernel.sh ]]; then
			try log_run "Building kernel via /usr/src/linux/compile_kernel.sh" /usr/src/linux/compile_kernel.sh
		else
			try log_run "Building kernel (manual fallback)" bash -c '
				cd /usr/src/linux || exit 1
				if [[ -n "${MAKEOPTS:-}" && "$MAKEOPTS" =~ -j([0-9]+) ]]; then
					jobs="${BASH_REMATCH[1]}"
				else
					jobs="$(nproc)"
				fi
				make -j"$jobs" || exit 1
				make modules_install || exit 1
				make INSTALLKERNEL=installkernel-gentoo install || exit 1
				kver="$(make kernelrelease)"
				mkdir -p /etc/dracut.conf.d
				tmp_confdir="$(mktemp -d /tmp/dracut-conf.XXXXXX)"
				trap '\''rm -rf "$tmp_confdir"'\'' EXIT
				dracut --conf /dev/null --confdir "$tmp_confdir" --kver "$kver" --hostonly --ro-mnt --force "/boot/initramfs-${kver}.img" || exit 1
				cp "/boot/initramfs-${kver}.img" /boot/initramfs.img || exit 1
				grub-mkconfig -o /boot/grub/grub.cfg || exit 1
			'
		fi
		mark_stage_done kernel_rebuilt
	fi

	einfo "Installing NVIDIA drivers and selecting GL/CL implementations"
	if stage_done nvidia_installed; then
		einfo "Skipping NVIDIA driver install (already done)"
	else
		try log_run "Installing NVIDIA drivers" emerge --verbose --noreplace x11-drivers/nvidia-drivers
		mark_stage_done nvidia_installed
	fi
	if command -v eselect >/dev/null 2>&1; then
		if eselect --list-modules 2>/dev/null | grep -qx opengl; then
			if eselect opengl list | grep -q nvidia; then
				eselect opengl set nvidia || true
			fi
		else
			ewarn "eselect module 'opengl' not available; skipping GL switch (libglvnd likely in use)."
		fi
		if eselect --list-modules 2>/dev/null | grep -qx opencl; then
			if eselect opencl list 2>/dev/null | grep -q nvidia; then
				eselect opencl set nvidia || true
			fi
		fi
	fi

	einfo "Writing Xorg NVIDIA config (fallback for X sessions)"
	mkdir -p /etc/X11/xorg.conf.d
	cat > /etc/X11/xorg.conf.d/10-nvidia.conf <<'EOF'
Section "OutputClass"
    Identifier "nvidia"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration" "yes"
    Option "PrimaryGPU" "yes"
EndSection
EOF

	einfo "Setting desktop packages"
	if stage_done base_packages; then
		einfo "Skipping base desktop packages (already done)"
	else
		try log_run "Installing base desktop packages" emerge --noreplace $PACKAGES_BASE
		mark_stage_done base_packages
	fi

	if ask "Do you want update world set ?"; then
		einfo "Update world set"
		try log_run "Updating @world" emerge --update --deep --newuse @world
	fi

	if [[ "$desktop_choice" == "kde" ]]; then
		if stage_done desktop_kde; then
			einfo "Skipping KDE install (already done)"
		else
			einfo "Installing KDE Plasma"
			try log_run "Installing KDE Plasma" emerge --noreplace kde-plasma/plasma-meta kde-plasma/kdeplasma-addons

			einfo "Installing KDE desktop apps"
			try log_run "Installing KDE desktop apps" emerge --noreplace --autounmask-continue=y -- "${DESKTOP_KDE_APPS[@]}"

		    if ! file_exists ~/.xinitrc; then
		    	einfo "Create .xinitrc for Plasma (startx fallback)"
		    	touch ~/.xinitrc

		    	if ! file_has_string "#!/bin/sh" ~/.xinitrc; then
				    einfo "Add content to .xinitrc to start plasma"
				    echo "#!/bin/sh" >> ~/.xinitrc \
						|| die "Could not add content to .xinitrc"
					echo "exec dbus-launch --exit-with-session startplasma-x11" >> ~/.xinitrc \
						|| die "Could not add content to .xinitrc"
				fi
			fi
			mark_stage_done desktop_kde
		fi
	elif [[ "$desktop_choice" == "gnome" ]]; then
		if stage_done desktop_gnome; then
			einfo "Skipping GNOME install (already done)"
		else
			einfo "Installing GNOME"
			try log_run "Installing GNOME" emerge --noreplace gnome-base/gnome gnome-base/gdm

			einfo "Installing GNOME desktop apps"
			try log_run "Installing GNOME desktop apps" emerge --noreplace --autounmask-continue=y -- "${DESKTOP_GNOME_APPS[@]}"

			if command -v systemctl >/dev/null 2>&1; then
				einfo "Enabling GDM display manager"
				systemctl enable --now gdm || ewarn "Failed to enable gdm; please enable manually."
			fi

		    if ! file_exists ~/.xinitrc; then
		    	einfo "Create .xinitrc for GNOME (startx fallback)"
		    	touch ~/.xinitrc

		    	if ! file_has_string "#!/bin/sh" ~/.xinitrc; then
				    einfo "Add content to .xinitrc to start gnome-session"
				    echo "#!/bin/sh" >> ~/.xinitrc \
						|| die "Could not add content to .xinitrc"
					echo "exec dbus-launch --exit-with-session gnome-session" >> ~/.xinitrc \
						|| die "Could not add content to .xinitrc"
				fi
			fi
			mark_stage_done desktop_gnome
		fi
	fi

	if command -v systemctl >/dev/null 2>&1; then
		einfo "Enabling PipeWire for all users (systemd global user units)"
		systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service || true
	fi

	if ask "Do you want install Steam ?"; then
		if stage_done steam; then
			einfo "Skipping Steam (already done)"
		else
			einfo "Installing Steam"
			mkdir -p /etc/portage/package.accept_keywords
			try log_run "Installing steam overlay prerequisites" emerge --autounmask-continue=y --noreplace app-eselect/eselect-repository dev-vcs/git
			try eselect repository enable steam-overlay
			try log_run "Syncing repositories" emerge --sync

			if ! file_has_string "*/*::steam-overlay" /etc/portage/package.accept_keywords/steam-overlay; then
				einfo "Add steam overlay package to accept keywords"
				echo "*/*::steam-overlay" >> /etc/portage/package.accept_keywords/steam-overlay || die "Could not add steam overlay to accept_keywords"
			fi

			# Not working, need unmaskwrite and etc-update and it has circular conclict with ncurses....
			try log_run "Installing Steam launcher" bash -c 'emerge --autounmask-write=y --autounmask=y --noreplace games-util/steam-launcher && echo "-3\nyes\nyes" | etc-update && emerge USE="-ncurses" --noreplace games-util/steam-launcher && emerge USE="-gpm" --noreplace ncurses'
			mark_stage_done steam
		fi
	fi

	einfo "Preparing to install snapd"
	mkdir -p /etc/portage/package.use
	if ! file_has_string "sys-apps/systemd" /etc/portage/package.use/systemd; then
		echo "sys-apps/systemd policykit apparmor" >> /etc/portage/package.use/systemd || die "Could not add sys-apps/systemd pol... to package.use"
		echo "sys-libs/libseccomp static-libs" >> /etc/portage/package.use/systemd || die "Could not add sys-libs/libseccomp stat... to package.use"
	fi

	if stage_done systemd_apparmor; then
		einfo "Skipping systemd/apparmor install (already done)"
	else
		einfo "Installing system and apparmor"
		try log_run "Installing systemd and apparmor" emerge --autounmask-continue=y --noreplace sys-apps/systemd sys-apps/apparmor
		mark_stage_done systemd_apparmor
	fi

	einfo "Modifying grub bootloader"
	if ! file_has_string 'GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor"' /etc/default/grub; then
		echo 'GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor"' >> /etc/default/grub || die "Could not modify bootloader"
	fi

	einfo "Generating new config to grub"
	try grub-mkconfig -o /boot/grub/grub.cfg

	if stage_done snapd; then
		einfo "Skipping snapd install (already done)"
	else
		einfo "Installing snapd"
		try log_run "Installing snapd" emerge --autounmask-continue=y --noreplace app-containers/snapd
		mark_stage_done snapd
	fi

	if ! file_has_string "sys-fs/squashfs-tools" /etc/portage/package.use/squashtools; then
		einfo "Add flags to squashtools"
		echo "sys-fs/squashfs-tools lz4 lzma lzo xattr zstd" >> /etc/portage/package.use/squashtools || die "Could not modify package.use/squashtools"

		if stage_done squashfs; then
			einfo "Skipping squashfs-tools (already done)"
		else
			try log_run "Installing squashfs-tools" emerge --changed-use --deep sys-fs/squashfs-tools
			mark_stage_done squashfs
		fi

		einfo "Creating snap link on /snap"
		try ln -sf /var/lib/snapd/snap /snap
	fi

	einfo "Enabling snapd on systemd"
	systemctl enable --now snapd
	systemctl enable --now snapd.socket
	systemctl enable --now snapd.apparmor

	einfo "Reboot your system now and after execute ./install post_install"
}

function post_install() {

	einfo "Installing mailspring"
	try snap install mailspring

	einfo "Installing VLC"
	try snap install vlc

	einfo "Installing VSCode"
	try snap install code --classic

	einfo "Installing Postman"
	try snap install postman

	einfo "Installing discord"
	try snap install discord

	einfo "Installing OBS Studio"
	try snap install obs-studio

	einfo "Try install qemu"
	mkdir -p /etc/portage/package.use
	if ! file_has_string "app-emulation/qemu" /etc/portage/package.use/emulation; then
		echo "app-emulation/qemu spice usb pulseaudio usbredir vhost-net vhost-user-fs" >> /etc/portage/package.use/emulation
	fi

	try emerge --noreplace --autounmask-write=y --autounmask=y -- "${QEMU_PACKAGES[@]}"
	try echo "-3\nyes" | etc-update
	try emerge --noreplace -- "${QEMU_PACKAGES[@]}"
}

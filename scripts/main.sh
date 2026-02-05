# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Functions

function install_stage3() {
	[[ $# == 0 ]] || die "Too many arguments"

	prepare_installation_environment
	local stage="${INSTALL_RESUME_STAGE-}"
	local stage_rank
	stage_rank="$(install_state_rank "$stage")"

	if [[ "$stage_rank" -lt 1 ]]; then
		apply_disk_configuration
		write_install_state "disk_configured"
	else
		einfo "Skipping disk configuration (resume)"
	fi

	if [[ "$stage_rank" -lt 2 ]]; then
		download_stage3
		extract_stage3
		write_install_state "stage3_extracted"
	else
		einfo "Skipping stage3 extraction (resume)"
		mount_root
	fi
}

function configure_base_system() {
	einfo "Generating locales"
	echo "$LOCALES" > /etc/locale.gen \
		|| die "Could not write /etc/locale.gen"
	locale-gen \
		|| die "Could not generate locales"

	if [[ $SYSTEMD == "true" ]]; then
		einfo "Setting machine-id"
		systemd-machine-id-setup \
			|| die "Could not setup systemd machine id"

		# Set hostname
		einfo "Selecting hostname"
		echo "$HOSTNAME" > /etc/hostname \
			|| die "Could not write /etc/hostname"

		# Set keymap
		einfo "Selecting keymap"
		echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf \
			|| die "Could not write /etc/vconsole.conf"

		# Set locale
		einfo "Selecting locale"
		echo "LANG=$LOCALE" > /etc/locale.conf \
			|| die "Could not write /etc/locale.conf"

		einfo "Selecting timezone"
		rm -rf /etc/localtime
		ln -sf /usr/share/zoneinfo/America/Sao_Paulo /etc/localtime || die "Could not change /etc/localtime link"
	else
		# Set hostname
		einfo "Selecting hostname"
		sed -i "/hostname=/c\\hostname=\"$HOSTNAME\"" /etc/conf.d/hostname \
			|| die "Could not sed replace in /etc/conf.d/hostname"

		# Set timezone
		einfo "Selecting timezone"
		echo "$TIMEZONE" > /etc/timezone \
			|| die "Could not write /etc/timezone"
		try emerge -v --config sys-libs/timezone-data

		# Set keymap
		einfo "Selecting keymap"
		sed -i "/keymap=/c\\keymap=\"$KEYMAP\"" /etc/conf.d/keymaps \
			|| die "Could not sed replace in /etc/conf.d/keymaps"

		# Set locale
		einfo "Selecting locale"
		try eselect locale set "$LOCALE"
	fi

	# Update environment
	env_update
}

function configure_portage() {
	normalize_mirrors() {
		local mirrors="$1"
		# Remove trailing backslashes and quotes, compress whitespace.
		mirrors="$(sed -e 's/\\\\$//' <<< "$mirrors")"
		mirrors="${mirrors//\"/}"
		mirrors="$(tr '\n' ' ' <<< "$mirrors")"
		mirrors="$(sed -e 's/[[:space:]]\+/ /g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$mirrors")"
		echo -n "$mirrors"
	}

	# Prepare /etc/portage for autounmask
	mkdir_or_die 0755 "/etc/portage/package.use"
	touch_or_die 0644 "/etc/portage/package.use/zz-autounmask"
	mkdir_or_die 0755 "/etc/portage/package.keywords"
	touch_or_die 0644 "/etc/portage/package.keywords/zz-autounmask"
	ensure_portage_tmpdir

	local make_jobs
	if type nproc &>/dev/null; then
		make_jobs="$(nproc)"
	else
		make_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
	fi
	[[ -n "$make_jobs" ]] || make_jobs=1
	local makeopts="-j${make_jobs}"
	export MAKEOPTS="$makeopts"
	if grep -q "^MAKEOPTS=" /etc/portage/make.conf 2>/dev/null; then
		sed -i "s/^MAKEOPTS=.*/MAKEOPTS=\"$makeopts\"/" /etc/portage/make.conf \
			|| die "Could not update MAKEOPTS in /etc/portage/make.conf"
	else
		echo "MAKEOPTS=\"$makeopts\"" >> /etc/portage/make.conf \
			|| die "Could not add MAKEOPTS to /etc/portage/make.conf"
	fi

	if [[ $SELECT_MIRRORS == "true" ]]; then
		local mirror_cache_dir="/var/cache/gentoo-install"
		local mirror_cache_file="$mirror_cache_dir/gentoo_mirrors.conf"
		local repo_cache_dir="$GENTOO_INSTALL_REPO_DIR/.cache"
		local repo_cache_file="$repo_cache_dir/gentoo_mirrors.conf"
		local cached_mirrors=""
		local mirrors_line=""

		if [[ -s "$mirror_cache_file" ]]; then
			einfo "Using cached portage mirrors from $mirror_cache_file"
			cached_mirrors="$(normalize_mirrors "$(cat "$mirror_cache_file")")"
		elif [[ -s "$repo_cache_file" ]]; then
			einfo "Using cached portage mirrors from $repo_cache_file"
			cached_mirrors="$(normalize_mirrors "$(cat "$repo_cache_file")")"
		else
			mirrors_line="$(grep "^GENTOO_MIRRORS=" /etc/portage/make.conf | tail -n 1)"
			if [[ -n "$mirrors_line" ]]; then
				cached_mirrors="${mirrors_line#GENTOO_MIRRORS=}"
				cached_mirrors="${cached_mirrors%\"}"
				cached_mirrors="${cached_mirrors#\"}"
				cached_mirrors="$(normalize_mirrors "$cached_mirrors")"
				if [[ -n "$cached_mirrors" ]]; then
					einfo "Using existing GENTOO_MIRRORS from make.conf"
					mkdir_or_die 0755 "$mirror_cache_dir"
					echo "$cached_mirrors" > "$mirror_cache_file" \
						|| die "Could not write mirror cache to $mirror_cache_file"
					mkdir_or_die 0755 "$repo_cache_dir"
					echo "$cached_mirrors" > "$repo_cache_file" \
						|| die "Could not write mirror cache to $repo_cache_file"
				fi
			fi
		fi

		if [[ -n "$cached_mirrors" ]]; then
			if grep -q "^GENTOO_MIRRORS=" /etc/portage/make.conf 2>/dev/null; then
				sed -i "s|^GENTOO_MIRRORS=.*|GENTOO_MIRRORS=\"$cached_mirrors\"|" /etc/portage/make.conf \
					|| die "Could not update GENTOO_MIRRORS in /etc/portage/make.conf"
			else
				echo "GENTOO_MIRRORS=\"$cached_mirrors\"" >> /etc/portage/make.conf \
					|| die "Could not add GENTOO_MIRRORS to /etc/portage/make.conf"
			fi
		else
			einfo "Temporarily installing mirrorselect"
			try emerge --verbose --oneshot app-portage/mirrorselect

			einfo "Selecting fastest portage mirrors"
			mirrorselect_params=("-s" "4" "-b" "10")
			[[ $SELECT_MIRRORS_LARGE_FILE == "true" ]] \
				&& mirrorselect_params+=("-D")
			try mirrorselect "${mirrorselect_params[@]}"

			mirrors_line="$(grep "^GENTOO_MIRRORS=" /etc/portage/make.conf | tail -n 1)"
			if [[ -n "$mirrors_line" ]]; then
				local mirrors
				mirrors="${mirrors_line#GENTOO_MIRRORS=}"
				mirrors="${mirrors%\"}"
				mirrors="${mirrors#\"}"
				mirrors="$(normalize_mirrors "$mirrors")"
				mkdir_or_die 0755 "$mirror_cache_dir"
				echo "$mirrors" > "$mirror_cache_file" \
					|| die "Could not write mirror cache to $mirror_cache_file"
				mkdir_or_die 0755 "$repo_cache_dir"
				echo "$mirrors" > "$repo_cache_file" \
					|| die "Could not write mirror cache to $repo_cache_file"
			else
				ewarn "Mirrorselect did not update GENTOO_MIRRORS; skipping cache"
			fi
		fi

		einfo "Adding ~$GENTOO_ARCH to ACCEPT_KEYWORDS"
		echo "ACCEPT_KEYWORDS=\"~$GENTOO_ARCH\"" >> /etc/portage/make.conf \
			|| die "Could not modify /etc/portage/make.conf"
	fi
}

function install_sshd() {
	einfo "Installing openssh (sshd)"
	try emerge --verbose net-misc/openssh

	einfo "Generating SSH host keys"
	try ssh-keygen -A

	einfo "Configuring sshd for root password login"
	local sshd_config="/etc/ssh/sshd_config"
	touch "$sshd_config"
	if grep -q "^PermitRootLogin" "$sshd_config"; then
		sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' "$sshd_config"
	else
		echo "PermitRootLogin yes" >> "$sshd_config"
	fi
	if grep -q "^PasswordAuthentication" "$sshd_config"; then
		sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' "$sshd_config"
	else
		echo "PasswordAuthentication yes" >> "$sshd_config"
	fi
	if grep -q "^UsePAM" "$sshd_config"; then
		sed -i 's/^UsePAM.*/UsePAM yes/' "$sshd_config"
	else
		echo "UsePAM yes" >> "$sshd_config"
	fi

	einfo "Enabling sshd service"
	enable_service sshd

	mkdir_or_die 0700 "/root/"
	mkdir_or_die 0700 "/root/.ssh"

	if [[ -n "$ROOT_SSH_AUTHORIZED_KEYS" ]]; then
		einfo "Adding authorized keys for root"
		touch_or_die 0600 "/root/.ssh/authorized_keys"
		echo "$ROOT_SSH_AUTHORIZED_KEYS" > "$ROOT_HOME/.ssh/authorized_keys" \
			|| die "Could not add ssh key to /root/.ssh/authorized_keys"
	fi
}

function generate_initramfs() {
	local output="$1"

	# Generate initramfs
	einfo "Generating initramfs"

	# Ensure dracut config dirs exist (dracut expects them even if empty).
	mkdir_or_die 0755 "/etc/dracut.conf.d"
	local empty_confdir
	empty_confdir="$(mktemp -d /tmp/dracut-conf.XXXXXX)" \
		|| die "Could not create temporary dracut confdir"
	# Ensure we always remove the temp confdir.
	trap 'rm -rf "$empty_confdir"' RETURN

	local modules=()
	[[ $USED_RAID == "true" ]] \
		&& modules+=("mdraid")
	[[ $USED_LUKS == "true" ]] \
		&& modules+=("crypt crypt-gpg")
	[[ $USED_BTRFS == "true" ]] \
		&& modules+=("btrfs")
	[[ $USED_ZFS == "true" ]] \
		&& modules+=("zfs")

	local kver
	kver="$(readlink /usr/src/linux)" \
		|| die "Could not figure out kernel version from /usr/src/linux symlink."
	kver="${kver#linux-}"

	# Generate initramfs
	try dracut \
		--conf          "/dev/null" \
		--confdir       "$empty_confdir" \
		--kver          "$kver" \
		--hostonly \
		--ro-mnt \
		--add           "bash ${modules[*]}" \
		--force \
		"$output"
}

function get_cmdline() {
	local cmdline=("rd.vconsole.keymap=$KEYMAP_INITRAMFS")
	cmdline+=("${DISK_DRACUT_CMDLINE[@]}")

	if [[ $USED_ZFS != "true" ]]; then
		cmdline+=("root=UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")")
	fi

	echo -n "${cmdline[*]}"
}

function install_grub() {
	local grub_platform
	local grub_target
	grub_platform="$(get_grub_platform)"
	grub_target="$(get_grub_target)"

	# Avoid heavy themes on small EFI partitions; disable grub themes.
	mkdir_or_die 0755 "/etc/portage/package.use"
	echo "sys-boot/grub -themes" > /etc/portage/package.use/grub \
		|| die "Could not disable grub themes via package.use"

	# Add grub_platforms
	einfo "Adding GRUB_PLATFORMS to make.conf (platform: $grub_platform)"
	echo "GRUB_PLATFORMS=\"$grub_platform\"" >> /etc/portage/make.conf \
		|| die "Could not modify /etc/portage/make.conf"

	try emerge --verbose sys-boot/grub

	local boot_dir="/boot"
	if [[ $IS_EFI == "true" ]]; then
		mountpoint -q -- "$boot_dir" \
			|| die "/boot is not mounted; cannot install grub"
		ensure_boot_space "$boot_dir" 50
		einfo "Installing grub (EFI target: $grub_target)"
		try grub-install \
			--target="$grub_target" \
			--efi-directory="$boot_dir" \
			--bootloader-id=gentoo \
			--removable
	else
		boot_dir="/boot/bios"
		mountpoint -q -- "$boot_dir" \
			|| die "/boot/bios is not mounted; cannot install grub"
		ensure_boot_space "$boot_dir" 50
		einfo "Installing grub (BIOS target: $grub_target)"
		try grub-install \
			--target="$grub_target" \
			--boot-directory="$boot_dir"
	fi

	einfo "Configuring grub"
	try grub-mkconfig -o /boot/grub/grub.cfg

	[[ -s /boot/grub/grub.cfg ]] \
		|| die "grub.cfg was not created; aborting"

	if [[ $IS_EFI == "true" ]]; then
		local efi_vendor_loader=""
		local efi_fallback_loader=""
		case "${GENTOO_ARCH:-amd64}" in
			amd64) efi_vendor_loader="grubx64.efi";  efi_fallback_loader="/boot/EFI/BOOT/BOOTX64.EFI" ;;
			x86)   efi_vendor_loader="grubia32.efi"; efi_fallback_loader="/boot/EFI/BOOT/BOOTIA32.EFI" ;;
			arm64) efi_vendor_loader="grubaa64.efi"; efi_fallback_loader="/boot/EFI/BOOT/BOOTAA64.EFI" ;;
			arm)   efi_vendor_loader="grubarm.efi";  efi_fallback_loader="/boot/EFI/BOOT/BOOTARM.EFI" ;;
			*)     efi_vendor_loader="grubx64.efi";  efi_fallback_loader="/boot/EFI/BOOT/BOOTX64.EFI" ;;
		esac

		local vendor_loader="/boot/EFI/gentoo/$efi_vendor_loader"
		if [[ -e "$vendor_loader" ]] && [[ ! -e "$efi_fallback_loader" ]]; then
			einfo "Creating EFI fallback loader at $efi_fallback_loader"
			mkdir -p "$(dirname "$efi_fallback_loader")" \
				|| die "Could not create EFI fallback directory"
			cp "$vendor_loader" "$efi_fallback_loader" \
				|| die "Could not copy EFI fallback loader"
		fi

		if command -v efibootmgr &>/dev/null; then
			local boot_source boot_disk boot_partnum
			boot_source="$(findmnt -n -o SOURCE /boot)" || boot_source=""
			if [[ -n "$boot_source" ]]; then
				boot_disk="/dev/$(lsblk -no PKNAME "$boot_source" 2>/dev/null)"
				boot_partnum="$(lsblk -no PARTNUM "$boot_source" 2>/dev/null)"
			fi

			if [[ -n "$boot_disk" ]] && [[ -n "$boot_partnum" ]]; then
				einfo "Creating EFI boot entry for Gentoo ($boot_disk, part $boot_partnum)"
				try efibootmgr \
					-c \
					-d "$boot_disk" \
					-p "$boot_partnum" \
					-L "Gentoo" \
					-l "\\EFI\\gentoo\\$efi_vendor_loader"
			else
				ewarn "Could not determine boot disk/partition for efibootmgr; relying on fallback loader."
			fi
		else
			ewarn "efibootmgr not available; relying on fallback loader."
		fi
	fi
}

function ensure_boot_space() {
	local boot_dir="$1"
	local min_mb="${2:-100}"

	local free_mb
	free_mb="$(df -Pm "$boot_dir" 2>/dev/null | awk 'NR==2 {print $4}')" || free_mb=""
	if [[ -z "$free_mb" ]]; then
		ewarn "Could not determine free space on $boot_dir"
		return 0
	fi

	if [[ "$free_mb" -ge "$min_mb" ]]; then
		return 0
	fi

	ewarn "Low space on $boot_dir (${free_mb}MB free, need ${min_mb}MB). Cleaning old initramfs files."
	shopt -s nullglob
	local imgs=("$boot_dir"/initramfs-*.img "$boot_dir"/initramfs.img)
	local img
	for img in "${imgs[@]}"; do
		[[ -e "$img" ]] || continue
		rm -f -- "$img" || true
		free_mb="$(df -Pm "$boot_dir" 2>/dev/null | awk 'NR==2 {print $4}')" || free_mb=""
		if [[ -n "$free_mb" ]] && [[ "$free_mb" -ge "$min_mb" ]]; then
			break
		fi
	done
	shopt -u nullglob

	if [[ -n "$free_mb" ]] && [[ "$free_mb" -lt "$min_mb" ]]; then
		die "Not enough free space on $boot_dir (have ${free_mb}MB, need ${min_mb}MB)"
	fi
}

function generate_syslinux_cfg() {
	cat <<EOF
DEFAULT gentoo
PROMPT 0
TIMEOUT 0

LABEL gentoo
	LINUX ../vmlinuz-current
	APPEND initrd=../initramfs.img $(get_cmdline)
EOF
}

function install_kernel_bios() {
	try emerge --verbose sys-boot/syslinux

	# Link kernel to known name
	local kernel_file
	kernel_file="$(find "/boot" -name "vmlinuz-*" -printf '%f\n' | sort -V | tail -n 1)" \
		|| die "Could not list newest kernel file"

	cp "/boot/$kernel_file" "/boot/bios/vmlinuz-current" \
		|| die "Could copy kernel to /boot/bios/vmlinuz-current"

	# Generate initramfs
	generate_initramfs "/boot/bios/initramfs.img"

	# Install syslinux
	einfo "Installing syslinux"
	local biosdev
	biosdev="$(resolve_device_by_id "$DISK_ID_BIOS")" \
		|| die "Could not resolve device with id=$DISK_ID_BIOS"
	mkdir_or_die 0700 "/boot/bios/syslinux"
	try syslinux --directory syslinux --install "$biosdev"

	# Create syslinux.cfg
	generate_syslinux_cfg > /boot/bios/syslinux/syslinux.cfg \
		|| die "Could save generated syslinux.cfg"

	# Install syslinux MBR record
	einfo "Copying syslinux MBR record"
	local gptdev
	gptdev="$(resolve_device_by_id "${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}")" \
		|| die "Could not resolve device with id=${DISK_ID_PART_TO_GPT_ID[$DISK_ID_BIOS]}"
	try dd bs=440 conv=notrunc count=1 if=/usr/share/syslinux/gptmbr.bin of="$gptdev"
}

function install_kernel() {
	# Set defaults if not defined in config
	: "${KERNEL_CONFIG_SOURCE:=current}"
	: "${KERNEL_MAKE_JOBS:=$(nproc)}"

	# Install vanilla kernel
	einfo "Installing vanilla kernel and related tools"
	mkdir_or_die 0755 "/etc/portage/package.license"
	if ! grep -qx "sys-kernel/linux-firmware linux-fw-redistributable" /etc/portage/package.license/linux-firmware 2>/dev/null; then
		echo "sys-kernel/linux-firmware linux-fw-redistributable" >> /etc/portage/package.license/linux-firmware \
			|| die "Could not add linux-firmware license"
	fi
	try emerge --verbose sys-kernel/gentoo-sources sys-kernel/linux-firmware

	einfo "Setting kernel number"
	try eselect kernel set 1

	# Determine architecture-specific kernel config path
	local kernel_config_file="$GENTOO_INSTALL_REPO_DIR/kernel_config/config-${GENTOO_ARCH:-amd64}"

	# Copy kernel configuration based on selected source
	einfo "Configuring kernel (source: $KERNEL_CONFIG_SOURCE, arch: ${GENTOO_ARCH:-amd64})"
	case "$KERNEL_CONFIG_SOURCE" in
		current)
			if [[ -f /proc/config.gz ]]; then
				einfo "Extracting config from /proc/config.gz"
				try zcat /proc/config.gz > /usr/src/linux/.config
			elif [[ -f "/boot/config-$(uname -r)" ]]; then
				einfo "Copying config from /boot/config-$(uname -r)"
				try cp "/boot/config-$(uname -r)" /usr/src/linux/.config
			else
				ewarn "Running kernel config not found, falling back to provided"
				if [[ -f "$kernel_config_file" ]]; then
					try cp "$kernel_config_file" /usr/src/linux/.config
				else
					die "No kernel config available for architecture: ${GENTOO_ARCH:-amd64}"
				fi
			fi
			einfo "Running make olddefconfig for new kernel version"
			try cd /usr/src/linux && make olddefconfig
			;;
		provided)
			einfo "Using provided kernel config for ${GENTOO_ARCH:-amd64}"
			if [[ -f "$kernel_config_file" ]]; then
				try cp "$kernel_config_file" /usr/src/linux/.config
			else
				die "No kernel config available for architecture: ${GENTOO_ARCH:-amd64}"
			fi
			;;
		*)
			die "Invalid KERNEL_CONFIG_SOURCE: $KERNEL_CONFIG_SOURCE"
			;;
	esac
	try chmod 644 /usr/src/linux/.config

	einfo "Installing lzo lzop"
	try emerge --verbose lzo lzop

	einfo "Installing dracut"
	try emerge --verbose sys-kernel/dracut

	einfo "Compiling kernel with $KERNEL_MAKE_JOBS parallel jobs"
	try cd /usr/src/linux && make -j"$KERNEL_MAKE_JOBS" && make modules_install && make install

	local kver
	kver="$(cd /usr/src/linux && make kernelrelease)" \
		|| die "Could not determine kernel release"

	# Ensure kernel/initramfs filenames are versioned and symlinked
	if [[ $IS_EFI == "true" ]]; then
		mountpoint -q -- "/boot" \
			|| die "/boot is not mounted; cannot finalize kernel install"
	else
		mountpoint -q -- "/boot/bios" \
			|| die "/boot/bios is not mounted; cannot finalize kernel install"
	fi

	local boot_dir="/boot"
	local kernel_img="$boot_dir/vmlinuz-$kver"
	local initramfs_img="$boot_dir/initramfs-$kver.img"

	ensure_boot_space "$boot_dir" 100

	# Some installkernel implementations drop unversioned files; fix up names.
	if [[ ! -e "$kernel_img" ]]; then
		if [[ -e "$boot_dir/vmlinuz" ]]; then
			einfo "Renaming kernel to $kernel_img"
			cp "$boot_dir/vmlinuz" "$kernel_img" \
				|| die "Could not copy kernel to $kernel_img"
		else
			ewarn "Kernel image not found in /boot; grub may not detect it"
		fi
	fi
	if [[ -e "$kernel_img" ]]; then
		ln -sf "$(basename "$kernel_img")" "$boot_dir/vmlinuz" 2>/dev/null \
			|| cp "$kernel_img" "$boot_dir/vmlinuz"
	fi

	# Copy config for reference
	if [[ -e /usr/src/linux/.config ]]; then
		cp /usr/src/linux/.config "$boot_dir/config-$kver" || true
	fi

	# Generate initramfs and stable symlink
	generate_initramfs "$initramfs_img"
	if [[ -e "$initramfs_img" ]]; then
		ln -sf "$(basename "$initramfs_img")" "$boot_dir/initramfs.img" 2>/dev/null \
			|| cp "$initramfs_img" "$boot_dir/initramfs.img"
	fi

	# Drop a helper script for rebuilding kernels later.
	if [[ -f "$GENTOO_INSTALL_REPO_DIR/contrib/compile_kernel.sh" ]]; then
		cp "$GENTOO_INSTALL_REPO_DIR/contrib/compile_kernel.sh" /usr/src/linux/compile_kernel.sh \
			|| die "Could not install /usr/src/linux/compile_kernel.sh"
		chmod +x /usr/src/linux/compile_kernel.sh || true
	fi

	install_grub

	# Generate a valid fstab file
	generate_fstab

	# Install gentoolkit
	einfo "Installing gentoolkit"
	try emerge --verbose app-portage/gentoolkit

	# Install and enable sshd
	if [[ $INSTALL_SSHD == "true" ]]; then
		install_sshd
	fi

	if [[ $SYSTEMD != "true" ]]; then
		# Install and enable dhcpcd
		einfo "Installing dhcpcd"
		try emerge --verbose net-misc/dhcpcd

		enable_service dhcpcd
	fi

	if [[ $SYSTEMD == "true" ]]; then
		# Enable systemd networking and dhcp
		enable_service systemd-networkd
		enable_service systemd-resolved
		echo -en "[Match]\nName=en*\n\n[Network]\nDHCP=yes" > /etc/systemd/network/20-wired-dhcp.network \
			|| die "Could not write dhcp network config to '/etc/systemd/network/20-wired-dhcp.network'"
		chown root:systemd-network /etc/systemd/network/20-wired-dhcp.network \
			|| die "Could not change owner of '/etc/systemd/network/20-wired-dhcp.network'"
		chmod 640 /etc/systemd/network/20-wired-dhcp.network \
			|| die "Could not change permissions of '/etc/systemd/network/20-wired-dhcp.network'"
	fi

	# Install additional packages, if any.
	if [[ ${#ADDITIONAL_PACKAGES[@]} -gt 0 ]]; then
		einfo "Installing additional packages"
		# shellcheck disable=SC2086
		try emerge --verbose --autounmask-continue=y -- "${ADDITIONAL_PACKAGES[@]}"
	fi

	if ask "Do you want to assign a root password now?"; then
		try passwd root
		einfo "Root password assigned"
	else
		try passwd -d root
		ewarn "Root password cleared, set one as soon as possible!"
	fi

	einfo "Gentoo installation complete."
	[[ $USED_LUKS == "true" ]] \
		&& einfo "A backup of your luks headers can be found at '$LUKS_HEADER_BACKUP_DIR', in case you want to have a backup."
	einfo "You may now reboot your system."
}

function add_fstab_entry() {
	printf '%-46s  %-24s  %-6s  %-96s %s\n' "$1" "$2" "$3" "$4" "$5" >> /etc/fstab \
		|| die "Could not append entry to fstab"
}

function generate_fstab() {
	einfo "Generating fstab"
	install -m0644 -o root -g root "$GENTOO_INSTALL_REPO_DIR/contrib/fstab" /etc/fstab \
		|| die "Could not overwrite /etc/fstab"
	if [[ $USED_ZFS != "true" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_ROOT")" "/" "$DISK_ID_ROOT_TYPE" "$DISK_ID_ROOT_MOUNT_OPTS" "0 1"
	fi
	if [[ $IS_EFI == "true" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_EFI")" "/boot" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	else
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_BIOS")" "/boot/bios" "vfat" "defaults,noatime,fmask=0177,dmask=0077,noexec,nodev,nosuid,discard" "0 2"
	fi
	if [[ -n "${DISK_ID_SWAP:-}" ]]; then
		add_fstab_entry "UUID=$(get_blkid_uuid_for_id "$DISK_ID_SWAP")" "none" "swap" "defaults,discard" "0 0"
	fi
}

function main_install_gentoo_in_chroot() {
	[[ $# == 0 ]] || die "Too many arguments"

	# Remove the root password, making the account accessible for automated
	# tasks during the period of installation.
	einfo "Clearing root password"
	passwd -d root \
		|| die "Could not change root password"

	if [[ $IS_EFI == "true" ]]; then
		# Mount efi partition
		mount_efivars
		einfo "Mounting efi partition"
		mount_by_id "$DISK_ID_EFI" "/boot"
	else
		# Mount bios partition
		einfo "Mounting bios partition"
		mount_by_id "$DISK_ID_BIOS" "/boot/bios"
	fi

	ensure_portage_tmpdir

	# Sync portage
	einfo "Syncing portage tree"
	try emerge-webrsync

	# Configure basic system things like timezone, locale, ...
	configure_base_system

	# Prepare portage environment
	configure_portage

	# Install git (for git portage overlays)
	einfo "Installing git"
	try emerge --verbose dev-vcs/git

	if [[ "$PORTAGE_SYNC_TYPE" == "git" ]]; then
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		cat > /etc/portage/repos.conf/gentoo.conf <<EOF
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = $PORTAGE_GIT_MIRROR
auto-sync = yes
sync-depth = $([[ $PORTAGE_GIT_FULL_HISTORY == true ]] && echo -n 0 || echo -n 1)
sync-git-verify-commit-signature = yes
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
EOF
		chmod 644 /etc/portage/repos.conf/gentoo.conf \
			|| die "Could not change permissions of '/etc/portage/repos.conf/gentoo.conf'"
		rm -rf /var/db/repos/gentoo \
			|| die "Could not delete obsolete rsync gentoo repository"
		try emerge --sync
	else
		# Force a known-good rsync configuration
		mkdir_or_die 0755 "/etc/portage/repos.conf"
		cat > /etc/portage/repos.conf/gentoo.conf <<'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
EOF
		chmod 644 /etc/portage/repos.conf/gentoo.conf \
			|| die "Could not change permissions of '/etc/portage/repos.conf/gentoo.conf'"
		try emerge --sync
	fi

	# Install mdadm if we used raid (needed for uuid resolving)
	if [[ $USED_RAID == "true" ]]; then
		einfo "Installing mdadm"
		try emerge --verbose sys-fs/mdadm
	fi

	# Install cryptsetup if we used luks
	if [[ $USED_LUKS == "true" ]]; then
		einfo "Installing cryptsetup"
		try emerge --verbose sys-fs/cryptsetup
	fi

	# Install btrfs-progs if we used btrfs
	if [[ $USED_BTRFS == "true" ]]; then
		einfo "Installing btrfs-progs"
		try emerge --verbose sys-fs/btrfs-progs
	fi

	# Install zfs kernel module and tools if we used zfs
	if [[ $USED_ZFS == "true" ]]; then
		einfo "Installing zfs"
		try emerge --verbose sys-fs/zfs sys-fs/zfs-kmod

		einfo "Enabling zfs services"
		if [[ $SYSTEMD == "true" ]]; then
			systemctl enable zfs.target        || die "Could not enable zfs.target service"
			systemctl enable zfs-import-cache  || die "Could not enable zfs-import-cache service"
			systemctl enable zfs-mount         || die "Could not enable zfs-mount service"
			systemctl enable zfs-import.target || die "Could not enable zfs-import.target service"
		else
			rc-update add zfs-import boot   || die "Could not add zfs-import to boot services"
			rc-update add zfs-mount boot    || die "Could not add zfs-mount to boot services"
		fi
	fi

	# Install kernel and initramfs
	install_kernel
	write_install_state "chroot_complete"

}

function maybe_resume_install() {
	local state
	state="$(read_install_state)"
	[[ -n "$state" ]] || return 0

	ewarn "Detected previous install state: $state"
	if [[ "$state" == "chroot_complete" ]]; then
		if ask "Installation appears complete. Start over?"; then
			clear_install_state
		else
			die "Installation already completed."
		fi
	else
		if ask "Continue from the previous state?"; then
			INSTALL_RESUME_STAGE="$state"
		else
			clear_install_state
		fi
	fi
}


function main_install() {
	[[ $# == 0 ]] || die "Too many arguments"

	maybe_resume_install
	gentoo_umount
	install_stage3

	[[ $IS_EFI == "true" ]] \
		&& mount_efivars
	gentoo_chroot "$ROOT_MOUNTPOINT" "$GENTOO_INSTALL_REPO_BIND/install" __install_gentoo_in_chroot
}

function main_install_after_compile_kernel() {
	gentoo_chroot "$ROOT_MOUNTPOINT" "$GENTOO_INSTALL_REPO_BIND/install" __complete_install
}

function main_chroot() {
	# Skip if already mounted
	mountpoint -q -- "$1" \
		|| die "'$1' is not a mountpoint"

	gentoo_chroot "$@"
}

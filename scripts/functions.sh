# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1


################################################
# Architecture Detection and Mapping Functions

# Detect system architecture and return Gentoo arch name
function detect_architecture() {
	local arch
	arch="$(uname -m)"
	case "$arch" in
		x86_64|amd64)      echo "amd64" ;;
		aarch64|arm64)     echo "arm64" ;;
		i?86|x86)          echo "x86" ;;
		armv7*|armhf)      echo "arm" ;;
		*)                 die "Unsupported architecture: $arch" ;;
	esac
}

# Get GRUB platform for current architecture
function get_grub_platform() {
	case "${GENTOO_ARCH:-amd64}" in
		amd64) echo "efi-64" ;;
		arm64) echo "efi-arm64" ;;
		x86)   echo "efi-32" ;;
		arm)   echo "efi-arm" ;;
		*)     die "Unknown architecture for GRUB platform: $GENTOO_ARCH" ;;
	esac
}

# Get GRUB install target for current architecture
function get_grub_target() {
	case "${GENTOO_ARCH:-amd64}" in
		amd64) echo "x86_64-efi" ;;
		arm64) echo "arm64-efi" ;;
		x86)   echo "i386-efi" ;;
		arm)   echo "arm-efi" ;;
		*)     die "Unknown architecture for GRUB target: $GENTOO_ARCH" ;;
	esac
}

# Get QEMU system binary name for current architecture
function get_qemu_system() {
	case "${GENTOO_ARCH:-amd64}" in
		amd64) echo "qemu-system-x86_64" ;;
		arm64) echo "qemu-system-aarch64" ;;
		x86)   echo "qemu-system-i386" ;;
		arm)   echo "qemu-system-arm" ;;
		*)     die "Unknown architecture for QEMU: $GENTOO_ARCH" ;;
	esac
}

################################################
# Functions

function sync_time() {
	einfo "Syncing time"
	local ntp_servers=()
	local ntp_decl=""
	if ntp_decl="$(declare -p NTP_SERVERS 2>/dev/null)"; then
		if [[ $ntp_decl == "declare -a "* ]]; then
			ntp_servers=("${NTP_SERVERS[@]}")
		else
			read -r -a ntp_servers <<< "${NTP_SERVERS-}"
		fi
	fi

	if [[ ${#ntp_servers[@]} -eq 0 ]]; then
		ntp_servers=(br.pool.ntp.org pool.ntp.br)
	fi

	einfo "Using NTP servers: ${ntp_servers[*]}"
	local ntpd_cmd=(ntpd -g -q)
	ntpd_cmd+=("${ntp_servers[@]}")
	try "${ntpd_cmd[@]}"

	einfo "Current date: $(LANG=C date)"
	einfo "Writing time to hardware clock"
	hwclock --systohc --utc \
		|| die "Could not save time to hardware clock"
}

function ensure_pty_limit() {
	local desired=4096
	if [[ -w /proc/sys/kernel/pty/max ]]; then
		local current
		current="$(cat /proc/sys/kernel/pty/max 2>/dev/null || echo "")"
		if [[ -n "$current" ]] && [[ "$current" -lt "$desired" ]]; then
			einfo "Increasing PTY limit from $current to $desired"
			echo "$desired" > /proc/sys/kernel/pty/max \
				|| ewarn "Could not increase PTY limit"
		fi
	fi
}

function ensure_portage_tmpdir() {
	local tmpdir="/var/tmp/portage"
	mkdir -p "$tmpdir" \
		|| die "Could not create $tmpdir"

	if getent passwd portage &>/dev/null; then
		chown -R portage:portage "$tmpdir" \
			|| die "Could not set ownership on $tmpdir"
		chmod -R g+rwX "$tmpdir" \
			|| die "Could not set permissions on $tmpdir"
		chmod 2775 "$tmpdir" \
			|| die "Could not set permissions on $tmpdir"
	else
		chmod -R a+rwX "$tmpdir" \
			|| die "Could not set permissions on $tmpdir"
		chmod 1777 "$tmpdir" \
			|| die "Could not set permissions on $tmpdir"
	fi
}

function check_config() {
	[[ $KEYMAP =~ ^[0-9A-Za-z-]*$ ]] \
		|| die "KEYMAP contains invalid characters"

	if [[ "$SYSTEMD" == "true" ]]; then
		[[ "$STAGE3_BASENAME" == *systemd* ]] \
			|| die "Using systemd requires a systemd stage3 archive!"
	else
		[[ "$STAGE3_BASENAME" != *systemd* ]] \
			|| die "Using OpenRC requires a non-systemd stage3 archive!"
	fi

	# Check hostname per RFC1123
	local hostname_regex='^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$'
	[[ $HOSTNAME =~ $hostname_regex ]] \
		|| die "'$HOSTNAME' is not a valid hostname"

	[[ -n "${DISK_ID_ROOT:-}" ]] \
		|| die "You must assign DISK_ID_ROOT"
	[[ -n "${DISK_ID_EFI:-}" ]] || [[ -n "${DISK_ID_BIOS:-}" ]] \
		|| die "You must assign DISK_ID_EFI or DISK_ID_BIOS"

	[[ -n "${DISK_ID_BIOS:-}" ]] && [[ -z "${DISK_ID_TO_UUID[$DISK_ID_BIOS]:-}" ]] \
		&& die "Missing uuid for DISK_ID_BIOS, have you made sure it is used?"
	[[ -n "${DISK_ID_EFI:-}" ]] && [[ -z "${DISK_ID_TO_UUID[$DISK_ID_EFI]:-}" ]] \
		&& die "Missing uuid for DISK_ID_EFI, have you made sure it is used?"
	[[ -n "${DISK_ID_SWAP:-}" ]] && [[ -z "${DISK_ID_TO_UUID[$DISK_ID_SWAP]:-}" ]] \
		&& die "Missing uuid for DISK_ID_SWAP, have you made sure it is used?"
	[[ -n "${DISK_ID_ROOT:-}" ]] && [[ -z "${DISK_ID_TO_UUID[$DISK_ID_ROOT]:-}" ]] \
		&& die "Missing uuid for DISK_ID_ROOT, have you made sure it is used?"

	if [[ -n "${DISK_ID_EFI:-}" ]]; then
		IS_EFI=true
	else
		IS_EFI=false
	fi
}

function preprocess_config() {
	disk_configuration

	# Check encryption key if used
	[[ $USED_ENCRYPTION == "true" ]] \
		&& check_encryption_key

	check_config
}

function prepare_installation_environment() {
	einfo "Preparing installation environment"

	local needed_programs=(
		gpg
		hwclock
		lsblk
		ntpd
		partprobe
		python3
		sgdisk
		uuidgen
		wget
	)

	[[ $USED_BTRFS == "true" ]] \
		&& needed_programs+=(btrfs)
	[[ $USED_ZFS == "true" ]] \
		&& needed_programs+=(zfs)
	[[ $USED_RAID == "true" ]] \
		&& needed_programs+=(mdadm)
	[[ $USED_LUKS == "true" ]] \
		&& needed_programs+=(cryptsetup)

	# Check for existence of required programs
	check_has_programs "${needed_programs[@]}"

	# Sync time now to prevent issues later
	sync_time
	ensure_pty_limit
}

function check_encryption_key() {
	if [[ -z "${GENTOO_INSTALL_ENCRYPTION_KEY+set}" ]]; then
		elog "You have enabled encryption, but haven't specified a key in the environment variable GENTOO_INSTALL_ENCRYPTION_KEY."
		if ask "Do you want to enter an encryption key now?"; then
			local encryption_key_1
			local encryption_key_2

			while true; do
				flush_stdin
				IFS="" read -s -r -p "Enter encryption key: " encryption_key_1 \
					|| die "Error in read"
				echo

				[[ ${#encryption_key_1} -ge 8 ]] \
					|| { ewarn "Your encryption key must be at least 8 characters long."; continue; }

				flush_stdin
				IFS="" read -s -r -p "Repeat encryption key: " encryption_key_2 \
					|| die "Error in read"
				echo

				[[ "$encryption_key_1" == "$encryption_key_2" ]] \
					|| { ewarn "Encryption keys mismatch."; continue; }
				break
			done

			export GENTOO_INSTALL_ENCRYPTION_KEY="$encryption_key_1"
		else
			die "Please export GENTOO_INSTALL_ENCRYPTION_KEY with the desired key."
		fi
	fi

	[[ ${#GENTOO_INSTALL_ENCRYPTION_KEY} -ge 8 ]] \
		|| die "Your encryption key must be at least 8 characters long."
}

function add_summary_entry() {
	local parent="$1"
	local id="$2"
	local name="$3"
	local hint="$4"
	local desc="$5"

	local ptr
	case "$id" in
		"${DISK_ID_BIOS-__unused__}")  ptr="[1;32m← bios[m" ;;
		"${DISK_ID_EFI-__unused__}")   ptr="[1;32m← efi[m"  ;;
		"${DISK_ID_SWAP-__unused__}")  ptr="[1;34m← swap[m" ;;
		"${DISK_ID_ROOT-__unused__}")  ptr="[1;33m← root[m" ;;
		# \x1f characters compensate for printf byte count and unicode character count mismatch due to '←'
		*)                             ptr="[1;32m[m$(echo -e "\x1f\x1f")" ;;
	esac

	summary_tree[$parent]+=";$id"
	summary_name[$id]="$name"
	summary_hint[$id]="$hint"
	summary_ptr[$id]="$ptr"
	summary_desc[$id]="$desc"
}

function summary_color_args() {
	for arg in "$@"; do
		if [[ -n "${arguments[$arg]+x}" ]]; then
			printf '%-28s ' "[1;34m$arg[2m=[m${arguments[$arg]}"
		fi
	done
}

function disk_create_gpt() {
	local new_id="${arguments[new_id]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -n "${arguments[id]+x}" ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "gpt" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(gpt)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -n "${arguments[id]+x}" ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local ptuuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating new gpt partition table ($new_id) on $device_desc"
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device'"
	sgdisk -Z -U "$ptuuid" "$device" >/dev/null \
		|| die "Could not create new gpt partition table ($new_id) on '$device'"
	partprobe "$device"
}

function disk_create_partition() {
	local new_id="${arguments[new_id]}"
	local id="${arguments[id]}"
	local size="${arguments[size]}"
	local type="${arguments[type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "$id" "$new_id" "part" "($type)" "$(summary_color_args size)"
		return 0
	fi

	if [[ $size == "remaining" ]]; then
		arg_size=0
	else
		arg_size="+$size"
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"
	local partuuid="${DISK_ID_TO_UUID[$new_id]}"
	local extra_args=""
	case "$type" in
		'bios')  type='ef02' extra_args='--attributes=0:set:2';;
		'efi')   type='ef00' ;;
		'swap')  type='8200' ;;
		'raid')  type='fd00' ;;
		'luks')  type='8309' ;;
		'linux') type='8300' ;;
		*) ;;
	esac

	einfo "Creating partition ($new_id) with type=$type, size=$size on $device"
	# shellcheck disable=SC2086
	sgdisk -n "0:0:$arg_size" -t "0:$type" -u "0:$partuuid" $extra_args "$device" >/dev/null \
		|| die "Could not create new gpt partition ($new_id) on '$device' ($id)"
	partprobe "$device"
}

function disk_create_raid() {
	local new_id="${arguments[new_id]}"
	local level="${arguments[level]}"
	local name="${arguments[name]}"
	local ids="${arguments[ids]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "_$new_id" "raid$level" "" "$(summary_color_args name)"
		done

		add_summary_entry __root__ "$new_id" "raid$level" "" "$(summary_color_args name)"
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	local mddevice="/dev/md/$name"
	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating raid$level ($new_id) on $devices_desc"
	mdadm \
			--create "$mddevice" \
			--verbose \
			--homehost="$HOSTNAME" \
			--metadata=1.2 \
			--raid-devices="${#devices[@]}" \
			--uuid="$uuid" \
			--level="$level" \
			"${devices[@]}" \
		|| die "Could not create raid$level array '$mddevice' ($new_id) on $devices_desc"
}

function disk_create_luks() {
	local new_id="${arguments[new_id]}"
	local name="${arguments[name]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		if [[ -n "${arguments[id]+x}" ]]; then
			add_summary_entry "${arguments[id]}" "$new_id" "luks" "" ""
		else
			add_summary_entry __root__ "$new_id" "${arguments[device]}" "(luks)" ""
		fi
		return 0
	fi

	local device
	local device_desc=""
	if [[ -n "${arguments[id]+x}" ]]; then
		device="$(resolve_device_by_id "${arguments[id]}")"
		device_desc="$device ($id)"
	else
		device="${arguments[device]}"
		device_desc="$device"
	fi

	local uuid="${DISK_ID_TO_UUID[$new_id]}"

	einfo "Creating luks ($new_id) on $device_desc"
	cryptsetup luksFormat \
			--type luks2 \
			--uuid "$uuid" \
			--key-file <(echo -n "$GENTOO_INSTALL_ENCRYPTION_KEY") \
			--cipher aes-xts-plain64 \
			--hash sha512 \
			--pbkdf argon2id \
			--iter-time 4000 \
			--key-size 512 \
			--batch-mode \
			"$device" \
		|| die "Could not create luks on $device_desc"
	mkdir -p "$LUKS_HEADER_BACKUP_DIR" \
		|| die "Could not create luks header backup dir '$LUKS_HEADER_BACKUP_DIR'"
	local header_file="$LUKS_HEADER_BACKUP_DIR/luks-header-$id-${uuid,,}.img"
	[[ ! -e $header_file ]] \
		|| rm "$header_file" \
		|| die "Could not remove old luks header backup file '$header_file'"
	cryptsetup luksHeaderBackup "$device" \
			--header-backup-file "$header_file" \
		|| die "Could not backup luks header on $device_desc"
	cryptsetup open --type luks2 \
			--key-file <(echo -n "$GENTOO_INSTALL_ENCRYPTION_KEY") \
			"$device" "$name" \
		|| die "Could not open luks encrypted device $device_desc"
}

function disk_create_dummy() {
	local new_id="${arguments[new_id]}"
	local device="${arguments[device]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry __root__ "$new_id" "$device" "" ""
		return 0
	fi
}

function init_btrfs() {
	local device="$1"
	local desc="$2"
	mkdir -p /btrfs \
		|| die "Could not create /btrfs directory"
	mount "$device" /btrfs \
		|| die "Could not mount $desc to /btrfs"
	btrfs subvolume create /btrfs/root \
		|| die "Could not create btrfs subvolume /root on $desc"
	btrfs subvolume set-default /btrfs/root \
		|| die "Could not set default btrfs subvolume to /root on $desc"
	umount /btrfs \
		|| die "Could not unmount btrfs on $desc"
}

function disk_format() {
	local id="${arguments[id]}"
	local type="${arguments[type]}"
	local label="${arguments[label]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		add_summary_entry "${arguments[id]}" "__fs__${arguments[id]}" "${arguments[type]}" "(fs)" "$(summary_color_args label)"
		return 0
	fi

	local device
	device="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"

	einfo "Formatting $device ($id) with $type"
	wipefs --quiet --all --force "$device" \
		|| die "Could not erase previous file system signatures from '$device' ($id)"

	case "$type" in
		'bios'|'efi')
			if [[ -n "${arguments[label]+x}" ]]; then
				mkfs.vfat -F 32 -n "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.vfat -F 32 "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'swap')
			if [[ -n "${arguments[label]+x}" ]]; then
				mkswap -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkswap "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'ext4')
			if [[ -n "${arguments[label]+x}" ]]; then
				mkfs.ext4 -q -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.ext4 -q "$device" \
					|| die "Could not format device '$device' ($id)"
			fi
			;;
		'btrfs')
			if [[ -n "${arguments[label]+x}" ]]; then
				mkfs.btrfs -q -L "$label" "$device" \
					|| die "Could not format device '$device' ($id)"
			else
				mkfs.btrfs -q "$device" \
					|| die "Could not format device '$device' ($id)"
			fi

			init_btrfs "$device" "'$device' ($id)"
			;;
		*) die "Unknown filesystem type" ;;
	esac
}

# This function will be called when a custom zfs pool type has been chosen.
# $1: either 'true' or 'false' determining if the datasets should be encrypted
# $2: either 'false' or a value determining the dataset compression algorithm
# $3: a string describing all device paths (for error messages)
# $@: device paths
function format_zfs_standard() {
	local encrypt="$1"
	local compress="$2"
	local device_desc="$3"
	shift 3
	local devices=("$@")
	local extra_args=()

	einfo "Creating zfs pool on $devices_desc"

	if [[ "$compress" != false ]]; then
		extra_args+=(
			"-O" "compression=$compress"
			)
	fi

	local zfs_stdin=""
	if [[ "$encrypt" == true ]]; then
		extra_args+=(
			"-O" "encryption=aes-256-gcm"
			"-O" "keyformat=passphrase"
			"-O" "keylocation=prompt"
			)

		zfs_stdin="$GENTOO_INSTALL_ENCRYPTION_KEY"
	fi

	# dnodesize=legacy might be needed for GRUB2, but auto is preferred for xattr=sa.
	zpool create \
		-R "$ROOT_MOUNTPOINT" \
		-o ashift=12          \
		-O acltype=posix      \
		-O atime=off          \
		-O xattr=sa           \
		-O dnodesize=auto     \
		-O mountpoint=none    \
		-O canmount=noauto    \
		-O devices=off        \
		"${extra_args[@]}"    \
		rpool                 \
		"${devices[@]}"       \
			<<< "$zfs_stdin"  \
		|| die "Could not create zfs pool on $devices_desc"

	zfs create rpool/ROOT \
		|| die "Could not create zfs dataset 'rpool/ROOT'"
	zfs create -o mountpoint=/ rpool/ROOT/default \
		|| die "Could not create zfs dataset 'rpool/ROOT/default'"
	zpool set bootfs=rpool/ROOT/default rpool \
		|| die "Could not set zfs property bootfs on rpool"
}

function disk_format_zfs() {
	local ids="${arguments[ids]}"
	local pool_type="${arguments[pool_type]}"
	local encrypt="${arguments[encrypt]-false}"
	local compress="${arguments[compress]-false}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "zfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	if [[ "$pool_type" == "custom" ]]; then
		format_zfs_custom "$devices_desc" "${devices[@]}"
	else
		format_zfs_standard "$encrypt" "$compress" "$devices_desc" "${devices[@]}"
	fi
}

function disk_format_btrfs() {
	local ids="${arguments[ids]}"
	local label="${arguments[label]}"
	local raid_type="${arguments[raid_type]}"
	if [[ ${disk_action_summarize_only-false} == "true" ]]; then
		local id
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${ids//';'/ }; do
			add_summary_entry "$id" "__fs__$id" "btrfs" "(fs)" "$(summary_color_args label)"
		done
		return 0
	fi

	local devices_desc=""
	local devices=()
	local id
	local dev
	# Splitting is intentional here
	# shellcheck disable=SC2086
	for id in ${ids//';'/ }; do
		dev="$(resolve_device_by_id "$id")" \
			|| die "Could not resolve device with id=$id"
		devices+=("$dev")
		devices_desc+="$dev ($id), "
	done
	devices_desc="${devices_desc:0:-2}"

	wipefs --quiet --all --force "${devices[@]}" \
		|| die "Could not erase previous file system signatures from $devices_desc"

	# Collect extra arguments
	extra_args=()
	if [[ "${#devices}" -gt 1 ]] && [[ -n "${arguments[raid_type]+x}" ]]; then
		extra_args+=("-d" "$raid_type")
	fi

	if [[ -n "${arguments[label]+x}" ]]; then
		extra_args+=("-L" "$label")
	fi

	einfo "Creating btrfs on $devices_desc"
	mkfs.btrfs -q "${extra_args[@]}" "${devices[@]}" \
		|| die "Could not create btrfs on $devices_desc"

	init_btrfs "${devices[0]}" "btrfs array ($devices_desc)"
}

function apply_disk_action() {
	unset known_arguments
	unset arguments; declare -A arguments; parse_arguments "$@"
	case "${arguments[action]}" in
		'create_gpt')        disk_create_gpt       ;;
		'create_partition')  disk_create_partition ;;
		'create_raid')       disk_create_raid      ;;
		'create_luks')       disk_create_luks      ;;
		'create_dummy')      disk_create_dummy     ;;
		'format')            disk_format           ;;
		'format_zfs')        disk_format_zfs       ;;
		'format_btrfs')      disk_format_btrfs     ;;
		*) echo "Ignoring invalid action: ${arguments[action]}" ;;
	esac
}

function print_summary_tree_entry() {
	local indent_chars=""
	local indent="0"
	local d="1"
	local maxd="$((depth - 1))"
	while [[ $d -lt $maxd ]]; do
		if [[ ${summary_depth_continues[$d]} == "true" ]]; then
			indent_chars+='│ '
		else
			indent_chars+='  '
		fi
		indent=$((indent + 2))
		d="$((d + 1))"
	done
	if [[ $maxd -gt 0 ]]; then
		if [[ ${summary_depth_continues[$maxd]} == "true" ]]; then
			indent_chars+='├─'
		else
			indent_chars+='└─'
		fi
		indent=$((indent + 2))
	fi

	local name="${summary_name[$root]}"
	local hint="${summary_hint[$root]}"
	local desc="${summary_desc[$root]}"
	local ptr="${summary_ptr[$root]}"
	local id_name="[2m[m"
	if [[ $root != __* ]]; then
		if [[ $root == _* ]]; then
			id_name="[2m${root:1}[m"
		else
			id_name="[2m${root}[m"
		fi
	fi

	local align=0
	if [[ $indent -lt 33 ]]; then
		align="$((33 - indent))"
	fi

	elog "$indent_chars$(printf "%-${align}s %-47s %s" \
		"$name [2m$hint[m" \
		"$id_name $ptr" \
		"$desc")"
}

function print_summary_tree() {
	local root="$1"
	local depth="$((depth + 1))"
	local has_children=false

	if [[ -n "${summary_tree[$root]+x}" ]]; then
		local children="${summary_tree[$root]}"
		has_children=true
		summary_depth_continues[$depth]=true
	else
		summary_depth_continues[$depth]=false
	fi

	if [[ $root != __root__ ]]; then
		print_summary_tree_entry "$root"
	fi

	if [[ $has_children == "true" ]]; then
		local count
		count="$(tr ';' '\n' <<< "$children" | grep -c '\S')" \
			|| count=0
		local idx=0
		# Splitting is intentional here
		# shellcheck disable=SC2086
		for id in ${children//';'/ }; do
			idx="$((idx + 1))"
			[[ $idx == "$count" ]] \
				&& summary_depth_continues[$depth]=false
			print_summary_tree "$id"
			# separate blocks by newline
			[[ ${summary_depth_continues[0]} == "true" ]] && [[ $depth == 1 ]] && [[ $idx == "$count" ]] \
				&& elog
		done
	fi
}

function apply_disk_actions() {
	local param
	local current_params=()
	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param == ';' ]]; then
			apply_disk_action "${current_params[@]}"
			current_params=()
		else
			current_params+=("$param")
		fi
	done
}

function lsblk_pair_value() {
	local line="$1"
	local key="$2"
	local val
	val="${line#*$key=\"}"
	[[ $val == "$line" ]] && { echo -n ""; return; }
	val="${val%%\"*}"
	echo -n "$val"
}

function trim_whitespace() {
	local val="$1"
	val="${val#"${val%%[![:space:]]*}"}"
	val="${val%"${val##*[![:space:]]}"}"
	echo -n "$val"
}

function release_disk_users() {
	local device="$1"
	local lsblk_output
	lsblk_output="$(lsblk --all --paths --pairs --output NAME,TYPE,FSTYPE,MOUNTPOINTS --noheadings "$device")" \
		|| die "Error while executing lsblk for $device"

	local devs=()
	local mountpoints=()
	local lvm_devs=()
	local other_devs=()
	local line
	while IFS="" read -r line; do
		local name
		local type
		local fstype
		local mps
		name="$(lsblk_pair_value "$line" "NAME")"
		type="$(lsblk_pair_value "$line" "TYPE")"
		fstype="$(lsblk_pair_value "$line" "FSTYPE")"
		mps="$(lsblk_pair_value "$line" "MOUNTPOINTS")"

		[[ -z "$name" ]] && continue
		[[ "$name" == "$device" ]] && continue

		devs+=("$name")

		if [[ -n "$mps" ]]; then
			local mp
			local mps_list=()
			IFS=',' read -r -a mps_list <<< "$mps"
			for mp in "${mps_list[@]}"; do
				[[ -n "$mp" ]] && mountpoints+=("$mp")
			done
		fi

		if [[ "$type" == "lvm" ]]; then
			lvm_devs+=("$name")
		elif [[ "$type" == "crypt" || "$type" == "raid" || "$type" == "md" || "$type" == "dm" ]]; then
			other_devs+=("$name")
		fi
	done < <(printf '%s\n' "$lsblk_output")

	declare -A dev_map
	local dev
	for dev in "${devs[@]}"; do
		dev_map["$dev"]=true
		if [[ -e "$dev" ]]; then
			local resolved
			resolved="$(readlink -f "$dev" 2>/dev/null || true)"
			[[ -n "$resolved" ]] && dev_map["$resolved"]=true
		fi
	done

	local swap_devs=()
	if type swapon &>/dev/null; then
		local swap
		while IFS="" read -r swap; do
			[[ -z "$swap" ]] && continue
			if [[ -n "${dev_map[$swap]+x}" ]]; then
				swap_devs+=("$swap")
			fi
		done < <(swapon --noheadings --show=NAME 2>/dev/null || true)
	fi

	if [[ ${#mountpoints[@]} -eq 0 ]] \
		&& [[ ${#swap_devs[@]} -eq 0 ]] \
		&& [[ ${#lvm_devs[@]} -eq 0 ]] \
		&& [[ ${#other_devs[@]} -eq 0 ]]; then
		return 0
	fi

	ewarn "Target disk appears to be in use: $device"
	[[ ${#mountpoints[@]} -gt 0 ]] \
		&& ewarn "Mounted filesystems: ${mountpoints[*]}"
	[[ ${#swap_devs[@]} -gt 0 ]] \
		&& ewarn "Active swap devices: ${swap_devs[*]}"
	[[ ${#lvm_devs[@]} -gt 0 ]] \
		&& ewarn "LVM devices: ${lvm_devs[*]}"
	[[ ${#other_devs[@]} -gt 0 ]] \
		&& ewarn "Other mapped devices: ${other_devs[*]}"
	[[ ${#other_devs[@]} -gt 0 ]] \
		&& ewarn "Non-LVM mapped devices may need manual cleanup if partitioning fails."

	ask "Attempt to unmount and deactivate swap/LVM for $device?" \
		|| die "Aborted because target disk is in use."

	if [[ ${#mountpoints[@]} -gt 0 ]]; then
		local mp
		for mp in "${mountpoints[@]}"; do
			if type mountpoint &>/dev/null; then
				mountpoint -q -- "$mp" || continue
			fi
			umount "$mp" \
				|| die "Could not unmount $mp"
		done
	fi

	if [[ ${#swap_devs[@]} -gt 0 ]]; then
		local swap
		for swap in "${swap_devs[@]}"; do
			swapoff "$swap" \
				|| die "Could not disable swap on $swap"
		done
	fi

	if [[ ${#lvm_devs[@]} -gt 0 ]]; then
		declare -A lvm_dev_map
		local dev
		for dev in "${lvm_devs[@]}"; do
			lvm_dev_map["$dev"]=true
			if [[ -e "$dev" ]]; then
				local resolved
				resolved="$(readlink -f "$dev" 2>/dev/null || true)"
				[[ -n "$resolved" ]] && lvm_dev_map["$resolved"]=true
			fi
		done

		if type lvs &>/dev/null && type vgchange &>/dev/null; then
			declare -A vgs
			local vg_lv
			while IFS="" read -r vg_lv; do
				local vg
				local lvpath
				vg="$(trim_whitespace "${vg_lv%%|*}")"
				lvpath="$(trim_whitespace "${vg_lv#*|}")"
				[[ -z "$vg" || -z "$lvpath" ]] && continue
				if [[ -n "${lvm_dev_map[$lvpath]+x}" ]]; then
					vgs["$vg"]=true
				elif [[ -e "$lvpath" ]]; then
					local lvpath_resolved
					lvpath_resolved="$(readlink -f "$lvpath" 2>/dev/null || true)"
					[[ -n "$lvpath_resolved" ]] \
						&& [[ -n "${lvm_dev_map[$lvpath_resolved]+x}" ]] \
						&& vgs["$vg"]=true
				else
					continue
				fi
			done < <(lvs --noheadings --options vg_name,lv_path --separator '|' 2>/dev/null || true)

			local vg
			for vg in "${!vgs[@]}"; do
				vgchange -an "$vg" \
					|| die "Could not deactivate volume group $vg"
			done
		else
			ewarn "lvm2 tools not found; skipping vgchange"
		fi
	fi

	if [[ ${#lvm_devs[@]} -gt 0 ]] && type dmsetup &>/dev/null; then
		local dm
		for dm in "${lvm_devs[@]}"; do
			[[ -e "$dm" ]] || continue
			dmsetup remove -f "$dm" \
				|| die "Could not remove device mapper $dm"
		done
	fi

	partprobe "$device" \
		|| die "Could not re-read partition table on $device"
}

function prepare_disks_for_partitioning() {
	local param
	local current_params=()
	declare -A seen_devices
	for param in "${DISK_ACTIONS[@]}"; do
		if [[ $param == ';' ]]; then
			unset known_arguments
			unset arguments; declare -A arguments; parse_arguments "${current_params[@]}"
			if [[ ${arguments[action]-} == "create_gpt" ]]; then
				local device
				if [[ -n "${arguments[id]+x}" ]]; then
					device="$(resolve_device_by_id "${arguments[id]}")" \
						|| die "Could not resolve device with id=${arguments[id]}"
				else
					device="${arguments[device]}"
				fi
				if [[ -n "$device" ]] && [[ -z "${seen_devices[$device]+x}" ]]; then
					seen_devices["$device"]=true
					release_disk_users "$device"
				fi
			fi
			current_params=()
		else
			current_params+=("$param")
		fi
	done
}

function summarize_disk_actions() {
	elog "[1mCurrent lsblk output:[m"
	for_line_in <(lsblk \
		|| die "Error in lsblk") elog

	local disk_action_summarize_only=true
	declare -A summary_tree
	declare -A summary_name
	declare -A summary_hint
	declare -A summary_ptr
	declare -A summary_desc
	declare -A summary_depth_continues
	apply_disk_actions

	local depth=-1
	elog
	elog "[1mConfigured disk layout:[m"
	elog ────────────────────────────────────────────────────────────────────────────────
	elog "$(printf '%-26s %-28s %s' NODE ID OPTIONS)"
	elog ────────────────────────────────────────────────────────────────────────────────
	print_summary_tree __root__
	elog ────────────────────────────────────────────────────────────────────────────────
}

function apply_disk_configuration() {
	summarize_disk_actions

	ask "Do you really want to apply this disk configuration?" \
		|| die "Aborted"
	prepare_disks_for_partitioning
	countdown "Applying in " 5

	einfo "Applying disk configuration"
	apply_disk_actions

	einfo "Disk configuration was applied successfully"
	elog "[1mNew lsblk output:[m"
	for_line_in <(lsblk \
		|| die "Error in lsblk") elog
}

function mount_efivars() {
	# Skip if already mounted
	mountpoint -q -- "/sys/firmware/efi/efivars" \
		&& return

	# Mount efivars
	einfo "Mounting efivars"
	mount -t efivarfs efivarfs "/sys/firmware/efi/efivars" \
		|| die "Could not mount efivarfs"
}

function mount_by_id() {
	local dev
	local id="$1"
	local mountpoint="$2"

	# Skip if already mounted
	mountpoint -q -- "$mountpoint" \
		&& return

	# Mount device
	einfo "Mounting device with id=$id to '$mountpoint'"
	mkdir -p "$mountpoint" \
		|| die "Could not create mountpoint directory '$mountpoint'"
	dev="$(resolve_device_by_id "$id")" \
		|| die "Could not resolve device with id=$id"
	mount "$dev" "$mountpoint" \
		|| die "Could not mount device '$dev'"
}

function mount_root() {
	if [[ $USED_ZFS == "true" ]] && ! mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		die "Error: Expected zfs to be mounted under '$ROOT_MOUNTPOINT', but it isn't."
	else
		mount_by_id "$DISK_ID_ROOT" "$ROOT_MOUNTPOINT"
	fi
}

function bind_repo_dir() {
	# Use new location by default
	export GENTOO_INSTALL_REPO_DIR="$GENTOO_INSTALL_REPO_BIND"

	# Bind the repo dir to a location in /tmp,
	# so it can be accessed from within the chroot
	mountpoint -q -- "$GENTOO_INSTALL_REPO_BIND" \
		&& return

	# Mount root device
	einfo "Bind mounting repo directory"
	mkdir -p "$GENTOO_INSTALL_REPO_BIND" \
		|| die "Could not create mountpoint directory '$GENTOO_INSTALL_REPO_BIND'"
	mount --bind "$GENTOO_INSTALL_REPO_DIR_ORIGINAL" "$GENTOO_INSTALL_REPO_BIND" \
		|| die "Could not bind mount '$GENTOO_INSTALL_REPO_DIR_ORIGINAL' to '$GENTOO_INSTALL_REPO_BIND'"
}

function file_has_string() {
	local str="$1"
	local file_to_check="$2"

	if grep -q $str "$file_to_check"; then
		return 0 # true
	fi

	return 1 # false
}

function file_exists() {
	local file_to_check="$1"

	if test -f "$file_to_check"; then
        return 0 # true
    fi

    return 1 # false
}

function install_state_dir() {
	if [[ ${EXECUTED_IN_CHROOT-false} == "true" ]]; then
		echo -n "/.gentoo-install"
	else
		echo -n "$ROOT_MOUNTPOINT/.gentoo-install"
	fi
}

function install_state_file() {
	echo -n "$(install_state_dir)/state"
}

function install_state_rank() {
	case "$1" in
		'disk_configured')  echo -n 1 ;;
		'stage3_extracted') echo -n 2 ;;
		'chroot_complete')  echo -n 3 ;;
		*) echo -n 0 ;;
	esac
}

function mount_root_for_state() {
	if mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		echo -n "already"
		return 0
	fi

	local dev
	dev="$(resolve_device_by_id_safe "$DISK_ID_ROOT")" \
		|| return 1
	mkdir -p "$ROOT_MOUNTPOINT" \
		|| return 1
	mount "$dev" "$ROOT_MOUNTPOINT" \
		|| return 1
	echo -n "mounted"
}

function read_install_state() {
	local state_file
	state_file="$(install_state_file)"

	if [[ ${EXECUTED_IN_CHROOT-false} == "true" ]]; then
		[[ -f "$state_file" ]] && cat "$state_file"
		return 0
	fi

	local mount_state
	mount_state="$(mount_root_for_state)" \
		|| return 0

	[[ -f "$state_file" ]] && cat "$state_file"

	if [[ "$mount_state" == "mounted" ]]; then
		umount -l "$ROOT_MOUNTPOINT" || true
	fi
}

function write_install_state() {
	local stage="$1"
	local state_dir
	state_dir="$(install_state_dir)"

	if [[ ${EXECUTED_IN_CHROOT-false} != "true" ]]; then
		local mount_state
		mount_state="$(mount_root_for_state)" \
			|| { ewarn "Could not mount root to write install state"; return 0; }
	fi

	mkdir -p "$state_dir" \
		|| die "Could not create install state directory '$state_dir'"
	echo "$stage" > "$state_dir/state" \
		|| die "Could not write install state to '$state_dir/state'"

	if [[ ${EXECUTED_IN_CHROOT-false} != "true" ]] && [[ "$mount_state" == "mounted" ]]; then
		umount -l "$ROOT_MOUNTPOINT" || true
	fi
}

function clear_install_state() {
	local state_dir
	state_dir="$(install_state_dir)"

	if [[ ${EXECUTED_IN_CHROOT-false} == "true" ]]; then
		rm -rf "$state_dir"
		return 0
	fi

	local mount_state
	mount_state="$(mount_root_for_state)" \
		|| return 0

	rm -rf "$state_dir"

	if [[ "$mount_state" == "mounted" ]]; then
		umount -l "$ROOT_MOUNTPOINT" || true
	fi
}

function download_file() {
	local url="$1"
}

function download_stage3() {
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"

	local STAGE3_RELEASES="$GENTOO_MIRROR/releases/$GENTOO_ARCH/autobuilds/current-$STAGE3_BASENAME/"

	# Download upstream list of files
	CURRENT_STAGE3="$(download_stdout "$STAGE3_RELEASES")" \
		|| die "Could not retrieve list of tarballs"
	# Decode urlencoded strings
	CURRENT_STAGE3=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))' <<< "$CURRENT_STAGE3")
	# Parse output for correct filename
	CURRENT_STAGE3="$(grep -o "\"${STAGE3_BASENAME}-[0-9A-Z]*.tar.xz\"" <<< "$CURRENT_STAGE3" \
		| sort -u | head -1)" \
		|| die "Could not parse list of tarballs"
	# Strip quotes
	CURRENT_STAGE3="${CURRENT_STAGE3:1:-1}"
	# File to indiciate successful verification
	CURRENT_STAGE3_VERIFIED="${CURRENT_STAGE3}.verified"

	# Download file if not already downloaded
	if [[ -e $CURRENT_STAGE3_VERIFIED ]]; then
		einfo "$STAGE3_BASENAME tarball already downloaded and verified"
	else
		einfo "Downloading $STAGE3_BASENAME tarball"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}" "${CURRENT_STAGE3}"
		download "$STAGE3_RELEASES/${CURRENT_STAGE3}.DIGESTS.asc" "${CURRENT_STAGE3}.DIGESTS.asc"

		# Import gentoo keys
		#einfo "Importing gentoo gpg key"
		#local GENTOO_GPG_KEY="$TMP_DIR/gentoo-keys.gpg"
		#download "https://gentoo.org/.well-known/openpgpkey/hu/wtktzo4gyuhzu8a4z5fdj3fgmr1u6tob?l=releng" "$GENTOO_GPG_KEY" \
		#	|| die "Could not retrieve gentoo gpg key"
		# gpg --quiet --import < "$GENTOO_GPG_KEY" \
		# 	|| die "Could not import gentoo gpg key"

		# Verify DIGESTS signature
		#einfo "Verifying DIGEST.asc signature"
		# gpg --quiet --verify "${CURRENT_STAGE3}.DIGESTS.asc" \
		# 	|| die "Signature of '${CURRENT_STAGE3}.DIGESTS.asc' invalid!"

		# Check hashes

		# Create verification file in case the script is restarted
		touch_or_die 0644 "$CURRENT_STAGE3_VERIFIED"
	fi
}

function extract_stage3() {
	mount_root

	[[ -n $CURRENT_STAGE3 ]] \
		|| die "CURRENT_STAGE3 is not set"
	[[ -e "$TMP_DIR/$CURRENT_STAGE3" ]] \
		|| die "stage3 file does not exist"

	# Go to root directory
	cd "$ROOT_MOUNTPOINT" \
		|| die "Could not move to '$ROOT_MOUNTPOINT'"
	# Ensure the directory is empty
	find . -mindepth 1 -maxdepth 1 -not -name 'lost+found' -not -name '.gentoo-install' \
		| grep -q . \
		&& die "root directory '$ROOT_MOUNTPOINT' is not empty"

	# Extract tarball
	einfo "Extracting stage3 tarball"
	tar xpf "$TMP_DIR/$CURRENT_STAGE3" --xattrs --numeric-owner \
		|| die "Error while extracting tarball"
	cd "$TMP_DIR" \
		|| die "Could not cd into '$TMP_DIR'"
}

function gentoo_umount() {
	if mountpoint -q -- "$ROOT_MOUNTPOINT"; then
		einfo "Unmounting root filesystem"
		umount -R -l "$ROOT_MOUNTPOINT" \
			|| die "Could not unmount filesystems"
	fi
}

function init_bash() {
	source /etc/profile
	umask 0077
	export PS1='(chroot) \[[0;31m\]\u\[[1;31m\]@\h \[[1;34m\]\w \[[m\]\$ \[[m\]'
}; export -f init_bash

function env_update() {
	env-update \
		|| die "Error in env-update"
	source /etc/profile \
		|| die "Could not source /etc/profile"
	umask 0077
}

function mkdir_or_die() {
	# shellcheck disable=SC2174
	mkdir -m "$1" -p "$2" \
		|| die "Could not create directory '$2'"
}

function touch_or_die() {
	touch "$2" \
		|| die "Could not touch '$2'"
	chmod "$1" "$2"
}

# $1: root directory
# $@: command...
function gentoo_chroot() {
	if [[ $# -eq 1 ]]; then
		einfo "To later unmount all virtual filesystems, simply use umount -l ${1@Q}"
		gentoo_chroot "$1" /bin/bash --init-file <(echo 'init_bash')
	fi

	[[ ${EXECUTED_IN_CHROOT-false} == "false" ]] \
		|| die "Already in chroot"

	local chroot_dir="$1"
	shift

	# Bind repo directory to tmp
	bind_repo_dir

	# Copy resolv.conf
	einfo "Preparing chroot environment"
	install --mode=0644 /etc/resolv.conf "$chroot_dir/etc/resolv.conf" \
		|| die "Could not copy resolv.conf"

	# Mount virtual filesystems
	einfo "Mounting virtual filesystems"
	(
		mountpoint -q -- "$chroot_dir/proc" || mount -t proc /proc "$chroot_dir/proc" || exit 1
		mountpoint -q -- "$chroot_dir/tmp"  || mount --rbind /tmp  "$chroot_dir/tmp"  || exit 1
		mountpoint -q -- "$chroot_dir/sys"  || {
			mount --rbind /sys  "$chroot_dir/sys" &&
			mount --make-rslave "$chroot_dir/sys"; } || exit 1
		mountpoint -q -- "$chroot_dir/dev"  || {
			mount --rbind /dev  "$chroot_dir/dev" &&
			mount --make-rslave "$chroot_dir/dev"; } || exit 1
	) || die "Could not mount virtual filesystems"

	# Cache lsblk output, because it doesn't work correctly in chroot (returns almost no info for devices, e.g. empty uuids)
	cache_lsblk_output

	# Execute command
	einfo "Chrooting..."
	EXECUTED_IN_CHROOT=true \
		TMP_DIR="$TMP_DIR" \
		CACHED_LSBLK_OUTPUT="$CACHED_LSBLK_OUTPUT" \
		exec chroot -- "$chroot_dir" "$GENTOO_INSTALL_REPO_DIR/scripts/dispatch_chroot.sh" "$@" \
			|| die "Failed to chroot into '$chroot_dir'."
}

function enable_service() {
	if [[ $SYSTEMD == "true" ]]; then
		systemctl enable "$1" \
			|| die "Could not enable $1 service"
	else
		rc-update add "$1" default \
			|| die "Could not add $1 to default services"
	fi
}

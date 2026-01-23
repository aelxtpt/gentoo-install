#!/bin/bash
# Helper to rebuild and install the current kernel from /usr/src/linux.
# We rely on dracut to generate the initramfs because it handles our root/LUKS/btrfs
# setups and matches what the installer uses. Keep this in /usr/src/linux so you
# can run it right after a make menuconfig.
# Usage: (optional) JOBS=8 ./compile_kernel.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root." >&2
	exit 1
fi

cd /usr/src/linux || { echo "Missing /usr/src/linux"; exit 1; }

# Ensure /boot is mounted.
if ! mountpoint -q /boot && [[ -d /boot ]]; then
	echo "Mounting /boot..."
	if [[ -b /dev/disk/by-label/efi ]]; then
		mount /dev/disk/by-label/efi /boot 2>/dev/null || true
	fi
fi
if ! mountpoint -q /boot; then
	echo "ERROR: /boot is not mounted. Please mount it and retry." >&2
	exit 1
fi

# Choose parallelism.
JOBS="${JOBS:-}"
if [[ -z "$JOBS" ]]; then
	# Derive from MAKEOPTS if set, otherwise nproc.
	if [[ -n "${MAKEOPTS:-}" ]] && [[ "$MAKEOPTS" =~ -j([0-9]+) ]]; then
		JOBS="${BASH_REMATCH[1]}"
	else
		JOBS="$(nproc)"
	fi
fi

echo "Building kernel with $JOBS jobs..."
make -j"$JOBS"
make modules_install
make install

kver="$(make kernelrelease)"
echo "Kernel release: $kver"

# Build initramfs.
echo "Generating initramfs..."
mkdir -p /etc/dracut.conf.d
tmp_confdir="$(mktemp -d /tmp/dracut-conf.XXXXXX)"
trap 'rm -rf "$tmp_confdir"' EXIT
dracut \
	--conf /dev/null \
	--confdir "$tmp_confdir" \
	--kver "$kver" \
	--hostonly \
	--ro-mnt \
	--force \
	"/boot/initramfs-${kver}.img"
cp "/boot/initramfs-${kver}.img" /boot/initramfs.img

echo "Updating grub configuration..."
grub-mkconfig -o /boot/grub/grub.cfg

echo "Done. Installed kernel: $kver"

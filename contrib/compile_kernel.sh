#!/bin/bash
# Helper to rebuild and install the current kernel from /usr/src/linux.
# We rely on dracut to generate the initramfs because it handles our root/LUKS/btrfs
# setups and matches what the installer uses. Keep this in /usr/src/linux so you
# can run it right after a make menuconfig.
# Usage: (optional) JOBS=8 ./compile_kernel.sh

set -euo pipefail
umask 0022

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

echo "Building kernel image and modules with $JOBS jobs..."
make -j"$JOBS"
kver="$(make -s kernelrelease)"
echo "Kernel release: $kver"
make modules_install

# Manually install the artifacts to /boot to avoid relying on installkernel.
bzImage="arch/x86/boot/bzImage"
if [[ ! -f "$bzImage" ]]; then
	echo "ERROR: missing $bzImage after build" >&2
	exit 1
fi
echo "Installing kernel to /boot..."
install -m644 "$bzImage" "/boot/vmlinuz-${kver}"
ln -sf "vmlinuz-${kver}" /boot/vmlinuz
install -m644 System.map "/boot/System.map-${kver}"
install -m644 .config "/boot/config-${kver}"

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
ln -sf "initramfs-${kver}.img" /boot/initramfs.img

echo "Updating grub configuration..."
if command -v grub-mkconfig >/dev/null; then
	grub-mkconfig -o /boot/grub/grub.cfg
else
	echo "WARNING: grub-mkconfig not found; please update bootloader manually." >&2
fi

echo "Done. Installed kernel: $kver"

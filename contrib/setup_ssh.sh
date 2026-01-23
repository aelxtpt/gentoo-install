#!/bin/bash
# Simple helper to install and enable OpenSSH with root login by password.
# Use with caution: root login with password is insecure on exposed networks.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root." >&2
	exit 1
fi

echo "Installing OpenSSH server..."
emerge --verbose --noreplace net-misc/openssh

echo "Configuring sshd for root password login..."
sshd_config="/etc/ssh/sshd_config"
mkdir -p /etc/ssh
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

echo "Enabling and starting sshd..."
systemctl enable --now sshd

echo "Done. Root password login over SSH is now enabled."

# Display IP addresses for convenience
echo "IP addresses:"
hostname -I || ip -4 addr show | awk '/inet / {print $2}'

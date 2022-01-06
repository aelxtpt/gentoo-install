# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

ACCEPT_LICENSE="*"
PACKAGES="x11-base/xorg-drivers x11-base/xorg-server x11-drivers/nvidia-drivers media-sound/pulseaudio"
VIDEO_CARDS="intel nvidia"
USE="X suid xvmc nvidia pulseaudio"
INPUT_DEVICES="libinput"

DESKTOP_APPS=("kde-apps/ark kde-apps/dolphin kde-apps/dolphin-plugins-git kde-apps/kalgebra kde-apps/kcalc kde-apps/konsole kde-apps/kde-dev-utils kde-apps/kmouth kde-apps/kmplot kde-apps/kompare kde-apps/krdc kde-apps/spectacle app-text/foliate www-client/firefox kde-apps/filelight kde-plasma/plasma-nm kde-misc/latte-dock")

QEMU_PACKAGES=("app-emulation/qemu app-emulation/libvirt net-misc/bridge-utils app-emulation/virt-manager app-emulation/virt-viewer app-emulation/spice-vdagent")

function first_boot() {
	einfo "Selecting profile default/linux/amd64/17.1/desktop/plasma/systemd"
    try eselect profile set default/linux/amd64/17.1/desktop/plasma/systemd

    if ask "I Should add VIDEO_CARDS, USE, INPUT_DEVICES, ACCEPT_LICENSE on make.conf ?"; then
    	echo "ACCEPT_LICENSE=\"$ACCEPT_LICENSE\"" >> /etc/portage/make.conf \
			|| die "Could not add ACCEPT_LICENSE on /etc/portage/make.conf"
		echo "USE=\"$USE\"" >> /etc/portage/make.conf \
			|| die "Could not add USE on /etc/portage/make.conf"
		echo "VIDEO_CARDS=\"$VIDEO_CARDS\"" >> /etc/portage/make.conf \
			|| die "Could not add VIDEO_CARDS on /etc/portage/make.conf"
		echo "INPUT_DEVICES=\"$INPUT_DEVICES\"" >> /etc/portage/make.conf \
			|| die "Could not add INPUT_DEVICES on /etc/portage/make.conf"
	fi

	# because we copy from kernel_config/config and this file probrably has wrong permissions
	einfo "Resolving permissions on kernel src"
	chmod a+r /usr/src/linux

    einfo "Setting desktop packages"
    try emerge --noreplace $PACKAGES

    if ask "Do you want update world set ?"; then
		einfo "Update world set"
    	try emerge --update --deep --newuse @world
	fi

    einfo "Installing KDE Plasma"
    try emerge --noreplace kde-plasma/plasma-meta kde-plasma/kdeplasma-addons

    einfo "Installing desktop apps"
    try emerge --noreplace --autounmask-continue=y -- "${DESKTOP_APPS[@]}"

    if ! file_exists ~/.xinitrc; then
    	einfo "Create .xinitrc"
    	touch ~/.xinitrc

    	if ! file_has_string "#!/bin/sh" ~/.xinitrc; then
		    einfo "Add content to .xinitrc to start plasma"
		    echo "#!/bin/sh" >> ~/.xinitrc \
				|| die "Could not add content to .xinitrc"
			echo "exec dbus-launch --exit-with-session startplasma-x11" >> ~/.xinitrc \
				|| die "Could not add content to .xinitrc"
		fi
	fi

	if ! file_exists /usr/src/linux/compile_kernel; then
		einfo "Generating script to compile kernel src"
		touch /usr/src/linux/compile_kernel

		if ! file_has_string "#!/bin/sh" /usr/src/linux/compile_kernel; then
			echo "#!/bin/sh" >> /usr/src/linux/compile_kernel || die "Could not add the content to compile_kernel"
			echo "make -j6 && make modules_install && make install" >> /usr/src/linux/compile_kernel || die "Could not add the content to compile_kernel"
			echo "emerge @module-rebuild" >> /usr/src/linux/compile_kernel || die "Could not add the content to compile_kernel"
			echo "grub-mkconfig -o /boot/grub/grub.cfg" >> /usr/src/linux/compile_kernel || die "Could not add the content to compile_kernel"
			chmod +x /usr/src/linux/compile_kernel
		fi
	fi

	if ask "Do you want install Steam ?"; then
		einfo "Installing Steam"
		try emerge --autounmask-continue=y --noreplace app-eselect/eselect-repository dev-vcs/git
		try eselect repository enable steam-overlay
		try emerge --sync

		if ! file_has_string "*/*::steam-overlay" /etc/portage/package.accept_keywords/steam-overlay; then
			einfo "Add steam overlay package to accept keywords"
			echo "*/*::steam-overlay" >> /etc/portage/package.accept_keywords/steam-overlay || die "Could not add steam overlay to accept_keywords"
		fi

		# Not working, need unmaskwrite and etc-update and it has circular conclict with ncurses....
		try emerge --autounmask-write=y --autounmask=y --noreplace games-util/steam-launcher && echo "-3\nyes\nyes" | etc-update && emerge USE="-ncurses" --noreplace games-util/steam-launcher && emerge USE="-gpm" --noreplace ncurses
	fi

	einfo "Preparing to install snapd"
	if ! file_has_string "sys-apps/systemd" /etc/portage/package.use/systemd; then
		echo "sys-apps/systemd policykit apparmor" >> /etc/portage/package.use/systemd || die "Could not add sys-apps/systemd pol... to package.use"
		echo "sys-libs/libseccomp static-libs" >> /etc/portage/package.use/systemd || die "Could not add sys-libs/libseccomp stat... to package.use"
	fi

	einfo "Installing system and apparmor"
	try emerge --autounmask-continue=y --noreplace sys-apps/systemd sys-apps/apparmor

	einfo "Modifying grub bootloader"
	if ! file_has_string 'GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor"' /etc/default/grub; then
		echo 'GRUB_CMDLINE_LINUX_DEFAULT="apparmor=1 security=apparmor"' >> /etc/default/grub || die "Could not modify bootloader"
	fi

	einfo "Generating new config to grub"
	try grub-mkconfig -o /boot/grub/grub.cfg

	einfo "Installing snapd"
	try emerge --autounmask-continue=y --noreplace app-containers/snapd

	if ! file_has_string "sys-fs/squashfs" /etc/portage/package.use/squashtools; then
		einfo "Add flags to squashtools"
		echo "sys-fs/squashfs-tools lz4 lzma lzo xattr zstd" >> /etc/portage/package.use/squashtools || die "Could not modify package.use/squashtools"

		try emerge --changed-use --deep sys-fs/squashfs-tools

		einfo "Creating snap link on /snap"
		try ln -s /var/lib/snapd/snap /snap
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
	if ! file_has_string "app-emulation/qemu" /etc/portage/package.use/emulation; then
		echo "app-emulation/qemu spice usb pulseaudio usbredir vhost-net vhost-user-fs" >> 
	fi

	try emerge --noreplace --autouunmask-write=y --autounmask=y -- "${QEMU_PACKAGES[@]}"
	try echo "-3\nyes" | etc-update
	try emerge --noreplace -- "${QEMU_PACKAGES[@]}"
}
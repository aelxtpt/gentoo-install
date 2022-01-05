# shellcheck source=./scripts/protection.sh
source "$GENTOO_INSTALL_REPO_DIR/scripts/protection.sh" || exit 1

ACCEPT_LICENSE="*"
PACKAGES="x11-base/xorg-drivers x11-base/xorg-server x11-drivers/nvidia-drivers"
VIDEO_CARDS="intel nvidia"
USE="X suid xvmc nvidia"
INPUT_DEVICES="libinput"

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

    einfo "Setting desktop packages"
    try emerge $PACKAGES

	einfo "Update world set"
    try emerge --update --deep --newuse @world
}
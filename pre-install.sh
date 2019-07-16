#!/usr/bin/env bash

# Exit on error. Append "|| true" if you expect an error.
set -o errexit
# Exit on error inside any functions or subshells.
set -o errtrace
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
set -o nounset
# Catch the error in case mysqldump fails (but gzip succeeds) in `mysqldump |gzip`
set -o pipefail
# Turn on traces, useful while debugging but commented out by default
# set -o xtrace

# trap to clean up
function cleanup_on_exit() {
	echo -e "\nExiting"
}
trap cleanup_on_exit 0

DEBUG=y

RD='\033[0;31m'
GR='\033[0;32m'
YL='\033[0;33m'
NC='\033[0m' # No Color

yell() { echo -e "$0: $*" >&2; }
die() { yell "$*"; exit 111; }
try() { "$@" || die "${RD}cannot $*${NC}"; }
function try_msg() {
	errmsg="${RD}$1${NC}"
	shift
	if [ "$DEBUG" == n ]; then
		"$@" || die "$errmsg"
	else
		status_warn " > # $*"
	fi
}

function status_good() {
	echo -e "${GR}$1${NC}"
}
function status_warn() {
	echo -e "${YL}$1${NC}"
}
function status_err() {
	echo -e "${RD}$1${NC}"
}


function prompt-cont() {
	echo -e -n "${YL}\t > Continue? [y/n] ${NC}" 
	read -r -n 1 choice
	echo -e ""
	case "$choice" in
		[yY] ) ;;
		* ) exit 1
	esac
}

function dangerous() {
	if [ "$DEBUG" == n ]; then
		status_warn " > # $*"; prompt-cont; try "$@"
	else
		status_warn " > # $*";
	fi
}

exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")


###############################################################################
##### START INSTALL
###############################################################################



# Check if booted into UEFI mode
echo "Checking if booted into UEFI mode"
if [ -d '/sys/firmware/efi/efivars' ] ; then
	status_good "Booted into UEFI mode"
else
	status_warn " > Potentially booted into BIOS mode"
	prompt-cont
fi


# Check network connection
echo -e "\nChecking network connection"
if [ "$(ping -c 3 archlinux.org)" ] ; then 
	status_good " > Network connection active"
else
	status_err " > Cannot connect to archlinux.org"
	exit 1
fi


# Update system clock
echo -e "\nUpdating system clock"
try_msg "Could not update system clock" timedatectl set-ntp true
status_good " > Clock updated"


###############################################################################
### Partition

echo -e '\n'
try_msg "Could not show partitions" parted -l
root_dev="/dev/sda"
if [ -e "/dev/nvme0n1" ]; then root_dev="/dev/nvme0n1"; fi
echo -en "\nFormat $root_dev for GPT? Manually partition? [y/n/m]"
choice=n
read -r -n 1 choice
echo ""
nvme_flag=""
if [[ "$root_dev" =~ "nvme" ]]; then nvme_flag=p; fi
case "$choice" in
	y|Y )
		dangerous parted "$root_dev" mklabel gpt
		dangerous parted --align optimal "$root_dev" mkpart boot fat32 0% 512MiB
		dangerous parted "$root_dev" set 1 esp on
		dangerous parted --align optimal  mkpart "$root_dev" home 512MiB 100%
		dangerous mkfs.fat -F32 "${root_dev}${nvme_flag}1"
		status_good " > Partitions created"
		;;
	[mM] )
		parted
		;;
	* )
		exit 1
esac


# drive encryption
echo -e '\n'
encrypt_flag=n
echo -en "${YL}Encrypt drive? [y/n] ${NC}"
read -r -n 1 encrypt_flag
case $encrypt_flag in
	[yY] )
		echo -en "\nSet partition for cryptroot (default /dev/sda2): "
		read -r choice
		crypt_part=${choice:-"/dev/sda2"}
		dangerous cryptsetup -y -v luksFormat "$crypt_part"
		try_msg "Could not open cryptroot" cryptsetup open "$crypt_part" cryptroot
		dangerous mkfs.btrfs -L cryptroot /dev/mapper/cryptroot
		try_msg "Could not mount cryptroot" mount /dev/mapper/cryptroot /mnt
		status_good " > cryptroot created on $crypt_part. Verifying"

		try_msg "Could not unmount" umount -R /mnt
		try_msg "Could not close cryptroot" cryptsetup close cryptroot
		try_msg "Could not open cryptroot" cryptsetup open "$crypt_part" cryptroot
		try_msg "Could not mount cryptroot" mount /dev/mapper/cryptroot /mnt
		status_good " > Verified cryptroot"
		status_good " > cryptroot mounted as root"
		;;
	[nN] ) 
		echo -en "\nSet partition for root (default /dev/sda2): "
		read -r choice
		root_part=${choice:-"/dev/sda2"}
		try_msg "Could not mount root" mount "$root_part" /mnt
		status_good " > $root_part mounted as root"
		;;
	* )
		exit 1
esac

# /mnt should be mounted, now mount boot
echo -en "\nSet partition for boot (default /dev/sda1): "
read -r choice
boot_part=${choice:-"/dev/sda1"}
try_msg "Could not make boot mount point" mkdir /mnt/boot
try_msg "Could not mount boot" mount "$boot_part" /mnt/boot
status_good " > boot mounted"

echo -e "\n\nSetup complete, ready for install\n"

###############################################################################
### pacstrap and install
###############################################################################

### I got lazy with this part, probably should fix it up a bit later

cat >>/etc/pacman.conf <<EOF
[spacedome]
SigLevel = Optional TrustAll
Server = file:///opt/spacedome
EOF

pacstrap /mnt spacedome-t470
genfstab -U /mnt >> /mnt/etc/fstab
echo "t470" > /mnt/etc/hostname

cat >>/mnt/etc/pacman.conf <<EOF
[spacedome]
SigLevel = Optional TrustAll
Server = file:///opt/spacedome
EOF
mkdir -p /mnt/opt/spacedome
cp -r /opt/spacedome /mnt/opt/spacedome

cat >>/mnt/etc/hosts <<EOF
127.0.0.1 t470
::1 t470
127.0.1.1 t470.home.spacedome.tv t470
EOF

"LANG=en_US.UTF-8" > /mnt/etc/locale.conf

cp mkinitcpio.conf /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux
arch-chroot /mnt passwd
arch-chroot /mnt refind-install
luks_uuid="$( lsblk -o UUID,FSTYPE $root_dev | grep LUKS | cut -d' ' -f1 )"
cat >>/mnt/boot/EFI/refind/refind.conf <<EOF
menuentry "Arch" {
	icon /EFI/refind/icons/os_arch.png
	volume "UUID of boot"
	leader /vmlinuz-linux
	initrd /initramfs-linux.img
	options "cryptdevice=UUID=${luks_uuid}:cryptroot:allow-discards root=/dev/mapper/cryptroot rw add_efi_memmap"
	submenuentry "Boot using fallback initramfs" {
		initrd /initramfs-linux-fallback.img
	}
	submenuentry "Boot to terminal" {
		add_options "systemd.unit=multi-user.target"
	}
}
EOF

arch-chroot /mnt useradd -mU -G wheel,users,uucp,video,audio,storage,input,log,sys,adm julien



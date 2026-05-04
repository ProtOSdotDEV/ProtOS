#!/bin/sh
# ProtOS instalrer script v.1.0 (working, need to add other functions such as my own version of pacstrap lmao)
set -e

echo "ProtOS NVMe Installer "

# identify the drive
DISK="/dev/nvme0n1"

if [! -b "$DISK" ]; then
    echo "ERROR: No NVMe primary controller found at $DISK"
fi

echo "Target drive: $DISK"
echo "WARNING: ALL DATA ON DRIVE $DRIVE IS BEING ERASED NOW."

# partition disk (NVMe) using sfdisk

echo "-> Partitioning..."
# layout:
# p1=EFI
# p2=swap
# p3=root
sfdisk "$DISK" <<END
label: gpt
,1G,U
,4G,S
,+,L
END

sleep 2
PART_EFI="${DISK}p1"
PART_SWAP="${DISK}p2"
PART_ROOT="${DISK}p3"

# formatting
echo "-> Formatting $DRIVE..."
mkfs.fat -F 32 "$PART_EFI"
mkswap "$PART_SWAP"
mkfs.ext4 "$PART_ROOT"

# turn on swap
echo "-> Turning on SWAP"
swapon "$PART_SWAP"

# verify changes
lsblk
sleep 2
clear
lsblk -lf
echo "Changes saved!"

# mount partitions
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

if [ ! ping -c 3 8.8.8.8 ]; then
    echo "No internet connection established, if this is an error or you have ethernet, run 'dhcpcd' with root priviledges"
    return 1
fi

ping -c 3 8.8.8.8

protopkg sync
sleep 2
protopkg install *

# install grub bootloader
# TODO: CREATE A "CHROOT" LIKE COMMAND (unless there already is one i dont remember)

grub install --target=aarch64 --efi-directory=/boot --removable --bootloader-id=GRUB
sleep 3
ls /boot/Image 
cp /boot/Image /boot/vmlinuz-linux 
grub mkconfig -o /boot/grub/grub.cfg



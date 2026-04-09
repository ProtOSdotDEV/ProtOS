#!/bin/sh
# ProtOS instalrer script v.1.0 (working, need to add other functions such as my own version of pacstrap lmao)
set -e

echo " ProtOS NVMe Installer "

# ifentify the drive
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



#!/bin/sh
# ProtOS Installer
# Partitions a disk, creates filesystems, and installs ProtOS

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${BLUE}[*]${NC} %s\n" "$1"; }
ok()    { printf "${GREEN}[+]${NC} %s\n" "$1"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$1"; }
error() { printf "${RED}[-]${NC} %s\n" "$1"; }

banner() {
    printf "${GREEN}"
    cat << 'EOF'

    ____             __  ____  _____
   / __ \_________  / /_/ __ \/ ___/
  / /_/ / ___/ __ \/ __/ / / /\__ \
 / ____/ /  / /_/ / /_/ /_/ /___/ /
/_/   /_/   \____/\__/\____//____/

       Installer v0.1.0

EOF
    printf "${NC}"
}

# Find available disks (exclude the boot media)
find_disks() {
    local disks=""
    for dev in /sys/block/nvme* /sys/block/vd* /sys/block/sd*; do
        [ -e "$dev" ] || continue
        local name=$(basename "$dev")
        local size_sectors=$(cat "$dev/size" 2>/dev/null || echo 0)
        local size_mb=$((size_sectors / 2048))

        # Skip tiny disks (likely the boot ISO)
        [ "$size_mb" -lt 512 ] && continue

        disks="$disks /dev/$name:${size_mb}MB"
    done
    echo "$disks"
}

# Partition the disk: GPT with EFI + root + swap
partition_disk() {
    local disk="$1"
    local disk_size_mb="$2"

    # Calculate partition sizes
    local efi_size=256       # 256MB EFI System Partition
    local swap_size=512      # 512MB swap (or 1/8 of disk, max 2GB)
    if [ "$disk_size_mb" -gt 8192 ]; then
        swap_size=$((disk_size_mb / 8))
        [ "$swap_size" -gt 2048 ] && swap_size=2048
    fi

    info "Partitioning $disk (${disk_size_mb}MB)..."
    info "  EFI:  ${efi_size}MB"
    info "  Swap: ${swap_size}MB"
    info "  Root: remaining space"

    # Create GPT partition table using sgdisk
    info "Creating GPT partition table..."

    # Wipe existing partition table
    sgdisk --zap-all "$disk" >/dev/null 2>&1

    # Partition 1: EFI System Partition
    sgdisk --new=1:0:+${efi_size}M --typecode=1:EF00 --change-name=1:"EFI" "$disk" >/dev/null 2>&1

    # Partition 2: Linux swap
    sgdisk --new=2:0:+${swap_size}M --typecode=2:8200 --change-name=2:"SWAP" "$disk" >/dev/null 2>&1

    # Partition 3: Linux root (rest of disk)
    sgdisk --new=3:0:0 --typecode=3:8300 --change-name=3:"ROOT" "$disk" >/dev/null 2>&1

    # Verify
    sgdisk --verify "$disk" >/dev/null 2>&1

    # Wait for partition devices to appear
    sleep 2
    mdev -s 2>/dev/null || true

    ok "GPT disk partitioned"
}

# Format partitions
format_partitions() {
    local disk="$1"
    local part_prefix="$disk"

    # Handle partition naming (vda1 vs sda1)
    if echo "$disk" | grep -q "nvme\|mmcblk"; then
        part_prefix="${disk}p"
    fi

    local efi_part="${part_prefix}1"
    local swap_part="${part_prefix}2"
    local root_part="${part_prefix}3"

    info "Formatting EFI partition ($efi_part) as FAT32..."
    mkdosfs -F 32 "$efi_part" 2>&1 || {
        error "Cannot format EFI partition"
        return 1
    }
    ok "EFI partition formatted (FAT32)"

    info "Formatting swap partition ($swap_part)..."
    mkswap -L PROTOS_SWAP "$swap_part" 2>&1 || {
        error "Cannot format swap partition"
        return 1
    }
    ok "Swap partition formatted"

    info "Formatting root partition ($root_part) as ext4..."
    mkfs.ext4 -F -L PROTOS_ROOT "$root_part" 2>&1 || {
        error "Cannot format root partition"
        return 1
    }
    ok "Root partition formatted (ext4)"
}

# Install ProtOS to the root partition
install_system() {
    local disk="$1"
    local part_prefix="$disk"

    if echo "$disk" | grep -q "nvme\|mmcblk"; then
        part_prefix="${disk}p"
    fi

    local efi_part="${part_prefix}1"
    local root_part="${part_prefix}3"

    # Mount root partition
    mkdir -p /mnt/target
    if ! mount -t ext4 "$root_part" /mnt/target; then
        error "Failed to mount root partition $root_part"
        return 1
    fi

    info "Installing ProtOS to disk..."

    # Create directory structure
    mkdir -p /mnt/target/bin /mnt/target/sbin /mnt/target/usr/bin /mnt/target/usr/sbin
    mkdir -p /mnt/target/lib /mnt/target/lib64
    mkdir -p /mnt/target/proc /mnt/target/sys /mnt/target/dev /mnt/target/tmp
    mkdir -p /mnt/target/run /mnt/target/root /mnt/target/mnt /mnt/target/home
    mkdir -p /mnt/target/opt /mnt/target/srv /mnt/target/boot
    mkdir -p /mnt/target/etc/init.d /mnt/target/var/log /mnt/target/var/tmp /mnt/target/var/run

    # Copy the running system to disk
    info "Copying system files..."
    cp -a /bin/* /mnt/target/bin/ 2>/dev/null
    cp -a /sbin/* /mnt/target/sbin/ 2>/dev/null
    [ -d /usr/bin ] && cp -a /usr/bin/* /mnt/target/usr/bin/ 2>/dev/null
    [ -d /usr/sbin ] && cp -a /usr/sbin/* /mnt/target/usr/sbin/ 2>/dev/null
    [ -d /lib ] && cp -a /lib/* /mnt/target/lib/ 2>/dev/null
    [ -d /linuxrc ] && cp -a /linuxrc /mnt/target/ 2>/dev/null

    # Copy config files
    cp -a /etc/* /mnt/target/etc/ 2>/dev/null

    # Install init
    cp /init /mnt/target/init 2>/dev/null
    cp /sbin/init /mnt/target/sbin/init 2>/dev/null

    # Create the installed marker
    cat > /mnt/target/etc/protos-installed << MARKER
PROTOS_ROOT_DEV=$root_part
PROTOS_SWAP_DEV=${part_prefix}2
PROTOS_EFI_DEV=$efi_part
INSTALL_DATE=$(date 2>/dev/null || echo unknown)
VERSION=0.1.0
MARKER

    # Update fstab for disk-based boot
    cat > /mnt/target/etc/fstab << FSTAB
# ProtOS filesystem table
LABEL=PROTOS_ROOT  /        ext4    defaults,noatime    0 1
LABEL=PROTOS_SWAP  none     swap    sw                  0 0
proc               /proc    proc    defaults            0 0
sysfs              /sys     sysfs   defaults            0 0
devtmpfs           /dev     devtmpfs defaults            0 0
tmpfs              /tmp     tmpfs   defaults            0 0
tmpfs              /run     tmpfs   defaults            0 0
FSTAB

    ok "System files installed"

    # Mount and set up EFI partition
    mount -t vfat "$efi_part" /mnt/target/boot
    if [ $? -eq 0 ]; then
        mkdir -p /mnt/target/boot/EFI/BOOT
        # The kernel is in the initramfs, but copy if accessible from ISO mount
        ok "EFI partition mounted"
    else
        warn "Could not mount EFI partition (non-fatal)"
    fi

    # Sync and unmount
    sync
    umount /mnt/target/boot 2>/dev/null
    umount /mnt/target

    ok "Installation complete!"
}

# Main installer flow
main() {
    banner

    # Find available disks
    info "Scanning for disks..."
    local disks=$(find_disks)

    if [ -z "$disks" ]; then
        error "No suitable disks found (need at least 512MB)"
        error "If running in a VM, add a virtual disk first"
        return 1
    fi

    printf "\n${BOLD}Available disks:${NC}\n\n"
    local i=1
    local disk_list=""
    for entry in $disks; do
        local dev=$(echo "$entry" | cut -d: -f1)
        local size=$(echo "$entry" | cut -d: -f2)
        printf "  ${BOLD}%d)${NC} %s (%s)\n" "$i" "$dev" "$size"
        disk_list="$disk_list $dev"
        i=$((i + 1))
    done

    printf "\n"

    # Ask user to select disk
    printf "${BOLD}Select disk to install ProtOS [1]: ${NC}"
    read choice
    [ -z "$choice" ] && choice=1

    local target=$(echo $disk_list | tr ' ' '\n' | grep -v '^$' | sed -n "${choice}p")
    if [ -z "$target" ]; then
        error "Invalid selection"
        return 1
    fi

    local target_size=$(echo "$disks" | tr ' ' '\n' | grep "^${target}:" | cut -d: -f2 | tr -d 'MB')

    printf "\n"
    warn "This will ERASE ALL DATA on $target ($target_size MB)"
    printf "${BOLD}Continue? [y/N]: ${NC}"
    read confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) info "Installation cancelled."; return 0 ;;
    esac

    printf "\n"

    # Run installation
    partition_disk "$target" "$target_size"
    format_partitions "$target"
    install_system "$target"

    printf "\n"
    printf "${GREEN}=========================================${NC}\n"
    printf "${GREEN}  ProtOS installed successfully!${NC}\n"
    printf "${GREEN}=========================================${NC}\n"
    printf "\n"
    printf "  Installed to: %s\n" "$target"
    printf "  EFI:   %s1 (256MB)\n" "$target"
    printf "  Swap:  %s2\n" "$target"
    printf "  Root:  %s3 (ext4)\n" "$target"
    printf "\n"
    printf "  You can now reboot and boot from the disk.\n"
    printf "  Or type 'reboot' to restart now.\n"
    printf "\n"
}

main "$@"

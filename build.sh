#!/bin/bash
# ProtOS Build Script - Fully Standalone ARM64 Linux OS
# Compiles Linux kernel and BusyBox from source using a Lima Linux VM
set -e

PROTOS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROTOS_DIR/build"
OUT_DIR="$PROTOS_DIR/out"
SRC_DIR="$PROTOS_DIR/src"
DOWNLOAD_DIR="$BUILD_DIR/downloads"

# Source versions
KERNEL_VERSION="6.6.70"
BUSYBOX_VERSION="1.36.1"
E2FSPROGS_VERSION="1.47.1"
GPTFDISK_VERSION="1.0.10"
UTILLINUX_VERSION="2.40.2"

# Source URLs
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
E2FSPROGS_URL="https://downloads.sourceforge.net/project/e2fsprogs/e2fsprogs/v${E2FSPROGS_VERSION}/e2fsprogs-${E2FSPROGS_VERSION}.tar.gz"
GPTFDISK_URL="https://downloads.sourceforge.net/project/gptfdisk/gptfdisk/${GPTFDISK_VERSION}/gptfdisk-${GPTFDISK_VERSION}.tar.gz"
UTILLINUX_URL="https://cdn.kernel.org/pub/linux/utils/util-linux/v${UTILLINUX_VERSION%.*}/util-linux-${UTILLINUX_VERSION}.tar.xz"

# Lima VM name
LIMA_VM="protos-builder"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

banner() {
    echo -e "${GREEN}"
    cat << 'EOF'
    ____             __  ____  _____
   / __ \_________  / /_/ __ \/ ___/
  / /_/ / ___/ __ \/ __/ / / /\__ \
 / ____/ /  / /_/ / /_/ /_/ /___/ /
/_/   /_/   \____/\__/\____//____/

  Standalone Build System v0.1.0
  Building from source - no prebuilt binaries
EOF
    echo -e "${NC}"
}

# Ensure Lima VM is running with build tools
setup_lima() {
    info "Setting up Linux build environment (Lima VM)..."

    if ! command -v limactl &>/dev/null; then
        error "Lima not installed. Run: brew install lima"
    fi

    # Check if VM exists and is running
    if limactl list --json 2>/dev/null | grep -q "\"name\":\"${LIMA_VM}\""; then
        local status
        status=$(limactl list --json 2>/dev/null | python3 -c "
import sys, json
for line in sys.stdin:
    vm = json.loads(line)
    if vm.get('name') == '${LIMA_VM}':
        print(vm.get('status', 'Unknown'))
" 2>/dev/null || echo "Unknown")
        if [ "$status" = "Running" ]; then
            ok "Build VM already running"
            return 0
        else
            info "Starting existing build VM..."
            limactl start "$LIMA_VM" 2>&1
            ok "Build VM started"
            return 0
        fi
    fi

    # Create new VM with build dependencies
    info "Creating build VM (first time setup, this takes a few minutes)..."
    cat > "$BUILD_DIR/lima-protos.yaml" << 'LIMAYAML'
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"

mounts:
  - location: "~"
    writable: true

containerd:
  system: false
  user: false

provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eux -o pipefail
      apt-get update -qq
      apt-get install -y -qq build-essential flex bison bc libssl-dev libelf-dev \
        cpio xz-utils bzip2 wget python3 kmod 2>&1 | tail -1
LIMAYAML

    limactl create --name="$LIMA_VM" "$BUILD_DIR/lima-protos.yaml" 2>&1
    limactl start "$LIMA_VM" 2>&1
    ok "Build VM created and started"
}

download_sources() {
    info "Downloading source code..."
    mkdir -p "$DOWNLOAD_DIR"

    if [ ! -f "$DOWNLOAD_DIR/linux-${KERNEL_VERSION}.tar.xz" ]; then
        info "Downloading Linux kernel ${KERNEL_VERSION} source..."
        curl -L -# -o "$DOWNLOAD_DIR/linux-${KERNEL_VERSION}.tar.xz" "$KERNEL_URL"
        ok "Kernel source downloaded"
    else
        ok "Kernel source already downloaded"
    fi

    if [ ! -f "$DOWNLOAD_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2" ]; then
        info "Downloading BusyBox ${BUSYBOX_VERSION} source..."
        curl -L -# -o "$DOWNLOAD_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2" "$BUSYBOX_URL"
        ok "BusyBox source downloaded"
    else
        ok "BusyBox source already downloaded"
    fi

    if [ ! -f "$DOWNLOAD_DIR/e2fsprogs-${E2FSPROGS_VERSION}.tar.gz" ]; then
        info "Downloading e2fsprogs ${E2FSPROGS_VERSION} source..."
        curl -L -# -o "$DOWNLOAD_DIR/e2fsprogs-${E2FSPROGS_VERSION}.tar.gz" "$E2FSPROGS_URL"
        ok "e2fsprogs source downloaded"
    else
        ok "e2fsprogs source already downloaded"
    fi

    if [ ! -f "$DOWNLOAD_DIR/gptfdisk-${GPTFDISK_VERSION}.tar.gz" ]; then
        info "Downloading gptfdisk ${GPTFDISK_VERSION} source..."
        curl -L -# -o "$DOWNLOAD_DIR/gptfdisk-${GPTFDISK_VERSION}.tar.gz" "$GPTFDISK_URL"
        ok "gptfdisk source downloaded"
    else
        ok "gptfdisk source already downloaded"
    fi

    if [ ! -f "$DOWNLOAD_DIR/util-linux-${UTILLINUX_VERSION}.tar.xz" ]; then
        info "Downloading util-linux ${UTILLINUX_VERSION} source..."
        curl -L -# -o "$DOWNLOAD_DIR/util-linux-${UTILLINUX_VERSION}.tar.xz" "$UTILLINUX_URL"
        ok "util-linux source downloaded"
    else
        ok "util-linux source already downloaded"
    fi
}

# Run a command inside the Lima VM
lima_exec() {
    limactl shell "$LIMA_VM" bash -c "$1"
}

build_kernel() {
    info "Compiling Linux kernel ${KERNEL_VERSION} for ARM64 (this takes a while)..."

    lima_exec "
        set -e
        cd '$PROTOS_DIR'
        BUILD='$BUILD_DIR'
        DOWNLOAD='$DOWNLOAD_DIR'
        KERNEL_VERSION='$KERNEL_VERSION'

        # Extract if needed (extract in /tmp first to handle symlinks on macOS mounts)
        if [ ! -d \"\$BUILD/linux-\${KERNEL_VERSION}\" ]; then
            echo '[EXTRACT] Linux kernel source...'
            cd /tmp
            tar xf \"\$DOWNLOAD/linux-\${KERNEL_VERSION}.tar.xz\"
            mv /tmp/linux-\${KERNEL_VERSION} \"\$BUILD/linux-\${KERNEL_VERSION}\"
        fi

        cd \"\$BUILD/linux-\${KERNEL_VERSION}\"

        # Configure kernel - start with defconfig, then apply our customizations
        if [ ! -f .config ] || [ '$SRC_DIR/kernel.config' -nt .config ] 2>/dev/null; then
            echo '[CONFIG] Generating kernel config...'
            make ARCH=arm64 defconfig

            # Enable key features for our OS
            ./scripts/config --enable CONFIG_BLK_DEV_INITRD
            ./scripts/config --enable CONFIG_RD_GZIP
            ./scripts/config --enable CONFIG_DEVTMPFS
            ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
            ./scripts/config --enable CONFIG_TTY
            ./scripts/config --enable CONFIG_SERIAL_AMBA_PL011
            ./scripts/config --enable CONFIG_SERIAL_AMBA_PL011_CONSOLE
            ./scripts/config --enable CONFIG_PRINTK
            ./scripts/config --enable CONFIG_PROC_FS
            ./scripts/config --enable CONFIG_SYSFS
            ./scripts/config --enable CONFIG_TMPFS
            ./scripts/config --enable CONFIG_EXT4_FS
            ./scripts/config --enable CONFIG_VIRTIO_BLK
            ./scripts/config --enable CONFIG_VIRTIO_NET
            ./scripts/config --enable CONFIG_VIRTIO_MMIO
            ./scripts/config --enable CONFIG_NET
            ./scripts/config --enable CONFIG_INET
            ./scripts/config --enable CONFIG_PCI
            ./scripts/config --enable CONFIG_VIRTIO_PCI

            # NVMe support
            ./scripts/config --enable CONFIG_BLK_DEV_NVME
            ./scripts/config --enable CONFIG_NVME_CORE

            # Display support (needed for UTM/virtio-gpu and EFI framebuffer)
            ./scripts/config --enable CONFIG_DRM
            ./scripts/config --enable CONFIG_DRM_VIRTIO_GPU
            ./scripts/config --enable CONFIG_DRM_SIMPLEDRM
            ./scripts/config --enable CONFIG_SYSFB_SIMPLEFB

            # Input support (keyboard/mouse in UTM and USB)
            ./scripts/config --enable CONFIG_VIRTIO_INPUT
            ./scripts/config --enable CONFIG_USB_XHCI_PCI
            ./scripts/config --enable CONFIG_USB_OHCI_HCD
            ./scripts/config --enable CONFIG_USB_OHCI_PCI

            # Disable unnecessary features to speed up build
            ./scripts/config --disable CONFIG_SOUND
            ./scripts/config --disable CONFIG_WLAN
            ./scripts/config --disable CONFIG_WIRELESS
            ./scripts/config --disable CONFIG_BLUETOOTH
            ./scripts/config --disable CONFIG_NFS_FS
            ./scripts/config --disable CONFIG_CIFS
            ./scripts/config --disable CONFIG_DEBUG_INFO_BTF

            make ARCH=arm64 olddefconfig

            # Force these to built-in (olddefconfig reverts them to =m)
            ./scripts/config --set-val CONFIG_USB_XHCI_PCI y
            ./scripts/config --set-val CONFIG_USB_XHCI_PCI_RENESAS y
            make ARCH=arm64 olddefconfig
        fi

        # Build kernel
        echo '[BUILD] Compiling kernel (using all CPU cores)...'
        make ARCH=arm64 Image -j\$(nproc) 2>&1 | tail -5

        echo '[OK] Kernel compiled successfully'
    "

    mkdir -p "$OUT_DIR"
    cp "$BUILD_DIR/linux-${KERNEL_VERSION}/arch/arm64/boot/Image" "$OUT_DIR/Image"
    ok "Kernel ready: $OUT_DIR/Image ($(du -h "$OUT_DIR/Image" | cut -f1))"
}

build_busybox() {
    info "Compiling BusyBox ${BUSYBOX_VERSION} (statically linked)..."

    lima_exec "
        set -e
        BUILD='$BUILD_DIR'
        DOWNLOAD='$DOWNLOAD_DIR'
        BUSYBOX_VERSION='$BUSYBOX_VERSION'

        # Extract if needed (extract in /tmp to handle symlinks)
        if [ ! -d \"\$BUILD/busybox-\${BUSYBOX_VERSION}\" ]; then
            echo '[EXTRACT] BusyBox source...'
            cd /tmp
            tar xf \"\$DOWNLOAD/busybox-\${BUSYBOX_VERSION}.tar.bz2\"
            mv /tmp/busybox-\${BUSYBOX_VERSION} \"\$BUILD/busybox-\${BUSYBOX_VERSION}\"
        fi

        cd \"\$BUILD/busybox-\${BUSYBOX_VERSION}\"

        # Configure BusyBox
        if [ ! -f .config ]; then
            echo '[CONFIG] Generating BusyBox config...'
            make defconfig

            # Enable static linking - critical for standalone OS
            sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config

            # Disable features that cause build issues on newer kernels
            sed -i 's/CONFIG_TC=y/# CONFIG_TC is not set/' .config
            sed -i 's/CONFIG_FEATURE_HAVE_RPC=y/# CONFIG_FEATURE_HAVE_RPC is not set/' .config
            sed -i 's/CONFIG_FEATURE_INETD_RPC=y/# CONFIG_FEATURE_INETD_RPC is not set/' .config

            make oldconfig </dev/null
        fi

        # Build
        echo '[BUILD] Compiling BusyBox...'
        make -j\$(nproc) 2>&1 | tail -3
        make install 2>&1 | tail -1

        echo '[OK] BusyBox compiled successfully'
    "

    ok "BusyBox compiled"
}

build_e2fsprogs() {
    info "Compiling e2fsprogs ${E2FSPROGS_VERSION} (static mkfs.ext4)..."

    lima_exec "
        set -e
        BUILD='$BUILD_DIR'
        DOWNLOAD='$DOWNLOAD_DIR'
        E2FSPROGS_VERSION='$E2FSPROGS_VERSION'

        # Extract if needed
        if [ ! -d \"\$BUILD/e2fsprogs-\${E2FSPROGS_VERSION}\" ]; then
            echo '[EXTRACT] e2fsprogs source...'
            cd /tmp
            tar xf \"\$DOWNLOAD/e2fsprogs-\${E2FSPROGS_VERSION}.tar.gz\"
            mv /tmp/e2fsprogs-\${E2FSPROGS_VERSION} \"\$BUILD/e2fsprogs-\${E2FSPROGS_VERSION}\"
        fi

        cd \"\$BUILD/e2fsprogs-\${E2FSPROGS_VERSION}\"

        if [ ! -f misc/mke2fs ]; then
            echo '[CONFIG] Configuring e2fsprogs...'
            ./configure \
                LDFLAGS='-static' \
                --disable-nls \
                --disable-defrag \
                --disable-debugfs \
                --disable-imager \
                --disable-resizer \
                --disable-uuidd \
                --disable-fsck \
                --disable-e2initrd-helper \
                --disable-tdb \
                --enable-libuuid \
                --enable-libblkid \
                2>&1 | tail -3

            echo '[BUILD] Compiling e2fsprogs...'
            make -j\$(nproc) 2>&1 | tail -5
        fi

        echo '[OK] e2fsprogs compiled successfully'
    "

    ok "e2fsprogs compiled"
}

build_gptfdisk() {
    info "Compiling gptfdisk ${GPTFDISK_VERSION} (static sgdisk)..."

    lima_exec "
        set -e
        BUILD='$BUILD_DIR'
        DOWNLOAD='$DOWNLOAD_DIR'
        GPTFDISK_VERSION='$GPTFDISK_VERSION'

        # Need popt and uuid for sgdisk static build
        if ! dpkg -l | grep -q libpopt-dev; then
            echo '[DEPS] Installing gptfdisk build dependencies...'
            sudo apt-get install -y -qq libpopt-dev uuid-dev libncurses-dev 2>&1 | tail -1
        fi

        # Extract if needed
        if [ ! -d \"\$BUILD/gptfdisk-\${GPTFDISK_VERSION}\" ]; then
            echo '[EXTRACT] gptfdisk source...'
            cd /tmp
            tar xf \"\$DOWNLOAD/gptfdisk-\${GPTFDISK_VERSION}.tar.gz\"
            mv /tmp/gptfdisk-\${GPTFDISK_VERSION} \"\$BUILD/gptfdisk-\${GPTFDISK_VERSION}\"
        fi

        cd \"\$BUILD/gptfdisk-\${GPTFDISK_VERSION}\"

        if [ ! -f sgdisk ]; then
            echo '[BUILD] Compiling sgdisk...'
            make LDFLAGS='-static' sgdisk -j\$(nproc) 2>&1 | tail -5
        fi

        echo '[OK] gptfdisk compiled successfully'
    "

    ok "gptfdisk compiled"
}

build_utillinux() {
    info "Compiling util-linux ${UTILLINUX_VERSION} (full package, static)..."

    lima_exec "
        set -e
        BUILD='$BUILD_DIR'
        DOWNLOAD='$DOWNLOAD_DIR'
        UTILLINUX_VERSION='$UTILLINUX_VERSION'

        # Install build deps for full util-linux
        if ! dpkg -l | grep -q libncursesw5-dev; then
            echo '[DEPS] Installing util-linux build dependencies...'
            sudo apt-get install -y -qq libncursesw5-dev libncurses-dev 2>&1 | tail -1
        fi

        # Extract if needed
        if [ ! -d \"\$BUILD/util-linux-\${UTILLINUX_VERSION}\" ]; then
            echo '[EXTRACT] util-linux source...'
            cd /tmp
            tar xf \"\$DOWNLOAD/util-linux-\${UTILLINUX_VERSION}.tar.xz\"
            mv /tmp/util-linux-\${UTILLINUX_VERSION} \"\$BUILD/util-linux-\${UTILLINUX_VERSION}\"
        fi

        cd \"\$BUILD/util-linux-\${UTILLINUX_VERSION}\"

        if [ ! -f .built_marker ]; then
            # Clean any previous partial build
            make clean 2>/dev/null || true

            echo '[CONFIG] Configuring util-linux (full package)...'
            ./configure \
                CFLAGS='-Os' \
                --disable-shared \
                --enable-static \
                --without-python \
                --without-systemd \
                --without-udev \
                --without-audit \
                --without-selinux \
                --without-readline \
                --without-sqlite3 \
                --disable-nls \
                --disable-pylibmount \
                --disable-login \
                --disable-sulogin \
                --disable-su \
                --disable-runuser \
                --disable-setpriv \
                --disable-chfn-chsh \
                --disable-newgrp \
                --disable-liblastlog2 \
                --disable-lastlog2 \
                --disable-pam-lastlog2 \
                --disable-makeinstall-chown \
                --disable-makeinstall-setuid \
                --enable-libuuid \
                --enable-libblkid \
                --enable-libmount \
                --enable-libsmartcols \
                --enable-libfdisk \
                2>&1 | tail -3

            echo '[BUILD] Compiling util-linux (static)...'
            make -j\$(nproc) LDFLAGS='--static' 2>&1 | tail -5

            # Collect all built static binaries into a staging dir
            echo '[INSTALL] Collecting binaries...'
            mkdir -p \"\$BUILD/util-linux-bins\"
            for bin in \
                lsblk blkid findmnt mount umount \
                fdisk sfdisk cfdisk \
                lscpu lsmem lsns lsirq lsipc lslogins \
                dmesg kill flock getopt rev cal column \
                losetup swapon swapoff \
                wipefs partx blockdev \
                nsenter unshare \
                more script scriptreplay \
                taskset ionice renice chrt \
                fallocate truncate \
                logger last lastb \
                uuidgen uuidparse \
                hexdump rename hardlink \
                mountpoint findfs \
                mkswap fsck fsck.cramfs \
                fstrim eject hwclock rtcwake \
                switch_root pivot_root \
                lslocks wdctl isosize prlimit \
                ; do
                # Binaries can be in root dir or .libs/
                if [ -f \"\$bin\" ] && file \"\$bin\" | grep -q 'statically linked'; then
                    cp \"\$bin\" \"\$BUILD/util-linux-bins/\"
                elif [ -f \".libs/\$bin\" ] && file \".libs/\$bin\" | grep -q 'statically linked'; then
                    cp \".libs/\$bin\" \"\$BUILD/util-linux-bins/\"
                fi
            done

            # Verify we got static binaries
            local_count=\$(ls \"\$BUILD/util-linux-bins/\" 2>/dev/null | wc -l)
            if [ \"\$local_count\" -eq 0 ]; then
                echo '[WARN] No static binaries found, trying alternative static link...'
                # Rebuild individual tools with explicit static linking
                for tool in lsblk lscpu lsmem fdisk sfdisk blkid findmnt \
                    dmesg flock nsenter unshare losetup wipefs blockdev \
                    fallocate fstrim hwclock mount umount swapon swapoff \
                    mkswap hexdump cal column rev uuidgen kill eject \
                    mountpoint findfs partx taskset ionice renice chrt \
                    prlimit lsns lsirq lsipc lslogins lslocks wdctl \
                    switch_root pivot_root script scriptreplay logger \
                    last hardlink isosize getopt rename truncate more \
                    fsck cfdisk; do
                    make \"\$tool\" LDFLAGS='-all-static' 2>/dev/null && {
                        if file \"\$tool\" | grep -q 'statically linked'; then
                            cp \"\$tool\" \"\$BUILD/util-linux-bins/\"
                        fi
                    }
                done
            fi

            touch .built_marker
            echo \"[OK] Collected \$(ls \$BUILD/util-linux-bins/ 2>/dev/null | wc -l) static util-linux binaries\"
        fi

        echo '[OK] util-linux compiled successfully'
    "

    ok "util-linux compiled"
}

build_pacman() {
    info "Building pacman package manager (static, with all dependencies)..."

    lima_exec "
        set -e
        bash '$PROTOS_DIR/scripts/build-pacman.sh' '$BUILD_DIR'
    "

    ok "pacman built"
}

bootstrap_arch_base() {
    info "Downloading Arch Linux ARM base packages (glibc, filesystem, etc.)..."

    lima_exec "
        set -e
        BUILD='$BUILD_DIR'
        BOOTSTRAP_DIR=\"\$BUILD/arch-bootstrap\"
        mkdir -p \"\$BOOTSTRAP_DIR\"

        # Download core packages from Arch Linux ARM if not already cached
        MIRROR='http://mirror.archlinuxarm.org/aarch64/core'
        cd \"\$BOOTSTRAP_DIR\"

        # We need these packages for dynamically-linked Arch packages to work:
        # - filesystem: directory layout and base config
        # - glibc: dynamic linker + C library
        # - gcc-libs: libgcc_s, libstdc++ (many packages need these)
        # - ncurses: libncursesw (nano, etc.)
        # - readline: libreadline (bash, etc.)
        # - zlib: libz (very common dependency)
        # - zstd: libzstd
        # - xz: liblzma
        # - bzip2: libbz2

        for pkg in filesystem glibc gcc-libs ncurses readline zlib zstd xz bzip2; do
            if [ ! -d \"\$BOOTSTRAP_DIR/\$pkg-extracted\" ]; then
                echo \"[INFO] Fetching \$pkg package listing...\"
                # Get the actual package filename from the repo
                # Use href extraction to find exact package matches
                REPO_LIST=\$(curl -sL \"\$MIRROR/\")
                PKG_FILE=\$(echo \"\$REPO_LIST\" | grep -oP \"href=\\\"\\K\${pkg}-[0-9][^\\\"]*-aarch64\\.pkg\\.tar\\.[gx]z[a-z]*\" | sort -V | tail -1)
                if [ -z \"\$PKG_FILE\" ]; then
                    PKG_FILE=\$(echo \"\$REPO_LIST\" | grep -oP \"href=\\\"\\K\${pkg}-[0-9][^\\\"]*-any\\.pkg\\.tar\\.[gx]z[a-z]*\" | sort -V | tail -1)
                fi
                if [ -n \"\$PKG_FILE\" ]; then
                    echo \"[INFO] Downloading \$PKG_FILE...\"
                    curl -L -# -o \"\$BOOTSTRAP_DIR/\$PKG_FILE\" \"\$MIRROR/\$PKG_FILE\"
                    mkdir -p \"\$BOOTSTRAP_DIR/\$pkg-extracted\"
                    tar xf \"\$BOOTSTRAP_DIR/\$PKG_FILE\" -C \"\$BOOTSTRAP_DIR/\$pkg-extracted\" 2>/dev/null || true
                    echo \"[OK] \$pkg downloaded and extracted\"
                else
                    echo \"[WARN] Could not find \$pkg package\"
                fi
            else
                echo \"[OK] \$pkg already cached\"
            fi
        done

        echo '[OK] Arch base packages ready'
    "

    ok "Arch base packages downloaded"
}

build_rootfs() {
    info "Building ProtOS root filesystem from scratch..."
    local ROOTFS="$BUILD_DIR/rootfs"
    rm -rf "$ROOTFS"

    # Create merged-usr directory hierarchy (Arch Linux ARM compatible)
    # Real directories live under /usr, top-level dirs are symlinks
    mkdir -p "$ROOTFS"/usr/{bin,sbin,lib}
    mkdir -p "$ROOTFS"/{proc,sys,dev,tmp,run,root,mnt,home,opt,srv}
    mkdir -p "$ROOTFS"/{etc/init.d,var/log,var/tmp}
    # Create merged-usr symlinks (same layout as Arch Linux ARM filesystem package)
    ln -sf usr/bin "$ROOTFS/bin"
    ln -sf usr/sbin "$ROOTFS/sbin"
    ln -sf usr/lib "$ROOTFS/lib"
    ln -sf usr/lib "$ROOTFS/lib64"
    ln -sf ../run "$ROOTFS/var/run"

    # Install BusyBox — copy into real usr/ dirs (since /bin, /sbin are symlinks)
    info "Installing BusyBox into rootfs..."
    local BB_INSTALL="$BUILD_DIR/busybox-${BUSYBOX_VERSION}/_install"
    # Copy bin/ contents to usr/bin/
    if [ -d "$BB_INSTALL/bin" ]; then
        cp -a "$BB_INSTALL/bin/"* "$ROOTFS/usr/bin/" 2>/dev/null || true
    fi
    # Copy sbin/ contents to usr/sbin/
    if [ -d "$BB_INSTALL/sbin" ]; then
        cp -a "$BB_INSTALL/sbin/"* "$ROOTFS/usr/sbin/" 2>/dev/null || true
    fi
    # Copy usr/ contents
    if [ -d "$BB_INSTALL/usr" ]; then
        cp -a "$BB_INSTALL/usr/"* "$ROOTFS/usr/" 2>/dev/null || true
    fi
    # Copy linuxrc if it exists
    [ -f "$BB_INSTALL/linuxrc" ] && cp -a "$BB_INSTALL/linuxrc" "$ROOTFS/" 2>/dev/null || true

    # Install ProtOS init
    info "Installing ProtOS init system..."
    cp "$SRC_DIR/init" "$ROOTFS/init"
    chmod +x "$ROOTFS/init"

    # Install ProtOS config files
    cp "$SRC_DIR/etc/os-release" "$ROOTFS/etc/os-release"
    cp "$SRC_DIR/etc/hostname" "$ROOTFS/etc/hostname"
    cp "$SRC_DIR/etc/motd" "$ROOTFS/etc/motd"
    cp "$SRC_DIR/etc/profile" "$ROOTFS/etc/profile"
    cp "$SRC_DIR/etc/inittab" "$ROOTFS/etc/inittab"
    cp "$SRC_DIR/etc/shell-login" "$ROOTFS/etc/shell-login"
    chmod +x "$ROOTFS/etc/shell-login"
    cp "$SRC_DIR/etc/init.d/rcS" "$ROOTFS/etc/init.d/rcS"
    chmod +x "$ROOTFS/etc/init.d/rcS"
    cp "$SRC_DIR/etc/udhcpc.sh" "$ROOTFS/etc/udhcpc.sh"
    chmod +x "$ROOTFS/etc/udhcpc.sh"

    # Install installer
    cp "$SRC_DIR/installer/install_protos.sh" "$ROOTFS/etc/install_protos.sh"
    chmod +x "$ROOTFS/etc/install_protos.sh"


    # Install protpkg package manager
    info "Installing protpkg package manager..."
    cp "$SRC_DIR/usr/bin/protpkg" "$ROOTFS/usr/bin/protpkg"
    chmod +x "$ROOTFS/usr/bin/protpkg"
    cp "$SRC_DIR/usr/bin/protpkg-build" "$ROOTFS/usr/bin/protpkg-build"
    chmod +x "$ROOTFS/usr/bin/protpkg-build"
    mkdir -p "$ROOTFS/var/lib/protpkg/installed"
    mkdir -p "$ROOTFS/var/cache/protpkg"

    # Install extra static binaries for installer
    info "Installing mkfs.ext4 and sgdisk..."
    rm -f "$ROOTFS/sbin/mkfs.ext4"
    cp "$BUILD_DIR/e2fsprogs-${E2FSPROGS_VERSION}/misc/mke2fs" "$ROOTFS/sbin/mkfs.ext4"
    chmod +x "$ROOTFS/sbin/mkfs.ext4"
    rm -f "$ROOTFS/sbin/sgdisk"
    cp "$BUILD_DIR/gptfdisk-${GPTFDISK_VERSION}/sgdisk" "$ROOTFS/sbin/sgdisk"
    chmod +x "$ROOTFS/sbin/sgdisk"

    # Install util-linux binaries (replace BusyBox symlinks with real binaries)
    info "Installing util-linux binaries..."
    local UL_BINS="$BUILD_DIR/util-linux-bins"
    if [ -d "$UL_BINS" ]; then
        local count=0
        for bin in "$UL_BINS"/*; do
            [ -f "$bin" ] || continue
            local name=$(basename "$bin")
            local dest
            # sbin-type tools go to /sbin, everything else to /usr/bin
            case "$name" in
                mount|umount|swapon|swapoff|losetup|fdisk|sfdisk|cfdisk|\
                blkid|findfs|fsck|fsck.*|mkswap|wipefs|blockdev|partx|\
                fstrim|switch_root|pivot_root|hwclock|rtcwake)
                    dest="$ROOTFS/sbin/$name"
                    ;;
                *)
                    dest="$ROOTFS/usr/bin/$name"
                    ;;
            esac
            # Remove any existing symlink first to avoid overwriting
            # the BusyBox binary through a symlink
            rm -f "$dest"
            cp "$bin" "$dest"
            chmod +x "$dest"
            count=$((count + 1))
        done
        ok "Installed $count util-linux tools"
    else
        warn "util-linux binaries not found — skipping"
    fi

    # Create essential system files
    echo "root:x:0:0:root:/root:/bin/sh" > "$ROOTFS/etc/passwd"
    echo "root:x:0:" > "$ROOTFS/etc/group"
    echo "root::0:0:99999:7:::" > "$ROOTFS/etc/shadow"
    chmod 600 "$ROOTFS/etc/shadow"

    cat > "$ROOTFS/etc/fstab" << 'FSTAB'
# ProtOS filesystem table
proc    /proc   proc    defaults    0 0
sysfs   /sys    sysfs   defaults    0 0
devtmpfs /dev   devtmpfs defaults   0 0
tmpfs   /tmp    tmpfs   defaults    0 0
tmpfs   /run    tmpfs   defaults    0 0
FSTAB

    # Create /etc/shells
    echo "/bin/sh" > "$ROOTFS/etc/shells"

    # Create /etc/nsswitch.conf
    cat > "$ROOTFS/etc/nsswitch.conf" << 'NSS'
passwd: files
group: files
shadow: files
hosts: files dns
NSS

    # Install pacman
    info "Installing pacman package manager..."
    local PACMAN_PREFIX="$BUILD_DIR/pacman-install"
    if [ -d "$PACMAN_PREFIX" ]; then
        # Copy pacman binaries
        for bin in pacman pacman-conf pacman-db-upgrade pacman-key vercmp makepkg; do
            if [ -f "$PACMAN_PREFIX/bin/$bin" ]; then
                rm -f "$ROOTFS/usr/bin/$bin"
                cp "$PACMAN_PREFIX/bin/$bin" "$ROOTFS/usr/bin/$bin"
                chmod +x "$ROOTFS/usr/bin/$bin"
            fi
        done
        # Copy pacman libs/scripts
        if [ -d "$PACMAN_PREFIX/share/makepkg" ]; then
            mkdir -p "$ROOTFS/usr/share"
            cp -a "$PACMAN_PREFIX/share/makepkg" "$ROOTFS/usr/share/"
        fi
        if [ -d "$PACMAN_PREFIX/share/pacman" ]; then
            cp -a "$PACMAN_PREFIX/share/pacman" "$ROOTFS/usr/share/"
        fi
        # Create pacman config
        mkdir -p "$ROOTFS/etc/pacman.d"
        cat > "$ROOTFS/etc/pacman.conf" << 'PACCONF'
#
# ProtOS pacman configuration
#
[options]
RootDir     = /
DBPath      = /var/lib/pacman/
CacheDir    = /var/cache/pacman/pkg/
LogFile     = /var/log/pacman.log
GPGDir      = /etc/pacman.d/gnupg/
HookDir     = /etc/pacman.d/hooks/
HoldPkg     = busybox
Architecture = aarch64
SigLevel    = Never

# Arch Linux ARM repositories
[core]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[extra]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[alarm]
Server = http://mirror.archlinuxarm.org/$arch/$repo

[aur]
Server = http://mirror.archlinuxarm.org/$arch/$repo
PACCONF

        # Create necessary dirs for pacman
        mkdir -p "$ROOTFS/var/lib/pacman/"{local,sync}
        mkdir -p "$ROOTFS/var/cache/pacman/pkg"
        mkdir -p "$ROOTFS/var/log"

        # Create ALPM local database version marker
        echo "9" > "$ROOTFS/var/lib/pacman/local/ALPM_DB_VERSION"

        ok "pacman installed"
    else
        warn "pacman not built — skipping"
    fi

    # Install Arch Linux ARM base packages (glibc, libs, etc.) into rootfs
    # This provides the dynamic linker and shared libs so pacman-installed packages can run
    info "Installing Arch Linux ARM base libraries..."
    local BOOTSTRAP_DIR="$BUILD_DIR/arch-bootstrap"
    if [ -d "$BOOTSTRAP_DIR" ]; then
        for pkg_dir in "$BOOTSTRAP_DIR"/*-extracted; do
            [ -d "$pkg_dir" ] || continue
            local pkg_name=$(basename "$pkg_dir" | sed 's/-extracted$//')
            info "  Installing $pkg_name..."
            # Copy usr/lib (shared libraries - most important)
            if [ -d "$pkg_dir/usr/lib" ]; then
                # Use rsync-like approach: copy files without clobbering our binaries
                find "$pkg_dir/usr/lib" -type f -o -type l | while read src; do
                    local rel="${src#$pkg_dir/}"
                    local dst="$ROOTFS/$rel"
                    local dst_dir=$(dirname "$dst")
                    mkdir -p "$dst_dir"
                    # Don't overwrite our static binaries or existing configs
                    if [ ! -f "$dst" ] || echo "$rel" | grep -qE '\.so'; then
                        cp -a "$src" "$dst" 2>/dev/null || true
                    fi
                done
            fi
            # Copy usr/bin (only if we don't already have the binary)
            if [ -d "$pkg_dir/usr/bin" ]; then
                for src in "$pkg_dir/usr/bin"/*; do
                    [ -f "$src" ] || continue
                    local name=$(basename "$src")
                    if [ ! -f "$ROOTFS/usr/bin/$name" ]; then
                        cp -a "$src" "$ROOTFS/usr/bin/$name" 2>/dev/null || true
                    fi
                done
            fi
            # Copy usr/sbin
            if [ -d "$pkg_dir/usr/sbin" ]; then
                for src in "$pkg_dir/usr/sbin"/*; do
                    [ -f "$src" ] || continue
                    local name=$(basename "$src")
                    if [ ! -f "$ROOTFS/usr/sbin/$name" ]; then
                        cp -a "$src" "$ROOTFS/usr/sbin/$name" 2>/dev/null || true
                    fi
                done
            fi
            # Copy usr/share (terminfo, locale, etc.)
            if [ -d "$pkg_dir/usr/share" ]; then
                cp -a "$pkg_dir/usr/share/"* "$ROOTFS/usr/share/" 2>/dev/null || true
            fi
            # Copy usr/include (headers - needed for some package installs)
            if [ -d "$pkg_dir/usr/include" ]; then
                mkdir -p "$ROOTFS/usr/include"
                cp -a "$pkg_dir/usr/include/"* "$ROOTFS/usr/include/" 2>/dev/null || true
            fi
            # Copy etc files (only if we don't already have them)
            if [ -d "$pkg_dir/etc" ]; then
                find "$pkg_dir/etc" -type f | while read src; do
                    local rel="${src#$pkg_dir/}"
                    local dst="$ROOTFS/$rel"
                    if [ ! -f "$dst" ]; then
                        local dst_dir=$(dirname "$dst")
                        mkdir -p "$dst_dir"
                        cp -a "$src" "$dst" 2>/dev/null || true
                    fi
                done
            fi
            # Register this package in pacman's local database
            if [ -f "$pkg_dir/.PKGINFO" ]; then
                local p_name=$(grep '^pkgname = ' "$pkg_dir/.PKGINFO" | head -1 | sed 's/^pkgname = //')
                local p_ver=$(grep '^pkgver = ' "$pkg_dir/.PKGINFO" | head -1 | sed 's/^pkgver = //')
                local p_desc=$(grep '^pkgdesc = ' "$pkg_dir/.PKGINFO" | head -1 | sed 's/^pkgdesc = //')
                local p_arch=$(grep '^arch = ' "$pkg_dir/.PKGINFO" | head -1 | sed 's/^arch = //')
                local p_url=$(grep '^url = ' "$pkg_dir/.PKGINFO" | head -1 | sed 's/^url = //')
                local p_size=$(grep '^size = ' "$pkg_dir/.PKGINFO" | head -1 | sed 's/^size = //')
                # Collect depends
                local p_depends=$(grep '^depend = ' "$pkg_dir/.PKGINFO" | sed 's/^depend = //')
                # Collect provides
                local p_provides=$(grep '^provides = ' "$pkg_dir/.PKGINFO" | sed 's/^provides = //')
                if [ -n "$p_name" ] && [ -n "$p_ver" ]; then
                    local db_dir="$ROOTFS/var/lib/pacman/local/${p_name}-${p_ver}"
                    mkdir -p "$db_dir"
                    # Create desc file in pacman format
                    {
                        echo "%NAME%"
                        echo "${p_name}"
                        echo ""
                        echo "%VERSION%"
                        echo "${p_ver}"
                        echo ""
                        echo "%BASE%"
                        echo "${p_name}"
                        echo ""
                        echo "%DESC%"
                        echo "${p_desc:-Pre-installed by ProtOS}"
                        echo ""
                        echo "%ARCH%"
                        echo "${p_arch:-aarch64}"
                        echo ""
                        echo "%URL%"
                        echo "${p_url:-}"
                        echo ""
                        echo "%INSTALLDATE%"
                        echo "$(date +%s)"
                        echo ""
                        echo "%PACKAGER%"
                        echo "ProtOS Build System"
                        echo ""
                        echo "%SIZE%"
                        echo "${p_size:-0}"
                        echo ""
                        echo "%REASON%"
                        echo "0"
                        echo ""
                        if [ -n "$p_depends" ]; then
                            echo "%DEPENDS%"
                            echo "$p_depends"
                            echo ""
                        fi
                        if [ -n "$p_provides" ]; then
                            echo "%PROVIDES%"
                            echo "$p_provides"
                            echo ""
                        fi
                        echo "%VALIDATION%"
                        echo "none"
                        echo ""
                    } > "$db_dir/desc"
                    # Create files list (macOS-compatible: no -printf)
                    {
                        echo "%FILES%"
                        (cd "$pkg_dir" && find . \
                            -not -name '.PKGINFO' -not -name '.MTREE' \
                            -not -name '.INSTALL' -not -name '.BUILDINFO' \
                            -not -path '.' | sed 's|^\./||' | sort)
                        echo ""
                    } > "$db_dir/files"
                    # Copy install scriptlet if present
                    [ -f "$pkg_dir/.INSTALL" ] && cp "$pkg_dir/.INSTALL" "$db_dir/install" 2>/dev/null || true
                    # Copy mtree
                    [ -f "$pkg_dir/.MTREE" ] && cp "$pkg_dir/.MTREE" "$db_dir/mtree" 2>/dev/null || true
                    ok "  Registered $p_name-$p_ver in pacman database"
                fi
            fi
        done
        ok "Arch base libraries installed"
    else
        warn "Arch bootstrap packages not found — skipping"
    fi

    # Install terminfo into /etc/terminfo (first search path for ncurses)
    # IMPORTANT: macOS is case-insensitive so /usr/share/terminfo/l and /L are the same dir.
    # But on Linux they're different! The Arch ncurses pkg uses uppercase (L/linux) but
    # programs look for lowercase (l/linux). Using /etc/terminfo avoids this entirely.
    info "Installing terminfo database..."
    lima_exec "
        set -e
        ROOTFS='$ROOTFS'
        # Install into /etc/terminfo (always checked first by ncurses)
        for d in l v x a d s; do
            mkdir -p \"\$ROOTFS/etc/terminfo/\$d\"
        done
        for dir in /usr/share/terminfo /usr/lib/terminfo /etc/terminfo; do
            if [ -f \"\$dir/l/linux\" ]; then
                cp -f \"\$dir/l/linux\" \"\$ROOTFS/etc/terminfo/l/\"
                cp -f \"\$dir/v/vt100\" \"\$ROOTFS/etc/terminfo/v/\" 2>/dev/null || true
                cp -f \"\$dir/v/vt220\" \"\$ROOTFS/etc/terminfo/v/\" 2>/dev/null || true
                cp -f \"\$dir/x/xterm\" \"\$ROOTFS/etc/terminfo/x/\" 2>/dev/null || true
                cp -f \"\$dir/x/xterm-256color\" \"\$ROOTFS/etc/terminfo/x/\" 2>/dev/null || true
                cp -f \"\$dir/a/ansi\" \"\$ROOTFS/etc/terminfo/a/\" 2>/dev/null || true
                cp -f \"\$dir/d/dumb\" \"\$ROOTFS/etc/terminfo/d/\" 2>/dev/null || true
                cp -f \"\$dir/s/screen\" \"\$ROOTFS/etc/terminfo/s/\" 2>/dev/null || true
                cp -f \"\$dir/s/screen-256color\" \"\$ROOTFS/etc/terminfo/s/\" 2>/dev/null || true
                echo 'Copied terminfo to /etc/terminfo from Lima VM'
                break
            fi
        done
    "
    ok "Terminfo installed"

    # Add wrapper scripts for common command names
    printf '#!/bin/sh\nexec mkfs.vfat "$@"\n' > "$ROOTFS/sbin/mkfs.fat"
    chmod +x "$ROOTFS/sbin/mkfs.fat"
    printf '#!/bin/sh\nexec mkdosfs "$@"\n' > "$ROOTFS/sbin/mkfs.fat32"
    chmod +x "$ROOTFS/sbin/mkfs.fat32"

    # ldconfig stub — Arch packages call ldconfig in post-install hooks
    # but BusyBox doesn't include it. A no-op stub silences the warning.
    printf '#!/bin/sh\nexit 0\n' > "$ROOTFS/usr/sbin/ldconfig"
    chmod +x "$ROOTFS/usr/sbin/ldconfig"

    # Default DNS resolv.conf (overwritten by DHCP)
    cat > "$ROOTFS/etc/resolv.conf" << 'DNS'
nameserver 8.8.8.8
nameserver 1.1.1.1
DNS

    ok "Root filesystem built"
}

create_initramfs() {
    info "Creating initramfs (cpio archive)..."
    mkdir -p "$OUT_DIR"

    
    lima_exec "
        set -e
        ROOTFS='$BUILD_DIR/rootfs'
        OUT='$OUT_DIR'
        TMPROOT='/tmp/protos-rootfs-cpio'

        # Copy rootfs to case-sensitive local filesystem
        # Use tar to preserve symlinks and all file types reliably across the Lima mount
        sudo rm -rf \"\$TMPROOT\"
        mkdir -p \"\$TMPROOT\"
        cd \"\$ROOTFS\"
        tar cf - . | (cd \"\$TMPROOT\" && tar xf -)

        # Recreate merged-usr symlinks (macOS mount doesn't preserve them)
        cd \"\$TMPROOT\"
        rm -rf bin sbin lib lib64 2>/dev/null || true
        ln -sf usr/bin bin
        ln -sf usr/sbin sbin
        ln -sf usr/lib lib
        ln -sf usr/lib lib64

        # Fix execute permissions (macOS mount strips them)
        chmod +x \"\$TMPROOT/init\"
        find \"\$TMPROOT/usr/bin\" -type f -exec chmod +x {} +
        find \"\$TMPROOT/usr/sbin\" -type f -exec chmod +x {} +
        find \"\$TMPROOT/usr/lib\" -name '*.so*' -type f -exec chmod +x {} + 2>/dev/null || true
        chmod +x \"\$TMPROOT/etc/shell-login\" \"\$TMPROOT/etc/init.d/rcS\" \"\$TMPROOT/etc/udhcpc.sh\" 2>/dev/null || true
        chmod +x \"\$TMPROOT/etc/installer.sh\" 2>/dev/null || true
        chmod +x \"\$TMPROOT/etc/install_protos.sh\" 2>/dev/null || true


        # Fix terminfo case-sensitivity: create lowercase dirs with copies of uppercase content
        cd \"\$TMPROOT/usr/share/terminfo\" 2>/dev/null || true
        for upper_dir in A B C D E F G H I J K L M N O P Q R S T U V W X Y Z; do
            lower_dir=\$(echo \"\$upper_dir\" | tr 'A-Z' 'a-z')
            if [ -d \"\$upper_dir\" ]; then
                mkdir -p \"\$lower_dir\"
                for f in \"\$upper_dir\"/*; do
                    [ -f \"\$f\" ] && cp -a \"\$f\" \"\$lower_dir/\" 2>/dev/null || true
                done
            fi
        done

        # Create the cpio archive from the case-correct copy
        cd \"\$TMPROOT\"
        sudo chown -R 0:0 \"\$TMPROOT\"
        find . | cpio -H newc -o --quiet 2>/dev/null | gzip -9 > \"\$OUT/initramfs.cpio.gz\"

        # Clean up
        sudo rm -rf \"\$TMPROOT\"
    "

    ok "initramfs created: $OUT_DIR/initramfs.cpio.gz ($(du -h "$OUT_DIR/initramfs.cpio.gz" | cut -f1))"
}

do_build() {
    banner

    mkdir -p "$BUILD_DIR" "$OUT_DIR" "$DOWNLOAD_DIR"

    download_sources
    setup_lima
    build_kernel
    build_busybox
    build_e2fsprogs
    build_gptfdisk
    build_utillinux
    build_pacman
    bootstrap_arch_base
    build_rootfs
    create_initramfs

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  ProtOS build complete!${NC}"
    echo -e "${GREEN}  100% compiled from source${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo "  Kernel:    $OUT_DIR/Image"
    echo "  Initramfs: $OUT_DIR/initramfs.cpio.gz"
    echo ""
    echo "  Kernel:  Linux ${KERNEL_VERSION} (compiled from kernel.org source)"
    echo "  Userland: BusyBox ${BUSYBOX_VERSION} (compiled from source, static)"
    echo ""
    echo "  Run './boot.sh' to start ProtOS in QEMU"
    echo ""
}

build_iso() {
    info "Building bootable EFI ISO image..."

    lima_exec "
        set -e
        OUT='$OUT_DIR'
        ISO_DIR='/tmp/protos-iso'
        EFI_IMG='/tmp/efi.img'

        # Create embedded GRUB config
        cat > /tmp/grub-embed.cfg << 'GRUBEOF'
insmod part_gpt
insmod part_msdos
insmod iso9660
insmod fat
insmod linux
insmod gzio
insmod normal
insmod search
insmod search_label

set timeout=5
set default=0

search --no-floppy --set=root --label PROTOS_0_1_0

menuentry \"ProtOS v0.1.0 (ARM64)\" {
    linux /boot/protos/vmlinuz rdinit=/init console=tty0 console=ttyAMA0 loglevel=3 quiet
    initrd /boot/protos/initramfs.gz
}

menuentry \"ProtOS v0.1.0 (Verbose Boot)\" {
    linux /boot/protos/vmlinuz rdinit=/init console=tty0 console=ttyAMA0 loglevel=7
    initrd /boot/protos/initramfs.gz
}
GRUBEOF

        # Build GRUB EFI binary
        grub-mkstandalone \\
            --format=arm64-efi \\
            --output=/tmp/bootaa64.efi \\
            --locales='' \\
            --fonts='' \\
            --modules='part_gpt part_msdos iso9660 fat linux gzio normal search search_label search_fs_uuid' \\
            'boot/grub/grub.cfg=/tmp/grub-embed.cfg' \\
            2>&1

        # Create EFI boot image
        dd if=/dev/zero of=\"\$EFI_IMG\" bs=1024 count=4096 2>/dev/null
        mkfs.fat -F 12 \"\$EFI_IMG\" >/dev/null 2>&1
        mmd -i \"\$EFI_IMG\" ::/EFI
        mmd -i \"\$EFI_IMG\" ::/EFI/BOOT
        mcopy -i \"\$EFI_IMG\" /tmp/bootaa64.efi ::/EFI/BOOT/BOOTAA64.EFI

        # Assemble ISO directory
        rm -rf \"\$ISO_DIR\"
        mkdir -p \"\$ISO_DIR/boot/grub/efi\" \"\$ISO_DIR/boot/protos\"
        cp \"\$OUT/Image\" \"\$ISO_DIR/boot/protos/vmlinuz\"
        cp \"\$OUT/initramfs.cpio.gz\" \"\$ISO_DIR/boot/protos/initramfs.gz\"
        cp \"\$EFI_IMG\" \"\$ISO_DIR/boot/grub/efi/efiboot.img\"
        cp /tmp/grub-embed.cfg \"\$ISO_DIR/boot/grub/grub.cfg\"

        # Generate ISO
        xorriso -as mkisofs \\
            -o \"\$OUT/protos-0.1.0-arm64.iso\" \\
            -iso-level 3 \\
            -J -joliet-long \\
            -V 'PROTOS_0_1_0' \\
            -append_partition 2 0xef \"\$EFI_IMG\" \\
            -e boot/grub/efi/efiboot.img \\
            -no-emul-boot \\
            -partition_offset 16 \\
            \"\$ISO_DIR\" 2>&1 | tail -3
    "

    ok "ISO ready: $OUT_DIR/protos-0.1.0-arm64.iso ($(du -h "$OUT_DIR/protos-0.1.0-arm64.iso" | cut -f1))"
}

do_iso() {
    banner
    mkdir -p "$BUILD_DIR" "$OUT_DIR" "$DOWNLOAD_DIR"

    if [ ! -f "$OUT_DIR/Image" ] || [ ! -f "$OUT_DIR/initramfs.cpio.gz" ]; then
        error "Run './build.sh build' first to compile kernel and rootfs"
    fi

    setup_lima
    build_iso

    echo ""
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}  ProtOS ISO ready!${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo ""
    echo "  ISO: $OUT_DIR/protos-0.1.0-arm64.iso"
    echo ""
    echo "  Write to USB:  dd if=out/protos-0.1.0-arm64.iso of=/dev/sdX bs=4M status=progress"
    echo "  Boot in QEMU:  ./boot.sh --iso"
    echo ""
}

do_clean() {
    info "Cleaning build artifacts..."
    rm -rf "$BUILD_DIR/rootfs" "$BUILD_DIR/linux-"* "$BUILD_DIR/busybox-"* "$OUT_DIR"
    ok "Cleaned"
}

do_distclean() {
    info "Cleaning everything (including downloads and VM)..."
    rm -rf "$BUILD_DIR" "$OUT_DIR"
    limactl stop "$LIMA_VM" 2>/dev/null || true
    limactl delete "$LIMA_VM" 2>/dev/null || true
    ok "Cleaned"
}

do_vm_stop() {
    info "Stopping build VM..."
    limactl stop "$LIMA_VM" 2>/dev/null || true
    ok "Build VM stopped"
}

case "${1:-build}" in
    build)     do_build ;;
    iso)       do_iso ;;
    clean)     do_clean ;;
    distclean) do_distclean ;;
    vm-stop)   do_vm_stop ;;
    *)
        echo "Usage: $0 {build|iso|clean|distclean|vm-stop}"
        echo ""
        echo "  build      - Build ProtOS from source (default)"
        echo "  iso        - Generate bootable EFI ISO image"
        echo "  clean      - Remove build artifacts (keep downloads)"
        echo "  distclean  - Remove everything including downloads and build VM"
        echo "  vm-stop    - Stop the build VM (saves resources)"
        exit 1
        ;;
esac

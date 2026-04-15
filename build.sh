#!/bin/bash
# ProtOS Build Script - Fully Standalone ARM64 Linux OS
# Compiles Linux kernel and BusyBox from source using a Lima Linux VM
set -e

clear


PROTOS_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROTOS_DIR/build"
OUT_DIR="$PROTOS_DIR/out"
SRC_DIR="$PROTOS_DIR/src"
DOWNLOAD_DIR="$BUILD_DIR/downloads"

# clear old temp lib/lib64/bin/sbin files created in build dir
rm -rf $PROTOS_DIR/bin $PROTOS_DIR/sbin $PROTOS_DIR/lib $PROTOS_DIR/lib64 

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

        # Configure kernel - start with defconfig, then apply the customizations
        rm -rf \$BUILD_DIR/linux-\${KERNEL_VERSION}/.config
        echo '[CONFIG] Generating kernel config...'
        make ARCH=arm64 defconfig

        # Enable key features for the OS
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
        ./scripts/config --enable CONFIG_DRM
        ./scripts/config --enable CONFIG_DRM_VIRTIO_GPU
        ./scripts/config --enable CONFIG_DRM_GEM_SHMEM_HELPER
        ./scripts/config --enable CONFIG_FB
        ./scripts/config --enable CONFIG_INPUT_EVDEV
        ./scripts/config --enable CONFIG_INPUT_KEYBOARD
        ./scripts/config --enable CONFIG_INPUT_MOUSE
        ./scripts/config --enable CONFIG_TMPFS_POSIX_ACL

        # NVMe support
        ./scripts/config --enable CONFIG_BLK_DEV_NVME
        ./scripts/config --enable CONFIG_NVME_CORE

        # CDROM support
        ./scripts/config --enable CONFIG_CDROM
        ./scripts/config --enable CONFIG_BLK_DEV_SR

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

        # Squashfs support (for disk-based ISO rootfs)
        ./scripts/config --enable CONFIG_SQUASHFS
        ./scripts/config --enable CONFIG_SQUASHFS_ZLIB
        ./scripts/config --enable CONFIG_SQUASHFS_LZ4
        ./scripts/config --enable CONFIG_SQUASHFS_ZSTD

        # OverlayFS (writable layer over read-only squashfs)
        ./scripts/config --enable CONFIG_OVERLAY_FS

        # ISO9660 (mount the ISO from within initramfs)
        ./scripts/config --enable CONFIG_ISO9660_FS
        ./scripts/config --enable CONFIG_JOLIET

        # Loop device (for mounting images)
        ./scripts/config --enable CONFIG_BLK_DEV_LOOP

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
        

        # Build kernel
        echo '[BUILD] Compiling kernel (using all CPU cores)...'
        make ARCH=arm64 Image -j\$(nproc) 2>&1 

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

build_gui() {
    info "Building GUI stack (Hyprland + kitty terminal)..."
    
    lima_exec "
        set -e
        BUILD='$BUILD_DIR'
        GUI_PREFIX=\"\$BUILD/gui-install\"
        mkdir -p \$GUI_PREFIX/include \$GUI_PREFIX/lib

        sudo apt-get update -qq
        sudo apt-get install -y -qq \
            cmake meson ninja-build pkg-config g++ \
            git ca-certificates \
            libwayland-dev wayland-protocols \
            libdrm-dev libinput-dev libxkbcommon-dev \
            libpixman-1-dev libcairo2-dev libpango1.0-dev \
            libegl-dev libgles-dev libgbm-dev \
            libseat-dev libudev-dev libdisplay-info-dev \
            libtomlplusplus-dev libliftoff-dev \
            libfreetype-dev libfontconfig-dev \
            libharfbuzz-dev libfcft-dev \
            hwdata glslang-tools \
            libxml2-dev libsystemd-dev \
            fonts-liberation \
            libxcb-composite0-dev libxcb-dri3-dev libxcb-present-dev \
            libxcb-render0-dev libxcb-shm0-dev libxcb-xfixes0-dev \
            libxcb-xinput-dev libxcb-icccm4-dev \
            libxcb-res0-dev \
            libxcb-ewmh-dev xwayland \
            libpcre2-dev uuid-dev libpugixml-dev libglvnd-dev libxrandr-dev \
            libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxkbfile-dev libxkbcommon-x11-dev libx11-xcb-dev \

            2>&1
        
        export PKG_CONFIG_PATH=\$GUI_PREFIX/lib/pkgconfig:\$GUI_PREFIX/lib/aarch64-linux-gnu/pkgconfig:\$GUI_PREFIX/share/pkgconfig:\${PKG_CONFIG_PATH:-}
        export CMAKE_PREFIX_PATH=\$GUI_PREFIX
        export CFLAGS=\"-I\$GUI_PREFIX/include\"
        export CXXFLAGS=\"-I\$GUI_PREFIX/include\"
        export LDFLAGS=\"-L\$GUI_PREFIX/lib -L\$GUI_PREFIX/lib/aarch64-linux-gnu\"

                # seatd
        if [ ! -f \$GUI_PREFIX/bin/seatd ]; then
            echo \"  -> Building seatd...\"
            cd /tmp
            rm -rf seatd
            git clone --depth 1 --branch 0.8.0 https://git.sr.ht/~kennylevinsen/seatd
            cd seatd
            meson setup build --prefix=\$GUI_PREFIX \
                -Dlibseat-logind=disabled -Dlibseat-seatd=enabled \
                -Dlibseat-builtin=enabled -Dserver=enabled
            ninja -C build -j\$(nproc)
            ninja -C build install
        fi


        # wlroots 0.17.4
        if [ ! -f \$GUI_PREFIX/lib/libwlroots.so ]; then
            info2() { echo \"  -> Building wlroots...\"; }; info2
            cd /tmp
            rm -rf wlroots-0.17.4
            wget -q https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.17.4/wlroots-0.17.4.tar.gz
            tar xzf wlroots-0.17.4.tar.gz
            cd wlroots-0.17.4
            meson setup build \
                --prefix=\$GUI_PREFIX \
                --libdir=lib \
                -Dexamples=false \
                -Dxwayland=enabled \
                -Dbackends=drm,libinput \
                -Drenderers=gles2
            ninja -C build -j\$(nproc)
            ninja -C build install
        fi

        # hyprutils
        if [ ! -f \$GUI_PREFIX/lib/hyprutils.so ]; then
            echo \"  -> Building hyprutils...\"
            cd /tmp
            rm -rf hyprutils
            git clone --depth 1 --branch v0.2.3 https://github.com/hyprwm/hyprutils.git
            cd hyprutils
            cmake -B build \
                -DCMAKE_INSTALL_PREFIX=\$GUI_PREFIX \
                -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j\$(nproc)
            cmake --install build
        fi

        # hyprlang
        if [ ! -f \$GUI_PREFIX/lib/libhyprlang.so ]; then
            echo \"  -> Building hyprlang...\"
            cd /tmp
            rm -rf hyprlang
            git clone --depth 1 --branch v0.5.2 https://github.com/hyprwm/hyprlang.git
            cd hyprlang
            cmake -B build \
                -DCMAKE_INSTALL_PREFIX=\$GUI_PREFIX \
                -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j\$(nproc)
            cmake --install build
        fi

        # hyprwayland-scanner
        if [ ! -f \$GUI_PREFIX/bin/hyprwayland-scanner ]; then
        echo \"  -> Building hyprwayland-scanner...\"
            cd /tmp
            rm -rf hyprwayland-scanner
            git clone --depth 1 --branch v0.4.0 https://github.com/hyprwm/hyprwayland-scanner.git
            cd hyprwayland-scanner
            cmake -B build \
                -DCMAKE_INSTALL_PREFIX=\$GUI_PREFIX \
                -DCMAKE_BUILD_TYPE=Release
            cmake --build build -j\$(nproc)
            cmake --install build
        fi

        # Hyprland
        if [ ! -f \$GUI_PREFIX/bin/Hyprland ]; then
            echo \"  -> Building Hyprland...\"
            if ! g++ -std=c++23 -x c++ -c /dev/null -o /dev/null 2>/dev/null; then
                sudo apt-get install -y -qq g++-13 2>&1 | tail -1
                export CXX=g++-13
                export CC=gcc-13
            fi
            cd /tmp
            rm -rf Hyprland
            git clone --recursive --depth 1 --branch v0.34.0 https://github.com/hyprwm/Hyprland.git
            cd Hyprland
            cmake -B build \
                -DCMAKE_INSTALL_PREFIX=\$GUI_PREFIX \
                -DCMAKE_BUILD_TYPE=Release \
                -DNO_XWAYLAND=OFF
            cmake --build build -j\$(nproc)
            cmake --install build
            cp -f /tmp/Hyprland/build/Hyprland \$GUI_PREFIX/bin/ 2>/dev/null || true
            cp -f /tmp/Hyprland/build/hyprctl/hyprctl \$GUI_PREFIX/bin/ 2>/dev/null || true
        fi

        # kitty
        if [ ! -f \$GUI_PREFIX/bin/kitty ]; then
            echo \"  -> Building kitty...\"
            sudo apt-get install -y -qq \
                libfontconfig-dev libfreetype-dev libharfbuzz-dev \
                libpng-dev liblcms2-dev libxxhash-dev libcrypt-dev \
                python3-dev golang libdbus-1-dev libsimde-dev \
                2>&1 | tail -1
            cd /tmp
            rm -rf kitty
            wget -q https://github.com/kovidgoyal/kitty/releases/download/v0.35.2/kitty-0.35.2.tar.xz
            tar xf kitty-0.35.2.tar.xz

            # update simde headers
            cd /tmp
            rm -rf simde
            git clone --depth 1 https://github.com/simd-everywhere/simde.git
            sudo cp -a simde/simde /usr/include

            cd kitty-0.35.2
            CFLAGS=\"-Wno-error \$CFLAGS\" python3 setup.py linux-package \
                --prefix=\$GUI_PREFIX \
                --update-check-interval=0 \
                --extra-include-dirs=\$GUI_PREFIX/include \
                --extra-library-dirs=\$GUI_PREFIX/lib
            if [ -d linux-package ]; then 
                cp -a linux-package/* \$GUI_PREFIX/
            fi
        
        fi

        # DejaVu fonts
        FONT_DIR=\$GUI_PREFIX/share/fonts/TTF
        mkdir -p \$FONT_DIR
        if [ ! -f \$FONT_DIR/DejaVuSansMono.ttf ]; then
            echo \"  -> Installing DejaVu fonts...\"
            cd /tmp
            wget -q -O dejavu.tar.bz2 https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2
            tar xf dejavu.tar.bz2
            cp dejavu-fonts-ttf-2.37/ttf/*.ttf \$FONT_DIR/
            rm -rf dejavu-fonts-ttf-2.37 dejavu.tar.bz2
        fi

        echo \"GUI stack build complete!\"
        "

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


    # Install protopkg package manager
    info "Installing protopkg package manager..."
    cp "$SRC_DIR/usr/bin/protopkg" "$ROOTFS/usr/bin/protopkg"
    chmod +x "$ROOTFS/usr/bin/protopkg"
    cp "$SRC_DIR/usr/bin/protopkg-build" "$ROOTFS/usr/bin/protopkg-build"
    chmod +x "$ROOTFS/usr/bin/protopkg-build"
    mkdir -p "$ROOTFS/var/lib/protopkg/installed"
    mkdir -p "$ROOTFS/var/cache/protopkg"

    # install GUI (hyprland + kitty + lins)
    info "Installing GUI components..."
    local GUI_PREFIX="$BUILD_DIR/gui-install"
    if [ -d "$GUI_PREFIX" ]; then
        # copy binaries
        for bin in Hyprland hyprctl kitty seatd; do
            if [ -f "$GUI_PREFIX/bin/$bin" ]; then
                rm -f "$ROOTFS/usr/bin/$bin"
                cp "$GUI_PREFIX/bin/$bin" "$ROOTFS/usr/bin/$bin"
                chmod +x "$ROOTFS/usr/bin/$bin"
            fi
        done
        # copy shared libraeies
        mkdir -p "$ROOTFS/usr/lib"
        cp -a "$GUI_PREFIX/lib/"*.so* "$ROOTFS/usr/lib/" 2>/dev/null || true
        cp -a "$GUI_PREFIX/lib/aarch64-linux-gnu/"*.so* "$ROOTFS/usr/lib" 2>/dev/null || true

        # copy libdrn, mesa, etc. subdirs
        [ -d "$GUI_PREFIX/lib/dri" ] && cp -a "$GUI_PREFIX/lib/dri" "$ROOTFS/usr/lib"

        # copy wayland protocols and pkgconfig (needed for runtime)
        mkdir -p "$ROOTFS/usr/share"
        [ -d "$GUI_PREFIX/share/wayland" ] && cp -a "$GUI_PREFIX/share/wayland" "$ROOTFS/usr/share"

        # Copy important hyprland files
        [ -d "$GUI_PREFIX/share/hyprland" ] && cp -a "$GUI_PREFIX/share/hyprland" "$ROOTFS/usr/share"

        # copying other shit, these comments are probably just making me look unprofessional
        [ -d "$GUI_PREFIX/share/fonts" ] && cp -a "$GUI_PREFIX/share/fonts" "$ROOTFS/usr/share"

        [ -d "$GUI_PREFIX/share/X11" ] && cp -a "$GUI_PREFIX/share/X11" "$ROOTFS/usr/share"

        # install configs (Hyprland looks for $XDG_CONFIG_HOME/hypr/ not hyprland/)
        mkdir -p "$ROOTFS/etc/hypr" "$ROOTFS/etc/kitty"
        cp "$SRC_DIR/etc/kitty/kitty.conf" "$ROOTFS/etc/kitty"
        cp "$SRC_DIR/etc/hyprland/hyprland.conf" "$ROOTFS/etc/hypr/hyprland.conf"

        [ -d "$GUI_PREFIX/lib/kitty" ] && cp -a "$GUI_PREFIX/lib/kitty" "$ROOTFS/usr/lib"
        [ -d "$GUI_PREFIX/share/kitty" ] && cp -a "$GUI_PREFIX/share/kitty" "$ROOTFS/usr/share"

        # install start script
        cp "$SRC_DIR/usr/bin/start-hyprland" "$ROOTFS/usr/bin/start-hyprland"
        chmod +x "$ROOTFS/usr/bin/start-hyprland"

        # dynamic linker and system libs from Lima VM (these don't exist on macOS)
        # Note: /lib is a symlink to usr/lib in merged-usr, so put everything in usr/lib
        lima_exec "
            ROOTFS='$BUILD_DIR/rootfs'
            GUI_PREFIX='$BUILD_DIR/gui-install'

            # Copy dynamic linker into usr/lib (since /lib -> usr/lib in merged-usr)
            INTERP=\$(find /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu -name 'ld-linux-aarch64.so.1' 2>/dev/null | head -1)
            if [ -n \"\$INTERP\" ]; then
                cp \"\$INTERP\" \"\$ROOTFS/usr/lib/ld-linux-aarch64.so.1\"
            fi

            # Copy all system shared libraries needed by Hyprland, seatd, kitty
            for lib in libc.so.6 libm.so.6 libdl.so.2 librt.so.1 libpthread.so.0 libgcc_s.so.1 libstdc++.so.6 libsystemd.so.0 libwayland-server.so.0 libwayland-client.so.0 libEGL.so.1 libGLESv2.so.2 libOpenGL.so.0 libGLdispatch.so.0 libxcb.so.1 libX11.so.6 libXext.so.6 libdrm.so.2 libxkbcommon.so.0 libinput.so.10 libpixman-1.so.0 libcairo.so.2 libpango-1.0.so.0 libpangocairo-1.0.so.0 libpangoft2-1.0.so.0 libgobject-2.0.so.0 libglib-2.0.so.0 libffi.so.8 libevdev.so.2 libmtdev.so.1 libseat.so.1 libudev.so.1 libgbm.so.1 libfontconfig.so.1 libfreetype.so.6 libharfbuzz.so.0 libpng16.so.16 liblcms2.so.2 libdbus-1.so.3 libexpat.so.1 libz.so.1 libpcre2-8.so.0 libfribidi.so.0 libXau.so.6 libXdmcp.so.6 libbsd.so.0 libmd.so.0 libcap.so.2 liblzma.so.5 libzstd.so.1 libgcrypt.so.20 libgpg-error.so.0 libgio-2.0.so.0 libgmodule-2.0.so.0 libcrypto.so.3 libXrender.so.1 libxcb-render.so.0 libxcb-shm.so.0 libxcb-composite.so.0 libxcb-ewmh.so.2 libxcb-icccm.so.4 libxcb-res.so.0 libxcb-xfixes.so.0 libthai.so.0 libdatrie.so.1 libgraphite2.so.3 libbrotlidec.so.1 libbrotlicommon.so.1 liblz4.so.1 libblkid.so.1 libmount.so.1 libbz2.so.1.0 libdisplay-info.so.1 libliftoff.so.0 libgudev-1.0.so.0 libwacom.so.9 libselinux.so.1 libEGL_mesa.so.0 libGLX_mesa.so.0 libxcb-randr.so.0 libxcb-dri2.so.0 libxcb-dri3.so.0 libxcb-present.so.0 libxcb-sync.so.1 libxcb-glx.so.0 libxshmfence.so.1 libwayland-egl.so.1 libdrm_amdgpu.so.1 libedit.so.2 libicudata.so.74 libicuuc.so.74 libsensors.so.5 libtinfo.so.6 libxml2.so.2 libX11-xcb.so.1; do
                src=\$(find /lib/aarch64-linux-gnu /usr/lib/aarch64-linux-gnu -name \"\$lib\" 2>/dev/null | head -1)
                [ -n \"\$src\" ] && cp \"\$src\" \"\$ROOTFS/usr/lib/\" 2>/dev/null || true
            done

            # Copy wlroots from gui-install (it was 'not found' in ldd)
            cp \"\$GUI_PREFIX/lib/\"libwlroots*.so* \"\$ROOTFS/usr/lib/\" 2>/dev/null || true
            cp \"\$GUI_PREFIX/lib/\"libhypr*.so* \"\$ROOTFS/usr/lib/\" 2>/dev/null || true
            cp \"\$GUI_PREFIX/lib/\"libseat*.so* \"\$ROOTFS/usr/lib/\" 2>/dev/null || true

            # Copy Mesa DRI drivers for software rendering in VMs
            # Mesa 25.x uses libdril_dri.so (shim) + libgallium-*.so (actual driver)
            mkdir -p \"\$ROOTFS/usr/lib/dri\"
            cp /usr/lib/aarch64-linux-gnu/dri/libdril_dri.so \"\$ROOTFS/usr/lib/dri/\" 2>/dev/null || true
            # Create symlinks that Mesa looks for
            for drv in swrast_dri.so kms_swrast_dri.so virtio_gpu_dri.so; do
                ln -sf libdril_dri.so \"\$ROOTFS/usr/lib/dri/\$drv\"
            done
            # Also copy from gui-install if mesa was built there
            [ -d \"\$GUI_PREFIX/lib/dri\" ] && cp \"\$GUI_PREFIX/lib/dri/\"*.so \"\$ROOTFS/usr/lib/dri/\" 2>/dev/null || true

            # Copy libgallium (the actual Mesa gallium megadriver, loaded by libdril_dri.so)
            cp /usr/lib/aarch64-linux-gnu/libgallium-*.so \"\$ROOTFS/usr/lib/\" 2>/dev/null || true

            # Copy libLLVM (needed for llvmpipe software renderer)
            for llvmlib in libLLVM.so.20.1 libLLVM.so.20 libLLVM-20.so libLLVM.so.1; do
                src=\$(find /usr/lib/aarch64-linux-gnu -name \"\$llvmlib\" 2>/dev/null | head -1)
                [ -n \"\$src\" ] && cp \"\$src\" \"\$ROOTFS/usr/lib/\" && break
            done

            # Copy libelf (needed by libgallium/LLVM)
            src=\$(find /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu -name 'libelf.so.1' -o -name 'libelf-*.so' 2>/dev/null | head -1)
            [ -n \"\$src\" ] && cp \"\$src\" \"\$ROOTFS/usr/lib/libelf.so.1\"
        "

        # Create ld.so.conf so dynamic linker finds libs in /usr/lib
        echo "/usr/lib" > "$ROOTFS/etc/ld.so.conf"

        # Create GLVND EGL vendor manifest so libEGL.so.1 can find Mesa's EGL
        mkdir -p "$ROOTFS/usr/share/glvnd/egl_vendor.d"
        cat > "$ROOTFS/usr/share/glvnd/egl_vendor.d/50_mesa.json" << 'EOFGL'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_mesa.so.0"
    }
}
EOFGL

        ok "GUI components installed"
    else
        warn "GUI not built - skipping (run scripts/build-gui.sh first)"
    fi

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
    echo "video:x:44:root" >> "$ROOTFS/etc/group"
    echo "input:x:104:root" >> "$ROOTFS/etc/group"
    echo "render:x:106:root" >> "$ROOTFS/etc/group"
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

        sudo rm -rf \"\$TMPROOT\"
        mkdir -p \"\$TMPROOT\"

        mkdir -p \"\$TMPROOT\"/{bin,sbin,dev,proc,sys,tmp,run,mnt,usr/bin,usr/sbin,usr/lib}
        cd \"\$TMPROOT\"
        ln -sf usr/lib lib
        ln -sf usr/lib lib64

        # copy busybox
        cp \"\$ROOTFS/usr/bin/busybox\" \"\$TMPROOT/bin/busybox\"
        chmod +x \"\$TMPROOT/bin/busybox\"

        for cmd in sh mount umount mkdir ls cat echo sleep switch_root mdev findfs; do
            ln -sf busybox \"\$TMPROOT/bin/\$cmd\"
        done

        cp '$SRC_DIR/init-iso' \"\$TMPROOT/init\"
        chmod +x \"\$TMPROOT/init\"

        cd \"\$TMPROOT\"
        sudo chown -R 0:0 \"\$TMPROOT\"
        find . | cpio -H newc -o --quiet 2>/dev/null | gzip -9 > \"\$OUT/initramfs.cpio.gz\"

        sudo rm -rf \"\$TMPROOT\"

    "
    ok "initramfs created: $OUT_DIR/initramfs.cpio.gz ($(du -h "$OUT_DIR/initramfs.cpio.gz" | cut -f1))"
}

create_squashfs() {
    info "Creating squashfs root filesystem image..."
    mkdir -p "$OUT_DIR"

    lima_exec "
       set -e
       ROOTFS='$BUILD_DIR/rootfs'
       OUT='$OUT_DIR'
       TMPROOT='/tmp/protos-rootfs-squash'

       which mksquashfs >/dev/null 2>&1 || sudo apt-get install -q squashfs-tools

       sudo rm -rf \"\$TMPROOT\"
       mkdir -p \"\$TMPROOT\"
       cd \"\$ROOTFS\"
       tar cf - . | (cd \"\$TMPROOT\" && tar xf -)

       cd \"\$TMPROOT\"
       rm -rf bin sbin lib lib64 2>/dev/null || true
       ln -sf usr/bin bin
       ln -sf usr/sbin sbin
       ln -sf usr/lib lib
       ln -sf usr/lib lib64

       chmod +x \"\$TMPROOT/init\"
       find \"\$TMPROOT/usr/bin\" -type f -exec chmod +x {} +
       find \"\$TMPROOT/usr/sbin\" -type f -exec chmod +x {} +
       find \"\$TMPROOT/usr/lib\" -type f -exec chmod +x {} +
       chmod +x \"\$TMPROOT/etc/shell-login\" \"\$TMPROOT/etc/init.d/rcS\" \"\$TMPROOT/etc/udhcpc.sh\" 2>/dev/null || true
       chmod +x \"\$TMPROOT/etc/installer.sh\" 2>/dev/null || true
       chmod +x \"\$TMPROOT/etc/install_protos.sh\" 2>/dev/null || true
       chmod +x \"\$TMPROOT/usr/bin/start-hyprland\" 2>/dev/null || true

       # fix terminfo case sensitivity
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

        sudo chown -R 0:0 \"\$TMPROOT\"
        
        sudo rm -rf \"\$OUT/rootfs.squashfs\"
        sudo mksquashfs \"\$TMPROOT\" \"\$OUT/rootfs.squashfs\" -comp zstd -Xcompression-level 15 -noappend

        sudo rm -rf \"\$TMPROOT\"
    "

    ok "Squashfs created: $OUT_DIR/rootfs.squashfs ($(du -h "$OUT_DIR/rootfs.squashfs" | cut -f1))"
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
    build_gui
    build_rootfs
    create_initramfs
    create_squashfs

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
        cp \"\$OUT/rootfs.squashfs\" \"\$ISO_DIR/boot/protos/rootfs.squashfs\" 
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

    if [ ! -f "$OUT_DIR/Image" ] || [ ! -f "$OUT_DIR/initramfs.cpio.gz" ] || [ ! -f "$OUT_DIR/rootfs.squashfs" ]; then
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
    echo "  Boot in QEMU:  ./bisoot.sh"
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

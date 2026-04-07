#!/bin/bash
# ProtOS Boot Script - Launch in QEMU
set -e

PROTOS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$PROTOS_DIR/out"
KERNEL="$OUT_DIR/Image"
INITRAMFS="$OUT_DIR/initramfs.cpio.gz"

# Check QEMU is installed
if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "Error: qemu-system-aarch64 not found"
    echo "Install with: brew install qemu"
    exit 1
fi

# Check build artifacts exist
if [ ! -f "$KERNEL" ] || [ ! -f "$INITRAMFS" ]; then
    echo "Error: ProtOS not built yet. Run './build.sh' first."
    exit 1
fi

EXTRA_ARGS=""
APPEND="console=ttyAMA0 rdinit=/init loglevel=3 quiet"
BUILD_DIR="$PROTOS_DIR/build"
DISK_IMG="$BUILD_DIR/protos-test-disk.qcow2"

case "${1:-}" in
    --install)
        # Create a virtual disk in build/ for installation testing
        mkdir -p "$BUILD_DIR"
        if [ ! -f "$DISK_IMG" ]; then
            echo "Creating 2GB virtual disk for installation testing..."
            qemu-img create -f qcow2 "$DISK_IMG" 2G
        fi
        EXTRA_ARGS="-drive file=$DISK_IMG,format=qcow2,if=virtio"
        APPEND="console=ttyAMA0 rdinit=/init protos.mode=install loglevel=3"
        ;;
    --disk)
        # Boot from existing installed test disk
        if [ ! -f "$DISK_IMG" ]; then
            echo "Error: No test disk found. Run './boot.sh --install' first."
            exit 1
        fi
        EXTRA_ARGS="-drive file=$DISK_IMG,format=qcow2,if=virtio"
        APPEND="console=ttyAMA0 rdinit=/init loglevel=3 quiet"
        ;;
    --iso)
        ISO="$OUT_DIR/protos-0.1.0-arm64.iso"
        if [ ! -f "$ISO" ]; then
            echo "Error: ISO not found. Run './build.sh iso' first."
            exit 1
        fi
        EXTRA_ARGS="-drive file=$ISO,format=raw,if=virtio,readonly=on"
        ;;
esac

echo "Starting ProtOS..."
echo "(Press Ctrl-A then X to exit QEMU)"
echo ""

qemu-system-aarch64 \
    -M virt \
    -cpu cortex-a72 \
    -m 512M \
    -nographic \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -append "$APPEND" \
    $EXTRA_ARGS

# ProtOS - ARM64 Linux-based OS
# Build system for compiling kernel, rootfs, and bootable image

SHELL := /bin/bash
.PHONY: all clean kernel busybox rootfs boot deps

# Versions
KERNEL_VERSION := 6.12.8
BUSYBOX_VERSION := 1.36.1

# Directories
BUILD_DIR := $(CURDIR)/build
SRC_DIR := $(CURDIR)/src
ROOTFS_DIR := $(BUILD_DIR)/rootfs
DOWNLOAD_DIR := $(BUILD_DIR)/downloads
OUT_DIR := $(CURDIR)/out

# Cross-compilation (on macOS we use a Linux container or cross tools)
ARCH := arm64
CROSS_COMPILE := aarch64-linux-gnu-

# Kernel URLs
KERNEL_URL := https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz
BUSYBOX_URL := https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2

all: kernel rootfs
	@echo ""
	@echo "========================================="
	@echo "  ProtOS build complete!"
	@echo "  Run 'make boot' to start ProtOS"
	@echo "========================================="

dirs:
	@mkdir -p $(BUILD_DIR) $(SRC_DIR) $(ROOTFS_DIR) $(DOWNLOAD_DIR) $(OUT_DIR)

# Download sources
$(DOWNLOAD_DIR)/linux-$(KERNEL_VERSION).tar.xz: | dirs
	@echo "[DOWNLOAD] Linux kernel $(KERNEL_VERSION)..."
	curl -L -o $@ $(KERNEL_URL)

$(DOWNLOAD_DIR)/busybox-$(BUSYBOX_VERSION).tar.bz2: | dirs
	@echo "[DOWNLOAD] BusyBox $(BUSYBOX_VERSION)..."
	curl -L -o $@ $(BUSYBOX_URL)

# Extract sources
$(BUILD_DIR)/linux-$(KERNEL_VERSION)/.extracted: $(DOWNLOAD_DIR)/linux-$(KERNEL_VERSION).tar.xz
	@echo "[EXTRACT] Linux kernel..."
	tar xf $< -C $(BUILD_DIR)
	touch $@

$(BUILD_DIR)/busybox-$(BUSYBOX_VERSION)/.extracted: $(DOWNLOAD_DIR)/busybox-$(BUSYBOX_VERSION).tar.bz2
	@echo "[EXTRACT] BusyBox..."
	tar xf $< -C $(BUILD_DIR)
	touch $@

# Build kernel
kernel: $(OUT_DIR)/Image

$(OUT_DIR)/Image: $(BUILD_DIR)/linux-$(KERNEL_VERSION)/.extracted $(SRC_DIR)/kernel.config
	@echo "[BUILD] Linux kernel for ARM64..."
	cp $(SRC_DIR)/kernel.config $(BUILD_DIR)/linux-$(KERNEL_VERSION)/.config
	$(MAKE) -C $(BUILD_DIR)/linux-$(KERNEL_VERSION) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) olddefconfig
	$(MAKE) -C $(BUILD_DIR)/linux-$(KERNEL_VERSION) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) Image -j$$(nproc)
	cp $(BUILD_DIR)/linux-$(KERNEL_VERSION)/arch/arm64/boot/Image $(OUT_DIR)/Image

# Build BusyBox (statically linked)
busybox: $(BUILD_DIR)/busybox-$(BUSYBOX_VERSION)/.built

$(BUILD_DIR)/busybox-$(BUSYBOX_VERSION)/.built: $(BUILD_DIR)/busybox-$(BUSYBOX_VERSION)/.extracted $(SRC_DIR)/busybox.config
	@echo "[BUILD] BusyBox (static)..."
	cp $(SRC_DIR)/busybox.config $(BUILD_DIR)/busybox-$(BUSYBOX_VERSION)/.config
	$(MAKE) -C $(BUILD_DIR)/busybox-$(BUSYBOX_VERSION) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) oldconfig
	$(MAKE) -C $(BUILD_DIR)/busybox-$(BUSYBOX_VERSION) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) install -j$$(nproc)
	touch $@

# Build root filesystem (initramfs)
rootfs: $(OUT_DIR)/initramfs.cpio.gz

$(OUT_DIR)/initramfs.cpio.gz: busybox $(SRC_DIR)/init
	@echo "[BUILD] Root filesystem..."
	rm -rf $(ROOTFS_DIR)
	mkdir -p $(ROOTFS_DIR)/{bin,sbin,etc,proc,sys,dev,tmp,usr/bin,usr/sbin,var/log,root,mnt}
	# Install busybox
	cp -a $(BUILD_DIR)/busybox-$(BUSYBOX_VERSION)/_install/* $(ROOTFS_DIR)/
	# Install init script
	cp $(SRC_DIR)/init $(ROOTFS_DIR)/init
	chmod +x $(ROOTFS_DIR)/init
	# Install additional config files
	cp $(SRC_DIR)/etc/os-release $(SRC_DIR)/etc/hostname $(SRC_DIR)/etc/motd $(SRC_DIR)/etc/profile $(SRC_DIR)/etc/inittab $(SRC_DIR)/etc/shell-login $(ROOTFS_DIR)/etc/
	chmod +x $(ROOTFS_DIR)/etc/shell-login
	cp $(SRC_DIR)/etc/init.d/rcS $(ROOTFS_DIR)/etc/init.d/rcS
	chmod +x $(ROOTFS_DIR)/etc/init.d/rcS
	# Install installer
	cp $(SRC_DIR)/installer.sh $(ROOTFS_DIR)/etc/installer.sh
	chmod +x $(ROOTFS_DIR)/etc/installer.sh
	# Create initramfs
	cd $(ROOTFS_DIR) && find . | cpio -H newc -o 2>/dev/null | gzip > $(OUT_DIR)/initramfs.cpio.gz
	@echo "[OK] initramfs.cpio.gz created"

# Boot ProtOS in QEMU
boot:
	@echo "Starting ProtOS..."
	qemu-system-aarch64 \
		-M virt \
		-cpu cortex-a72 \
		-m 512M \
		-nographic \
		-kernel $(OUT_DIR)/Image \
		-initrd $(OUT_DIR)/initramfs.cpio.gz \
		-append "console=ttyAMA0 rdinit=/init loglevel=3 quiet"

# Download sources only
download: $(DOWNLOAD_DIR)/linux-$(KERNEL_VERSION).tar.xz $(DOWNLOAD_DIR)/busybox-$(BUSYBOX_VERSION).tar.bz2

clean:
	rm -rf $(BUILD_DIR) $(OUT_DIR)

distclean: clean
	rm -rf $(BUILD_DIR)/downloads

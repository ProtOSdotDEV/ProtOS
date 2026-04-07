#!/bin/bash
# Build pacman and all dependencies as static binaries for ProtOS
# This runs INSIDE the Lima VM
set -e

BUILD_DIR="${1:?Usage: build-pacman.sh BUILD_DIR}"
DOWNLOAD_DIR="$BUILD_DIR/downloads"
PACMAN_PREFIX="$BUILD_DIR/pacman-install"
SYSROOT="$BUILD_DIR/pacman-sysroot"

# Versions
ZLIB_VERSION="1.3.1"
ZSTD_VERSION="1.5.6"
OPENSSL_VERSION="3.3.2"
NGHTTP2_VERSION="1.64.0"
CURL_VERSION="8.11.1"
LIBARCHIVE_VERSION="3.7.7"
LIBGPG_ERROR_VERSION="1.51"
LIBASSUAN_VERSION="3.0.1"
GPGME_VERSION="1.24.1"
PACMAN_VERSION="6.1.0"

# URLs
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
NGHTTP2_URL="https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.xz"
CURL_URL="https://curl.se/download/curl-${CURL_VERSION}.tar.xz"
LIBARCHIVE_URL="https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VERSION}/libarchive-${LIBARCHIVE_VERSION}.tar.xz"
LIBGPG_ERROR_URL="https://gnupg.org/ftp/gcrypt/libgpg-error/libgpg-error-${LIBGPG_ERROR_VERSION}.tar.bz2"
LIBASSUAN_URL="https://gnupg.org/ftp/gcrypt/libassuan/libassuan-${LIBASSUAN_VERSION}.tar.bz2"
GPGME_URL="https://gnupg.org/ftp/gcrypt/gpgme/gpgme-${GPGME_VERSION}.tar.bz2"
PACMAN_URL="https://gitlab.archlinux.org/pacman/pacman/-/releases/v${PACMAN_VERSION}/downloads/pacman-${PACMAN_VERSION}.tar.xz"

NPROC=$(nproc)

info()  { echo "[INFO] $1"; }
ok()    { echo "[OK] $1"; }
error() { echo "[ERROR] $1"; exit 1; }

mkdir -p "$DOWNLOAD_DIR" "$SYSROOT"/{lib,include} "$PACMAN_PREFIX"

export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"
export CFLAGS="-I$SYSROOT/include -Os"
export CPPFLAGS="-I$SYSROOT/include"
export LDFLAGS="-L$SYSROOT/lib -static"

download() {
    local url="$1" dest="$2"
    if [ ! -f "$dest" ]; then
        info "Downloading $(basename "$dest")..."
        curl -L -# -o "$dest" "$url"
    fi
}

extract() {
    local archive="$1" dir="$2"
    if [ ! -d "$dir" ]; then
        info "Extracting $(basename "$archive")..."
        mkdir -p /tmp/extract-$$
        tar xf "$archive" -C /tmp/extract-$$
        mv /tmp/extract-$$/* "$dir"
        rm -rf /tmp/extract-$$
    fi
}

# ============================================================
# 0. ZLIB
# ============================================================
build_zlib() {
    download "$ZLIB_URL" "$DOWNLOAD_DIR/zlib-${ZLIB_VERSION}.tar.gz"
    extract "$DOWNLOAD_DIR/zlib-${ZLIB_VERSION}.tar.gz" "$BUILD_DIR/zlib-${ZLIB_VERSION}"

    if [ ! -f "$SYSROOT/lib/libz.a" ]; then
        info "Building zlib ${ZLIB_VERSION}..."
        cd "$BUILD_DIR/zlib-${ZLIB_VERSION}"
        ./configure --prefix="$SYSROOT" --static 2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "zlib built"
    else
        ok "zlib already built"
    fi
}

# ============================================================
# 1. ZSTD
# ============================================================
build_zstd() {
    download "$ZSTD_URL" "$DOWNLOAD_DIR/zstd-${ZSTD_VERSION}.tar.gz"
    extract "$DOWNLOAD_DIR/zstd-${ZSTD_VERSION}.tar.gz" "$BUILD_DIR/zstd-${ZSTD_VERSION}"

    if [ ! -f "$SYSROOT/lib/libzstd.a" ]; then
        info "Building zstd ${ZSTD_VERSION}..."
        cd "$BUILD_DIR/zstd-${ZSTD_VERSION}"
        make -j$NPROC lib-release 2>&1 | tail -3
        cp lib/libzstd.a "$SYSROOT/lib/"
        cp lib/zstd.h lib/zstd_errors.h lib/zdict.h "$SYSROOT/include/"
        # Create pkg-config file
        mkdir -p "$SYSROOT/lib/pkgconfig"
        cat > "$SYSROOT/lib/pkgconfig/libzstd.pc" << EOF
prefix=$SYSROOT
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: zstd
Description: Zstandard compression
Version: ${ZSTD_VERSION}
Libs: -L\${libdir} -lzstd
Cflags: -I\${includedir}
EOF
        ok "zstd built"
    else
        ok "zstd already built"
    fi
}

# ============================================================
# 2. OpenSSL
# ============================================================
build_openssl() {
    download "$OPENSSL_URL" "$DOWNLOAD_DIR/openssl-${OPENSSL_VERSION}.tar.gz"
    extract "$DOWNLOAD_DIR/openssl-${OPENSSL_VERSION}.tar.gz" "$BUILD_DIR/openssl-${OPENSSL_VERSION}"

    if [ ! -f "$SYSROOT/lib/libssl.a" ]; then
        info "Building openssl ${OPENSSL_VERSION}..."
        cd "$BUILD_DIR/openssl-${OPENSSL_VERSION}"
        ./Configure linux-aarch64 \
            --prefix="$SYSROOT" \
            --openssldir="$SYSROOT/ssl" \
            no-shared \
            no-tests \
            no-docs \
            -Os 2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install_sw 2>&1 | tail -3
        ok "openssl built"
    else
        ok "openssl already built"
    fi
}

# ============================================================
# 3. nghttp2
# ============================================================
build_nghttp2() {
    download "$NGHTTP2_URL" "$DOWNLOAD_DIR/nghttp2-${NGHTTP2_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/nghttp2-${NGHTTP2_VERSION}.tar.xz" "$BUILD_DIR/nghttp2-${NGHTTP2_VERSION}"

    if [ ! -f "$SYSROOT/lib/libnghttp2.a" ]; then
        info "Building nghttp2 ${NGHTTP2_VERSION}..."
        cd "$BUILD_DIR/nghttp2-${NGHTTP2_VERSION}"
        ./configure \
            --prefix="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --enable-lib-only \
            --disable-python-bindings \
            2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "nghttp2 built"
    else
        ok "nghttp2 already built"
    fi
}

# ============================================================
# 4. libcurl
# ============================================================
build_curl() {
    download "$CURL_URL" "$DOWNLOAD_DIR/curl-${CURL_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/curl-${CURL_VERSION}.tar.xz" "$BUILD_DIR/curl-${CURL_VERSION}"

    if [ ! -f "$SYSROOT/lib/libcurl.a" ]; then
        info "Building curl ${CURL_VERSION}..."
        cd "$BUILD_DIR/curl-${CURL_VERSION}"
        ./configure \
            --prefix="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --with-openssl="$SYSROOT" \
            --with-nghttp2="$SYSROOT" \
            --without-libpsl \
            --without-libidn2 \
            --without-brotli \
            --disable-ldap \
            --disable-rtsp \
            --disable-dict \
            --disable-telnet \
            --disable-tftp \
            --disable-pop3 \
            --disable-imap \
            --disable-smb \
            --disable-smtp \
            --disable-gopher \
            --disable-mqtt \
            --disable-manual \
            --disable-docs \
            2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "curl built"
    else
        ok "curl already built"
    fi
}

# ============================================================
# 5. libarchive
# ============================================================
build_libarchive() {
    download "$LIBARCHIVE_URL" "$DOWNLOAD_DIR/libarchive-${LIBARCHIVE_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/libarchive-${LIBARCHIVE_VERSION}.tar.xz" "$BUILD_DIR/libarchive-${LIBARCHIVE_VERSION}"

    if [ ! -f "$SYSROOT/lib/libarchive.a" ]; then
        info "Building libarchive ${LIBARCHIVE_VERSION}..."
        cd "$BUILD_DIR/libarchive-${LIBARCHIVE_VERSION}"
        ./configure \
            --prefix="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --without-xml2 \
            --without-expat \
            --with-zstd \
            --without-lz4 \
            --without-lzma \
            CFLAGS="-I$SYSROOT/include -Os" \
            LDFLAGS="-L$SYSROOT/lib" \
            2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "libarchive built"
    else
        ok "libarchive already built"
    fi
}

# ============================================================
# 6. libgpg-error
# ============================================================
build_libgpg_error() {
    download "$LIBGPG_ERROR_URL" "$DOWNLOAD_DIR/libgpg-error-${LIBGPG_ERROR_VERSION}.tar.bz2"
    extract "$DOWNLOAD_DIR/libgpg-error-${LIBGPG_ERROR_VERSION}.tar.bz2" "$BUILD_DIR/libgpg-error-${LIBGPG_ERROR_VERSION}"

    if [ ! -f "$SYSROOT/lib/libgpg-error.a" ]; then
        info "Building libgpg-error ${LIBGPG_ERROR_VERSION}..."
        cd "$BUILD_DIR/libgpg-error-${LIBGPG_ERROR_VERSION}"
        ./configure \
            --prefix="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --disable-nls \
            --disable-doc \
            --disable-tests \
            2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "libgpg-error built"
    else
        ok "libgpg-error already built"
    fi
}

# ============================================================
# 7. libassuan
# ============================================================
build_libassuan() {
    download "$LIBASSUAN_URL" "$DOWNLOAD_DIR/libassuan-${LIBASSUAN_VERSION}.tar.bz2"
    extract "$DOWNLOAD_DIR/libassuan-${LIBASSUAN_VERSION}.tar.bz2" "$BUILD_DIR/libassuan-${LIBASSUAN_VERSION}"

    if [ ! -f "$SYSROOT/lib/libassuan.a" ]; then
        info "Building libassuan ${LIBASSUAN_VERSION}..."
        cd "$BUILD_DIR/libassuan-${LIBASSUAN_VERSION}"
        ./configure \
            --prefix="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --disable-doc \
            --with-libgpg-error-prefix="$SYSROOT" \
            2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "libassuan built"
    else
        ok "libassuan already built"
    fi
}

# ============================================================
# 8. GPGME
# ============================================================
build_gpgme() {
    download "$GPGME_URL" "$DOWNLOAD_DIR/gpgme-${GPGME_VERSION}.tar.bz2"
    extract "$DOWNLOAD_DIR/gpgme-${GPGME_VERSION}.tar.bz2" "$BUILD_DIR/gpgme-${GPGME_VERSION}"

    if [ ! -f "$SYSROOT/lib/libgpgme.a" ]; then
        info "Building gpgme ${GPGME_VERSION}..."
        cd "$BUILD_DIR/gpgme-${GPGME_VERSION}"
        ./configure \
            --prefix="$SYSROOT" \
            --enable-static \
            --disable-shared \
            --disable-gpg-test \
            --disable-g13-test \
            --disable-gpgsm-test \
            --disable-gpgconf-test \
            --disable-languages \
            --with-libgpg-error-prefix="$SYSROOT" \
            --with-libassuan-prefix="$SYSROOT" \
            2>&1 | tail -3
        make -j$NPROC 2>&1 | tail -3
        make install 2>&1 | tail -3
        ok "gpgme built"
    else
        ok "gpgme already built"
    fi
}

# ============================================================
# 9. PACMAN
# ============================================================
build_pacman() {
    download "$PACMAN_URL" "$DOWNLOAD_DIR/pacman-${PACMAN_VERSION}.tar.xz"
    extract "$DOWNLOAD_DIR/pacman-${PACMAN_VERSION}.tar.xz" "$BUILD_DIR/pacman-${PACMAN_VERSION}"

    if [ ! -f "$PACMAN_PREFIX/bin/pacman" ]; then
        info "Building pacman ${PACMAN_VERSION}..."
        cd "$BUILD_DIR/pacman-${PACMAN_VERSION}"

        # Install meson if not available
        if ! command -v meson &>/dev/null; then
            sudo apt-get install -y -qq meson ninja-build 2>&1 | tail -1
        fi

        # Clean any previous build
        rm -rf builddir

        # Ensure pkg-config is installed
        if ! command -v pkg-config &>/dev/null; then
            sudo apt-get install -y -qq pkg-config 2>&1 | tail -1
        fi

        # Configure with meson
        PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig" \
        meson setup builddir \
            --prefix="$PACMAN_PREFIX" \
            --default-library=static \
            --prefer-static \
            -Dbuildtype=release \
            -Ddoc=disabled \
            -Ddoxygen=disabled \
            -Di18n=false \
            -Dscriptlet-shell=/bin/sh \
            -Dldconfig=/bin/true \
            -Dc_link_args="-L$SYSROOT/lib -static -lgpg-error -lassuan -lz" \
            2>&1 | tail -15

        # Build
        ninja -C builddir -j$NPROC 2>&1 | tail -10

        # Install - meson install can fail on macOS mounts, so do manual install
        ninja -C builddir install 2>&1 | tail -5 || true

        # Manual install of key binaries if meson install failed
        mkdir -p "$PACMAN_PREFIX/bin"
        for bin in pacman pacman-conf vercmp testpkg cleanupdelta; do
            [ -f "builddir/$bin" ] && cp "builddir/$bin" "$PACMAN_PREFIX/bin/"
        done
        # Copy shell scripts from meson install or source
        for script in makepkg makepkg-template pacman-db-upgrade pacman-key repo-add; do
            if [ ! -f "$PACMAN_PREFIX/bin/$script" ]; then
                [ -f "scripts/$script.sh.in" ] || continue
            fi
        done
        # Copy libalpm config
        mkdir -p "$PACMAN_PREFIX/etc"
        [ -f "etc/pacman.conf" ] && cp etc/pacman.conf "$PACMAN_PREFIX/etc/" || true

        ok "pacman built"
    else
        ok "pacman already built"
    fi
}

# ============================================================
# Main
# ============================================================
info "Building pacman and dependencies (static)..."
info "Build dir: $BUILD_DIR"
info "Sysroot:   $SYSROOT"

build_zlib
build_zstd
build_openssl
build_nghttp2
build_curl
build_libarchive
build_libgpg_error
build_libassuan
build_gpgme
build_pacman

ok "All pacman components built successfully"
echo ""
echo "Pacman installed to: $PACMAN_PREFIX"
ls -la "$PACMAN_PREFIX/bin/" 2>/dev/null

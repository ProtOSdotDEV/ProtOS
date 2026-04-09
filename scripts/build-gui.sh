#!bin/bash
# ProtOS GUI Build script
# Builds wayland + hyprland + kitty from source
set -e

BUILD_DIR="${1:?Usage: build-gui.sh <build-dir>}"
PREFIX="$BUILD_DIR/gui-install"
SRC="$BUILD_DIR/gui-src"
JOBS=$(nproc)

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/aarch64-linux-gnu/pkgconfig:$PREFIX/share/pkgconfig"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/aarch64-linux-gnu"
export PATH="$PREFIX/bin:$PATH"
export CFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -L$PREFIX/lib/aarch64-linux-gnu"
export CMAKE_PREFIX_PATH="$PREFIX"

mkdir -p "$PREFIX" "$SRC"

info()  { echo -e "\033[0;34m[GUI]\033[0m $1"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m $1"; }

# install build tools in lima
info "Installing build dependencies..."
sudo apt-get update -qq 
sudo apt-get install -y -qq \
    meson ninja-build cmake pkg-config \
    python3-pip python3-jinja2 \
    libffi-dev libexpat1-dev libxml2-dev \
    flex bison glslang-tools \
    hwdata \
    2>&1
ok "Build tools installed"

fetch() {
    local name="$1" url="$2" dir="$3"
    if [ ! -d "$SRC/$dir" ]; then
        info "Downloading $name..."
        wget -q -O "$SRC/$name.tar.gz" "$url"
        cd "$SRC"
        tar xf "$name.tar.gz"
        rm "$name.tar.gz"
    fi
}

# libffi
LIBFFI_VER="3.4.6"
fetch "libfii" "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VER}/libffi-${LIBFFI_VER}.tar.gz" "libffi-${LIBFFI_VER}"
if [ ! -f "$PREFIX/lib/libffi.so" ]; then
    info "Building libffi..."
    cd "$SRC/libffi-${LIBFFI_VER}"
    ./configure --prefix="$PREFIX" --disable-static
    make -j$JOBS && make install
    ok "libffi built"
fi

# expat
EXPAT_VER="2.6.2"
fetch "expat" "https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-${EXPAT_VER}.tar.gz" "expat-${EXPAT_VER}"
if [ ! -f "$PREFIX/lib/libexpat.so" ]; then
    info "Building expat..."
    cd "$SRC/expat-${EXPAT_VER}"
    ./configure --prefix="$PREFIX" --disable-static
    make -j$JOBS && make install
    ok "expat built"
fi

# wayland
WAYLAND_VER="1.22.0"
fetch "wayland" "https://gitlab.freedesktop.org/wayland/wayland/-/releases/${WAYLAND_VER}/downloads/wayland-${WAYLAND_VER}.tar.zx" "wayland-${WAYLAND_VER}"
if [ ! -f "$PREFIX/lib/libwayland-server.so" ]; then
    info "Building wayland..."
    cd "$SRC/wayland-${WAYLAND_VER}"
    meson setup builddir --prefix="$PREFIX" -Ddocumentation=false -Dtests=false
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "wayland built"
fi

# wayland-protocols
WYLNPRT_VER="1.33"
fetch "wayland-protocols
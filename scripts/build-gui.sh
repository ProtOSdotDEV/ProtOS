#!/bin/bash
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
fetch "libffi" "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VER}/libffi-${LIBFFI_VER}.tar.gz" "libffi-${LIBFFI_VER}"
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
fetch "wayland" "https://gitlab.freedesktop.org/wayland/wayland/-/releases/${WAYLAND_VER}/downloads/wayland-${WAYLAND_VER}.tar.xz" "wayland-${WAYLAND_VER}"
if [ ! -f "$PREFIX/lib/libwayland-server.so" ]; then
    info "Building wayland..."
    cd "$SRC/wayland-${WAYLAND_VER}"
    meson setup builddir --prefix="$PREFIX" -Ddocumentation=false -Dtests=false
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "wayland built"
fi

# wayland-protocols
WYLNPRT_VER="1.33"
fetch "wayland-protocols" "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/${WYLNPRT_VER}/downloads/wayland-protocols-${WYLNPRT_VER}.tar.xz" "wayland-protocols-${WYLNPRT_VER}"
if [ ! -f "$PREFIX/share/pkgconfig/wayland-protocols.pc" ]; then
    info "Building wayland-protocols..."
    cd "$SRC/wayland-protocols-${WYLNPRT_VER}"
    meson setup builddir --prefix="$PREFIX" -Dtests=false
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "wayland-protocols built."
fi

# libdrm
LIBDRM_VER="2.4.120"
fetch "libdrm" "https://dri.freedesktop.org/libdrm/libdrm-${LIBDRM_VER}.tar.xz" "libdrm-${LIBDRM_VER}"
if [ ! -f "$PREFIX/lib/libdrm.so" ]; then
    info "building libdrm..."
    cd "$SRC/libdrm-${LIBDRM_VER}"
    meson setup builddir --prefix="$PREFIX" \
        -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled \
        -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled \
        -Detnaviv=disabled -Dtests=false -Dman-pages=disabled
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "libdrm built"
fi

#  pixman 
PIXMAN_VER="0.43.4"
fetch "pixman" "https://www.cairographics.org/releases/pixman-${PIXMAN_VER}.tar.gz" "pixman-${PIXMAN_VER}"
if [ ! -f "$PREFIX/lib/libpixman-1.so" ]; then
    info "Building pixman..."
    cd "$SRC/pixman-${PIXMAN_VER}"
    meson setup builddir --prefix="$PREFIX" -Dtests=disabled -Ddemos=disabled
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "pixman built"
fi

# seatd 
SEATD_VER="0.8.0"
fetch "seatd" "https://git.sr.ht/~kennylevinsen/seatd/archive/${SEATD_VER}.tar.gz" "seatd-${SEATD_VER}"
if [ ! -f "$PREFIX/lib/libseat.so" ]; then
    info "Building seatd..."
    cd "$SRC/seatd-${SEATD_VER}"
    meson setup builddir --prefix="$PREFIX" \
        -Dlibseat-logind=disabled -Dlibseat-seatd=enabled \
        -Dlibseat-builtin=enabled -Dserver=enabled
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "seatd built."
fi

#libevdev
LIBEVDEV_VER="1.13.2"
fetch "libevdev" "https://www.freedesktop.org/software/libevdev/libevdev-${LIBEVDEV_VER}.tar.xz" "libevdev-${LIBEVDEV_VER}"
if [ ! -f "$PREFIX/lib/libevdev.so" ]; then
    info "Building libevdev..."
    cd "$SRC/libevdev-${LIBEVDEV_VER}"
    meson setup builddir --prefix="$PREFIX" -Dtests=disabled -Ddocumentation=disabled
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "libevdev built"
fi

# mtdev 
MTDEV_VER="1.1.7"
fetch "mtdev" "https://bitmath.org/code/mtdev/mtdev-${MTDEV_VER}.tar.bz2" "mtdev-${MTDEV_VER}"
if [ ! -f "$PREFIX/lib/libmtdev.so" ]; then
    info "Building mtdev..."
    cd "$SRC/mtdev-${MTDEV_VER}"
    ./configure --prefix="$PREFIX" --disable-static
    make -j$JOBS && make install
    ok "mtdev built"
fi

# libinput
LIBINPUT_VER="1.25.0"
fetch "libinput" "https://gitlab.freedesktop.org/libinput/libinput/-/archive/${LIBINPUT_VER}/libinput-${LIBINPUT_VER}.tar.gz" "libinput-${LIBINPUT_VER}"
if [ ! -f "$PREFIX/lib/libinput.so" ]; then
    info "Building libinput..."
    cd "$SRC/libinput-${LIBINPUT_VER}"
    meson setup builddir --prefix="$PREFIX" \
        -Dlibwacom=false -Ddebug-gui=false -Dtests=false -Ddocumentation=false
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "libinput built"
fi

# libxkbcommon
XKBCOMMON_VER="1.7.0"
fetch "libxkbcommon" "https://xkbcommon.org/download/libxkbcommon-${XKBCOMMON_VER}.tar.xz" "libxkbcommon-${XKBCOMMON_VER}"
if [ ! -f "$PREFIX/lib/libxkbcommon.so" ]; then
    info "Building libxkbcommon..."
    cd "$SRC/libxkbcommon-${XKBCOMMON_VER}"
    meson setup builddir --prefix="$PREFIX" \
        -Denable-x11=false -Denable-docs=false -Denable-tools=false
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "libxkbcommon built"
fi

# mesa
MESA_VER="24.0.5"
fetch "mesa" "https://archive.mesa3d.org/mesa-${MESA_VER}.tar.xz" "mesa-${MESA_VER}"
if [ ! -f "$PREFIX/lib/libEGL.so" ]; then
    info "Building mesa (this takes a while)..."
    cd "$SRC/mesa-${MESA_VER}"
    meson setup builddir --prefix="$PREFIX" \
        -Dplatforms=wayland \
        -Dgallium-drivers=swrast,virgl \
        -Dvulkan-drivers= \
        -Dglx=disabled \
        -Degl=enabled \
        -Dgles2=enabled \
        -Dllvm=disabled \
        -Dshared-glapi=enabled \
        -Dgbm=enabled
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "mesa built"
fi

# wlroots
# Hyprland 0.34 uses wlroots 0.17.x
WLROOTS_VER="0.17.4"
if [ ! -d "$SRC/wlroots-${WLROOTS_VER}" ]; then
    info "Downloading wlroots..."
    cd "$SRC"
    wget -q -O wlroots.tar.gz "https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/${WLROOTS_VER}/wlroots-${WLROOTS_VER}.tar.gz"
    tar xf wlroots.tar.gz && rm wlroots.tar.gz
fi
if [ ! -f "$PREFIX/lib/libwlroots.so" ]; then
    info "Building wlroots..."
    cd "$SRC/wlroots-${WLROOTS_VER}"
    meson setup builddir --prefix="$PREFIX" \
        -Dbackends=drm,libinput \
        -Drenderers=gles2 \
        -Dxwayland=disabled \
        -Dexamples=false
    ninja -C builddir -j$JOBS && ninja -C builddir install
    ok "wlroots built"
fi

# hyprland
HYPRLAND_VER="0.34.0"
if [ ! -d "$SRC/Hyprland-${HYPRLAND_VER}" ]; then
    info "Downloading Hyprland..."
    cd "$SRC"
    wget -q -O hyprland.tar.gz "https://github.com/hyprwm/Hyprland/releases/download/v${HYPRLAND_VER}/source-v${HYPRLAND_VER}.tar.gz"
    tar xf hyprland.tar.gz && rm hyprland.tar.gz
fi
if [ ! -f "$PREFIX/bin/Hyprland" ]; then
    info "Building Hyprland (needs C++23)..."
    # Ensure we have a modern enough compiler
    if ! g++ -std=c++23 -x c++ -c /dev/null -o /dev/null 2>/dev/null; then
        sudo apt-get install -y -qq g++-13 2>&1 | tail -1
        export CXX=g++-13
        export CC=gcc-13
    fi
    cd "$SRC/Hyprland-${HYPRLAND_VER}"
    cmake -B build \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DNO_XWAYLAND=ON
    cmake --build build -j$JOBS
    cmake --install build
    ok "Hyprland built"
fi

# kitty
KITTY_VER="0.35.2"
sudo apt-get install -y -qq \
    libfontconfig-dev  libfreetype-dev libharfbuzz-dev \
    libpng-dev liblcms2-dev libxxhash-dev libcrypt-dev \
    python3-dev golang libdbus-1-dev libsimde-dev \
    2>&1 

if [ ! -d "$SRC/kitty-${KITTY_VER}" ]; then
    info "Downloading kitty..."
    cd "$SRC"
    wget -q -O kitty.tar.xz "https://github.com/kovidgoyal/kitty/releases/download/v${KITTY_VER}/kitty-${KITTY_VER}.tar.xz"
    tar xf kitty.tar.xz && rm kitty.tar.xz
fi

if [ ! -f "$PREFIX/bin/kitty" ]; then
    info "Building kitty..."
    cd "$SRC/kitty-${KITTY_VER}"
    python3 setup.py linux-package \
        --prefix="$PREFIX" \
        --update-check-interval=0 \
        --extra-include-dirs="$PREFIX/include" \
        --extra-library-dirs="$PREFIX/lib"
    cp -a linux-package/* "$PREFIX/"
    ok "kitty built"
fi

# fonts
FONT_DIR="$PREFIX/share/fonts/TTF"
mkdir -p "$FONT_DIR"
if [ ! -f "$FONT_DIR/DejaVuSansMono.ttf" ]; then
    info "Downloading DejaVu fonts..."
    cd /tmp
    wget -q -O dejavu.tar.bz2 "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2"
    tar xf dejavu.tar.bz2
    cp dejavu-fonts-ttf-2.37/ttf/*.ttf "$FONT_DIR/"
    rm -rf dejavu-fonts-ttf-2.37 dejavu.tar.bz2
    ok "Fonts installed"
fi

echo ""
ok "GUI stack build complete!"
echo "  Prefix: $PREFIX"
echo "  Run 'ls $PREFIX/bin' to see installed binaries"


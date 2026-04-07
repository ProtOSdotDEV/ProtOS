#!/bin/bash
# Build a test protpkg repository with a statically compiled nano
set -e

BUILD_DIR="${1:-/Users/skxlldxggy/ProtOS/build}"
REPO_DIR="$BUILD_DIR/protpkg-repo"

echo "[INFO] Building test protpkg repository..."
mkdir -p "$REPO_DIR"

# Build static nano inside Lima VM
echo "[INFO] Building static nano..."
limactl shell protos-builder bash -c "
    set -e
    BUILD='$BUILD_DIR'
    REPO='$REPO_DIR'

    NANO_VERSION='8.3'
    NCURSES_VERSION='6.5'

    # Build static ncurses first (nano needs it)
    if [ ! -f \"\$BUILD/ncurses-\${NCURSES_VERSION}/lib/libncursesw.a\" ]; then
        cd /tmp
        if [ ! -f \"\$BUILD/downloads/ncurses-\${NCURSES_VERSION}.tar.gz\" ]; then
            echo '[INFO] Downloading ncurses...'
            wget -q -O \"\$BUILD/downloads/ncurses-\${NCURSES_VERSION}.tar.gz\" \
                \"https://ftp.gnu.org/gnu/ncurses/ncurses-\${NCURSES_VERSION}.tar.gz\"
        fi
        tar xf \"\$BUILD/downloads/ncurses-\${NCURSES_VERSION}.tar.gz\"
        mv ncurses-\${NCURSES_VERSION} \"\$BUILD/ncurses-\${NCURSES_VERSION}\"
        cd \"\$BUILD/ncurses-\${NCURSES_VERSION}\"
        echo '[CONFIG] Configuring ncurses...'
        ./configure \
            --without-shared \
            --with-normal \
            --without-debug \
            --without-ada \
            --without-cxx \
            --without-cxx-binding \
            --enable-widec \
            --with-terminfo-dirs='/etc/terminfo:/usr/share/terminfo' \
            --with-default-terminfo-dir='/usr/share/terminfo' \
            --disable-database \
            --with-fallbacks=linux,vt100,xterm,xterm-256color,dumb \
            CFLAGS='-Os' \
            2>&1 | tail -3
        echo '[BUILD] Compiling ncurses...'
        make -j\$(nproc) 2>&1 | tail -3
    fi

    # Build static nano
    if [ ! -f \"\$BUILD/nano-\${NANO_VERSION}/src/nano\" ]; then
        cd /tmp
        if [ ! -f \"\$BUILD/downloads/nano-\${NANO_VERSION}.tar.xz\" ]; then
            echo '[INFO] Downloading nano...'
            wget -q -O \"\$BUILD/downloads/nano-\${NANO_VERSION}.tar.xz\" \
                \"https://www.nano-editor.org/dist/v8/nano-\${NANO_VERSION}.tar.xz\"
        fi
        tar xf \"\$BUILD/downloads/nano-\${NANO_VERSION}.tar.xz\"
        mv nano-\${NANO_VERSION} \"\$BUILD/nano-\${NANO_VERSION}\"
        cd \"\$BUILD/nano-\${NANO_VERSION}\"
        echo '[CONFIG] Configuring nano...'
        NCURSES_DIR=\"\$BUILD/ncurses-\${NCURSES_VERSION}\"
        CFLAGS=\"-Os -I\${NCURSES_DIR}/include -I\${NCURSES_DIR}/include/ncursesw\" \
        LDFLAGS=\"-static -L\${NCURSES_DIR}/lib\" \
        LIBS=\"-lncursesw\" \
        NCURSESW_CFLAGS=\"-I\${NCURSES_DIR}/include/ncursesw\" \
        NCURSESW_LIBS=\"-L\${NCURSES_DIR}/lib -lncursesw\" \
        ./configure \
            --enable-utf8 \
            --disable-nls \
            --disable-browser \
            --disable-speller \
            2>&1 | tail -3
        echo '[BUILD] Compiling nano...'
        make -j\$(nproc) 2>&1 | tail -3
    fi

    # Verify it's static
    if file \"\$BUILD/nano-\${NANO_VERSION}/src/nano\" | grep -q 'statically linked'; then
        echo '[OK] nano is statically linked'
    else
        echo '[WARN] nano may not be fully static'
        file \"\$BUILD/nano-\${NANO_VERSION}/src/nano\"
    fi

    # Create the protpkg package
    echo '[PKG] Creating nano package...'
    PKGDIR='/tmp/protpkg-nano'
    rm -rf \"\$PKGDIR\"
    mkdir -p \"\$PKGDIR/data/usr/bin\"
    mkdir -p \"\$PKGDIR/data/usr/share/nano\"
    cp \"\$BUILD/nano-\${NANO_VERSION}/src/nano\" \"\$PKGDIR/data/usr/bin/nano\"
    chmod +x \"\$PKGDIR/data/usr/bin/nano\"

    # Copy syntax highlighting files
    cp \"\$BUILD/nano-\${NANO_VERSION}/syntax/\"*.nanorc \"\$PKGDIR/data/usr/share/nano/\" 2>/dev/null || true

    # Create PKGINFO
    cat > \"\$PKGDIR/PKGINFO\" <<PKGEOF
name=nano
version=\${NANO_VERSION}
desc=Small and friendly text editor (statically linked)
arch=aarch64
deps=-
PKGEOF

    # Calculate size
    SIZE=\$(du -sb \"\$PKGDIR/data\" | cut -f1)
    echo \"size=\$SIZE\" >> \"\$PKGDIR/PKGINFO\"

    # Build the package
    cd \"\$PKGDIR\"
    tar czf \"\$REPO/nano-\${NANO_VERSION}-aarch64.pkg.tar.gz\" PKGINFO data/
    echo '[OK] nano package created'

    # Generate checksum
    SHA=\$(sha256sum \"\$REPO/nano-\${NANO_VERSION}-aarch64.pkg.tar.gz\" | cut -d' ' -f1)

    # Build htop too for a second test package
    HTOP_VERSION='3.3.0'
    if [ ! -f \"\$BUILD/htop-\${HTOP_VERSION}/htop\" ]; then
        cd /tmp
        if [ ! -f \"\$BUILD/downloads/htop-\${HTOP_VERSION}.tar.xz\" ]; then
            echo '[INFO] Downloading htop...'
            wget -q -O \"\$BUILD/downloads/htop-\${HTOP_VERSION}.tar.xz\" \
                \"https://github.com/htop-dev/htop/releases/download/\${HTOP_VERSION}/htop-\${HTOP_VERSION}.tar.xz\"
        fi
        tar xf \"\$BUILD/downloads/htop-\${HTOP_VERSION}.tar.xz\"
        mv htop-\${HTOP_VERSION} \"\$BUILD/htop-\${HTOP_VERSION}\"
        cd \"\$BUILD/htop-\${HTOP_VERSION}\"
        echo '[CONFIG] Configuring htop...'
        NCURSES_DIR=\"\$BUILD/ncurses-\${NCURSES_VERSION}\"
        CFLAGS=\"-Os -I\${NCURSES_DIR}/include -I\${NCURSES_DIR}/include/ncursesw\" \
        LDFLAGS=\"-static -L\${NCURSES_DIR}/lib\" \
        LIBS=\"-lncursesw -lm\" \
        ./configure \
            --disable-unicode \
            --enable-static \
            2>&1 | tail -3
        echo '[BUILD] Compiling htop...'
        make -j\$(nproc) LDFLAGS='-static' 2>&1 | tail -3
    fi

    # Create htop package
    echo '[PKG] Creating htop package...'
    PKGDIR2='/tmp/protpkg-htop'
    rm -rf \"\$PKGDIR2\"
    mkdir -p \"\$PKGDIR2/data/usr/bin\"
    if [ -f \"\$BUILD/htop-\${HTOP_VERSION}/htop\" ]; then
        cp \"\$BUILD/htop-\${HTOP_VERSION}/htop\" \"\$PKGDIR2/data/usr/bin/htop\"
        chmod +x \"\$PKGDIR2/data/usr/bin/htop\"
    fi

    cat > \"\$PKGDIR2/PKGINFO\" <<PKGEOF2
name=htop
version=\${HTOP_VERSION}
desc=Interactive process viewer (statically linked)
arch=aarch64
deps=-
PKGEOF2

    SIZE2=\$(du -sb \"\$PKGDIR2/data\" | cut -f1)
    echo \"size=\$SIZE2\" >> \"\$PKGDIR2/PKGINFO\"

    cd \"\$PKGDIR2\"
    tar czf \"\$REPO/htop-\${HTOP_VERSION}-aarch64.pkg.tar.gz\" PKGINFO data/
    SHA2=\$(sha256sum \"\$REPO/htop-\${HTOP_VERSION}-aarch64.pkg.tar.gz\" | cut -d' ' -f1)
    echo '[OK] htop package created'

    # Create the PACKAGES.idx
    echo \"nano|\${NANO_VERSION}|aarch64|-|\$SIZE|\$SHA|Small and friendly text editor (statically linked)\" > \"\$REPO/PACKAGES.idx\"
    echo \"htop|\${HTOP_VERSION}|aarch64|-|\$SIZE2|\$SHA2|Interactive process viewer (statically linked)\" >> \"\$REPO/PACKAGES.idx\"

    echo ''
    echo '[OK] Repository ready at: \$REPO'
    echo 'Contents:'
    ls -lh \"\$REPO\"
    echo ''
    echo 'PACKAGES.idx:'
    cat \"\$REPO/PACKAGES.idx\"
"

echo ""
echo "[OK] Test repo built at: $REPO_DIR"

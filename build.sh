#!/bin/bash
set -e

PROJECT_DIR="/mnt/c/Users/Administrator/.gemini/antigravity/scratch/luci-app-xc-lite"
cd "$PROJECT_DIR"

echo "=== 1. ?????? ==="
BUILD_DIR="/tmp/luci-app-xc-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/data" "$BUILD_DIR/control"

# ?? root ??
cp -r root/* "$BUILD_DIR/data/"

# ?? htdocs ? www
mkdir -p "$BUILD_DIR/data/www"
cp -r htdocs/* "$BUILD_DIR/data/www/"

# 清理换行符 CRLF -> LF
find "$BUILD_DIR/data" -type f \( -name "*.lua" -o -name "*.htm" -o -name "*.js" -o -name "*.json" -o -name "xc" -o -name "luci.xc" -o -name "xc-xray" -o -name "80_luci-app-xc" \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# 设置可执行权限
chmod 0755 "$BUILD_DIR/data/usr/bin/xc"
chmod 0755 "$BUILD_DIR/data/usr/libexec/rpcd/luci.xc"
chmod 0755 "$BUILD_DIR/data/etc/init.d/xc-xray"
chmod 0755 "$BUILD_DIR/data/etc/uci-defaults/80_luci-app-xc"

# ?? control ??
cat > "$BUILD_DIR/control/control" << 'EOF'
Package: luci-app-xc
Version: 1.0.0-1
Depends: luci-base, rpcd, rpcd-mod-file
Section: luci
Architecture: all
Maintainer: deanzai
Description: LuCI Web interface for xc (Xray node switcher and router)
EOF

# ?? postinst
cat > "$BUILD_DIR/control/postinst" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    [ -d /usr/share/xray ] || mkdir -p /usr/share/xray
    [ -f /usr/share/xray/geosite.dat ] || ln -sf /root/xray/geosite.dat /usr/share/xray/geosite.dat 2>/dev/null
    [ -f /usr/share/xray/geoip.dat ] || ln -sf /root/xray/geoip.dat /usr/share/xray/geoip.dat 2>/dev/null
    chmod +x /usr/bin/xc /usr/libexec/rpcd/luci.xc /etc/init.d/xc-xray /etc/uci-defaults/80_luci-app-xc 2>/dev/null
    /etc/init.d/rpcd restart 2>/dev/null
    /etc/init.d/uhttpd restart 2>/dev/null
}
exit 0
EOF
chmod 0755 "$BUILD_DIR/control/postinst"

# ?? prerm
cat > "$BUILD_DIR/control/prerm" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    /etc/init.d/xc-xray stop 2>/dev/null
    /etc/init.d/xc-xray disable 2>/dev/null
}
exit 0
EOF
chmod 0755 "$BUILD_DIR/control/prerm"

echo "=== 2. ???? data.tar.gz ? control.tar.gz ==="
cd "$BUILD_DIR/data"
tar --owner=0 --group=0 -czf "$BUILD_DIR/data.tar.gz" *
cd "$BUILD_DIR/control"
tar --owner=0 --group=0 -czf "$BUILD_DIR/control.tar.gz" *

echo "2.0" > "$BUILD_DIR/debian-binary"

echo "=== 3. ?? OpenWrt IPK ??? ==="
cd "$BUILD_DIR"
IPK_FILE="$PROJECT_DIR/luci-app-xc_1.0.0-1_all.ipk"
tar -czf "$IPK_FILE" debian-binary control.tar.gz data.tar.gz
ls -lh "$IPK_FILE"

echo "=== 4. ?? APK ??? ==="
APK_DIR="/tmp/luci-app-xc-apk"
rm -rf "$APK_DIR"
mkdir -p "$APK_DIR"
cp -r "$BUILD_DIR/data/"* "$APK_DIR/"
cat > "$APK_DIR/.PKGINFO" << 'EOF'
pkgname = luci-app-xc
pkgver = 1.0.0-r1
pkgdesc = LuCI Web interface for xc (Xray node switcher and router)
url = https://github.com/deanzai/luci-app-xc-lite
builddate = 1725796800
packager = deanzai
size = 28672
arch = all
origin = luci-app-xc
commit = 102ea11
EOF

cd "$APK_DIR"
APK_FILE="$PROJECT_DIR/luci-app-xc-1.0.0-r1.apk"
tar --owner=0 --group=0 -czf "$APK_FILE" .PKGINFO *
ls -lh "$APK_FILE"

echo "=== ????? ==="

#!/bin/bash
set -e

PROJECT_DIR="/mnt/c/Users/Administrator/.gemini/antigravity/scratch/luci-app-xc-lite"
cd "$PROJECT_DIR"

echo "=== 1. 准备构建目录与文件 ==="
BUILD_DIR="/tmp/luci-app-xc-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/data" "$BUILD_DIR/control"

# 复制 root 目录
cp -r root/* "$BUILD_DIR/data/"

# 复制 htdocs 到 www
mkdir -p "$BUILD_DIR/data/www"
cp -r htdocs/* "$BUILD_DIR/data/www/"

# 清理换行符 CRLF -> LF
find "$BUILD_DIR/data" -type f \( -name "*.lua" -o -name "*.htm" -o -name "*.js" -o -name "*.json" -o -name "xc" -o -name "luci.xc" -o -name "xc-xray" -o -name "80_luci-app-xc" \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true

# 设置可执行权限
chmod 0755 "$BUILD_DIR/data/usr/bin/xc"
chmod 0755 "$BUILD_DIR/data/usr/libexec/rpcd/luci.xc"
chmod 0755 "$BUILD_DIR/data/etc/init.d/xc-xray"
chmod 0755 "$BUILD_DIR/data/etc/uci-defaults/80_luci-app-xc"

# 获取版本号
PKG_VER=$(grep -E '^PKG_VERSION:=' Makefile | cut -d= -f2 | tr -d ' \r\n')
PKG_REL=$(grep -E '^PKG_RELEASE:=' Makefile | cut -d= -f2 | tr -d ' \r\n')
[ -n "$PKG_VER" ] || PKG_VER="1.0.14"
[ -n "$PKG_REL" ] || PKG_REL="1"
FULL_VER="${PKG_VER}-${PKG_REL}"
APK_VER="${PKG_VER}-r${PKG_REL}"

# 生成 control 文件
cat > "$BUILD_DIR/control/control" << EOF
Package: luci-app-xc
Version: ${FULL_VER}
Depends: luci-base, rpcd, rpcd-mod-file
Section: luci
Architecture: all
Maintainer: deanzai
Description: LuCI Web interface for xc (Xray node switcher and router)
EOF

# 生成 postinst
cat > "$BUILD_DIR/control/postinst" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    mkdir -p /etc/xc/bin /etc/xc/assets /usr/share/xray 2>/dev/null
    [ -f /usr/share/xray/geosite.dat ] || ln -sf /root/xray/geosite.dat /usr/share/xray/geosite.dat 2>/dev/null
    [ -f /usr/share/xray/geoip.dat ] || ln -sf /root/xray/geoip.dat /usr/share/xray/geoip.dat 2>/dev/null
    chmod +x /usr/bin/xc /usr/libexec/rpcd/luci.xc /etc/init.d/xc-xray /etc/uci-defaults/80_luci-app-xc 2>/dev/null
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache* 2>/dev/null
    /etc/init.d/rpcd restart 2>/dev/null
    /etc/init.d/uhttpd restart 2>/dev/null
    /etc/init.d/xc-xray enable 2>/dev/null
    if [ -s /etc/xc/config.json ]; then
        /etc/init.d/xc-xray restart 2>/dev/null || true
    fi
}
exit 0
EOF
chmod 0755 "$BUILD_DIR/control/postinst"

# 生成 prerm
cat > "$BUILD_DIR/control/prerm" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
    /etc/init.d/xc-xray stop 2>/dev/null
    /etc/init.d/xc-xray disable 2>/dev/null
}
exit 0
EOF
chmod 0755 "$BUILD_DIR/control/prerm"

echo "=== 2. 打包 data.tar.gz 与 control.tar.gz ==="
cd "$BUILD_DIR/data"
tar --owner=0 --group=0 -czf "$BUILD_DIR/data.tar.gz" *
cd "$BUILD_DIR/control"
tar --owner=0 --group=0 -czf "$BUILD_DIR/control.tar.gz" *

echo "2.0" > "$BUILD_DIR/debian-binary"

echo "=== 3. 生成 OpenWrt IPK 安装包 ==="
cd "$BUILD_DIR"
IPK_FILE="$PROJECT_DIR/luci-app-xc_${FULL_VER}_all.ipk"
tar -czf "$IPK_FILE" debian-binary control.tar.gz data.tar.gz
ls -lh "$IPK_FILE"

echo "=== 4. 生成 APK 安装包 (OpenWrt 24.10+) ==="
APK_DIR="/tmp/luci-app-xc-apk"
rm -rf "$APK_DIR"
mkdir -p "$APK_DIR"
cp -r "$BUILD_DIR/data/"* "$APK_DIR/"
cat > "$APK_DIR/.PKGINFO" << EOF
pkgname = luci-app-xc
pkgver = ${APK_VER}
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
APK_FILE="$PROJECT_DIR/luci-app-xc-${APK_VER}.apk"
tar --owner=0 --group=0 -czf "$APK_FILE" .PKGINFO *
ls -lh "$APK_FILE"

echo "=== 打包编译完成 ==="

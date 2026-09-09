include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI Web interface for xc (Xray node switcher and router)
LUCI_DEPENDS:=+xray-core +curl +netstat +rpcd +rpcd-mod-file
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-xc
PKG_VERSION:=1.0.14
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

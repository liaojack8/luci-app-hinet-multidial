include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-hinet-multidial
PKG_VERSION:=1.3.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Jack

LUCI_TITLE:=HiNet staggered PPPoE multi-dial controller
LUCI_DEPENDS:=+luci-base +ppp +ppp-mod-pppoe
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

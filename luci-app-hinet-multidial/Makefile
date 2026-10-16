include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-hinet-multidial
PKG_VERSION:=1.5.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Jack

LUCI_TITLE:=HiNet staggered PPPoE multi-dial controller with per-session WireGuard egress
LUCI_DEPENDS:=+luci-base +ppp +ppp-mod-pppoe +kmod-wireguard +wireguard-tools +qrencode +firewall4
LUCI_PKGARCH:=all

# OpenWrt wraps this as prerm-pkg; default_prerm still stops the service.
define Package/luci-app-hinet-multidial/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] || exit 0
. /usr/share/hinet-multidial/lib.sh
hmd_lan_cleanup
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature

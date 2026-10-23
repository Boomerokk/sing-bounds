# Makefile — пакет luci-app-singbounds для системы сборки OpenWrt.
#
# Сборка (в SDK OpenWrt 24.10/25.x, для своей архитектуры):
#   1) скопировать этот репозиторий в package/luci-app-singbounds/
#      (или подключить как feed: feeds.conf: src-link singbounds <путь>)
#   2) make menuconfig -> LuCI -> Applications -> luci-app-singbounds
#   3) make package/luci-app-singbounds/compile V=s
# Результат: bin/packages/<arch>/luci-app-singbounds_1.2.1_all.ipk
# (на 25.x с apk — соответствующий .apk).
#
# Устанавливать пакет НЕ обязательно: install.sh из репозитория делает
# то же самое без SDK. Пакет — для тех, кто хочет штатный opkg/apk-менеджмент.
#
# sing-box НЕ является зависимостью: sing-bounds переиспользует уже
# установленный бинарник (или ставит его сам при первом запуске).

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbounds
PKG_VERSION:=1.2.1
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=Boomerokk
PKG_BUILD_DEPENDS:=

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-singbounds
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=sing-bounds: VLESS+Reality VPN server in LuCI
  DEPENDS:=+luci-base +rpcd +ucode +ucode-mod-uci
  PKGARCH:=all
  MAINTAINER:=Boomerokk
endef

define Package/luci-app-singbounds/conffiles
/etc/config/singbounds
endef

define Package/luci-app-singbounds/description
sing-bounds turns an OpenWrt router into a personal VLESS+Reality VPN
server (a mini 3X-UI) reusing the sing-box binary. Managed entirely from
LuCI: inbound/client lifecycle, per-client QR codes and vless:// links,
virtual IPs on br-lan, firewall rules, config backup/rollback.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

# Файлы пакета = содержимое files/ репозитория как корень ФС роутера,
# плюс правила запуска/остановки через init.
define Package/luci-app-singbounds/install
	$(INSTALL_DIR) $(1)/usr/lib/sing-bounds
	$(INSTALL_BIN) ./files/backend/backend.sh $(1)/usr/lib/sing-bounds/
	$(INSTALL_BIN) ./files/backend/firewall.sh $(1)/usr/lib/sing-bounds/
	$(INSTALL_BIN) ./files/backend/vip.sh $(1)/usr/lib/sing-bounds/
	$(INSTALL_BIN) ./files/backend/netbounds.uc $(1)/usr/lib/sing-bounds/
	$(INSTALL_BIN) ./files/backend/render.uc $(1)/usr/lib/sing-bounds/
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/backend/singbounds-ctl $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/rpcd/singbounds $(1)/usr/libexec/rpcd/
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/init.d/singbounds $(1)/etc/init.d/
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/menu.d/luci-app-singbounds.json $(1)/usr/share/luci/menu.d/
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/acl.d/luci-app-singbounds.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbounds
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/singbounds/app.js $(1)/www/luci-static/resources/view/singbounds/
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/singbounds/qrcode.js $(1)/www/luci-static/resources/view/singbounds/
	# UCI-конфиг создаётся при первом запуске (сервис создаёт global-секцию).
endef

define Package/luci-app-singbounds/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# регистрация ubus-объекта и пункта меню LuCI
/etc/init.d/rpcd reload 2>/dev/null || true
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache* 2>/dev/null || true
exit 0
endef

define Package/luci-app-singbounds/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# аккуратно остановить сервис перед удалением (данные UCI НЕ трогаем:
# удаление конфига — осознанный выбор юзера через LuCI-кнопку uninstall)
/etc/init.d/singbounds stop 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,luci-app-singbounds))

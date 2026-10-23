#!/bin/sh
# install.sh — установщик sing-bounds «одной командой».
#
# ЗАПУСК:
#   1) Из чекаута репо (репо скопирован на роутер целиком, например в
#      /tmp/sing-bounds-install):
#        cd /tmp/sing-bounds-install && sh install.sh
#      или с явным путём к репо:   sh /путь/install.sh /путь/к/репо
#   2) Одной командой без файлов рядом (GitHub-режим):
#        wget -qO- https://raw.githubusercontent.com/sing-bounds/sing-bounds/main/install.sh | sh
#      установщик сам скачивает архив main-ветки и распаковывает его.
#
# ЧТО ДЕЛАЕТ:
#   umask 022 -> PM-детект (apk/opkg, имена пакетов одинаковые) +
#   установка curl и ca-bundle ДО source-детекта (GitHub-режим качает
#   архив curl'ом: busybox wget на чистом роутере падает по TLS) ->
#   источник -> остальные зависимости (uhttpd-mod-ubus, ucode-mod-*) ->
#   проверка/установка sing-box -> бэкап /etc/config/firewall ->
#   копирование файлов по карте путей (web UI /www/singbounds СТРОГО
#   раньше sb_webui_install: uhttpd биндит docroot, иначе procd
#   crash-loop) -> UCI touch + global-секция -> sb_webui_install
#   (uhttpd-инстанс 7789) -> rpcd reload -> init enable + start ->
#   миграция stand_code + sb_stand_regen_all -> статус-отчёт.
#
# ИДЕМПОТЕНТНОСТЬ: повторный запуск обновляет файлы и НЕ дублирует
# UCI-секции (global-опции и uhttpd.singbounds — uci set канонических
# значений; init enable идемпотентен; firewall-бэкап не перезаписывается
# и хранит состояние ДО первой установки; sb_fw_* идемпотентны по name).
#
# ПОДДЕРЖКА: OpenWrt 24.x (opkg) и 25.x (apk). POSIX sh (busybox ash),
# без bash-измов. Требует root. Карта путей едина для install и
# uninstall.

# --------------------------------------------------------------- утилиты ---

sb_log()  { printf ' * %s\n' "$*"; }
sb_warn() { printf ' ! %s\n' "$*" >&2; }
sb_die()  { printf 'sing-bounds: ОШИБКА: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = '0' ] || sb_die 'запустите от root (ssh root@<роутер>)'

# umask 022: rpcd-окружение может нести 077, а uhttpd отдаёт статику
# только с правами на чтение (403 на 0600/0700).
# Права на каждый файл и каталог карты выставляются явно дополнительно.
umask 022

# ------------------------------------------------------ пакетный менеджер ---

# apk (OpenWrt 24.12+/25.x): бинарник — /usr/bin/apk (usrmerge;
# /bin/apk отсутствует) — проверяем PATH и оба пути. opkg — 24.10 и
# старше. Имена пакетов-зависимостей ОДИНАКОВЫ в
# 24/25 (uhttpd-mod-ubus, ucode-mod-uci, ucode-mod-fs, curl).
if command -v apk >/dev/null 2>&1 || [ -x /bin/apk ]; then
	SB_PM='apk'
	SB_PM_ADD='apk add'
elif command -v opkg >/dev/null 2>&1; then
	SB_PM='opkg'
	SB_PM_ADD='opkg install'
else
	sb_die 'не найден ни apk, ни opkg — это не OpenWrt?'
fi
sb_log "пакетный менеджер: $SB_PM"

# -------------------------------------- deps до source-детекта: curl/CA ---

# РАНЬШЕ source-детекта: GitHub-режим ниже качает архив curl'ом; на
# чистом роутере busybox wget падает по TLS (нет свежих CA/алгоритмов).
# Ставим curl + ca-bundle немедленно после umask/PM-детекта; остальное
# (uhttpd-mod-ubus, ucode-mod-*) — после выбора источника.
sb_log "curl + ca-bundle ($SB_PM_ADD) — до скачивания источника"
$SB_PM_ADD curl ca-bundle >/dev/null 2>&1 \
	|| sb_warn 'не поставились curl/ca-bundle одним вызовом — проверяю по факту'
command -v curl >/dev/null 2>&1 \
	|| sb_die "curl отсутствует — выполните вручную: $SB_PM_ADD curl ca-bundle"

# --------------------------------------------------------------- источник ---

SB_SRC="${1:-}"
SB_GH_REPO="${SB_GH_REPO:-Boomerokk/sing-bounds}"

sb_src_ok() {
	[ -n "$SB_SRC" ] && [ -f "$SB_SRC/files/backend/backend.sh" ] \
		&& [ -f "$SB_SRC/install.sh" ] \
		&& [ -f "$SB_SRC/files/www/luci-static/resources/view/singbounds/app.js" ]
}

# Явный путь не указан, но рядом (cwd) лежит чекаут — берём cwd.
if ! sb_src_ok && [ -z "$SB_SRC" ] && [ -f './files/backend/backend.sh' ]; then
	SB_SRC='.'
fi

if ! sb_src_ok; then
	# GitHub-режим: curl уже гарантирован (см. deps до source-детекта).
	SB_TMP="$(mktemp -d /tmp/sing-bounds-src.XXXXXX)" \
		|| sb_die 'не могу создать временный каталог в /tmp'
	SB_URL="https://github.com/$SB_GH_REPO/archive/refs/heads/main.tar.gz"
	sb_log "файлы репозитория рядом не найдены — GitHub-режим: $SB_URL"
	curl -fsSL --max-time 60 "$SB_URL" -o "$SB_TMP/src.tar.gz" \
		|| sb_die "не могу скачать архив (нет доступа к GitHub или репозиторий $SB_GH_REPO ещё не опубликован). Скопируйте репозиторий на роутер (например, в /tmp/sing-bounds-install) и запустите install.sh из его корня."
	tar -xzf "$SB_TMP/src.tar.gz" -C "$SB_TMP" \
		|| sb_die 'не могу распаковать архив репозитория'
	SB_NAME="$(printf '%s' "$SB_GH_REPO" | sed 's|.*/||')"
	SB_SRC="$SB_TMP/$SB_NAME-main"
	sb_src_ok || sb_die 'в архиве репозитория нет ожидаемой структуры files/'
fi
sb_log "источник файлов: $SB_SRC"

# ---------------------------------- зависимости (кроме curl, см. выше) ---

SB_PKGS='uhttpd-mod-ubus ucode-mod-uci ucode-mod-fs'
sb_log "зависимости ($SB_PM_ADD): $SB_PKGS"
# Уже установленные пакеты apk/opkg ошибкой не считаются; фактическое
# наличие критичных инструментов проверяем ниже.
$SB_PM_ADD $SB_PKGS >/dev/null 2>&1 \
	|| sb_warn 'не все зависимости поставились одним вызовом — проверяю по факту'
command -v ucode >/dev/null 2>&1 \
	|| sb_die "ucode отсутствует — выполните вручную: $SB_PM_ADD ucode-mod-uci ucode-mod-fs"
[ -r /usr/lib/ucode/uci.so ] || sb_warn 'нет /usr/lib/ucode/uci.so — проверьте ucode-mod-uci'
# uhttpd-mod-ubus: на apk-ветке (25.x) модуль собирается внутрь
# основного пакета uhttpd и файла ubus.so НЕТ — проверяем
# установленность ПАКЕТА; на opkg (24.x) — классическую файловую
# проверку.
if [ "$SB_PM" = 'apk' ]; then
	apk info -e uhttpd-mod-ubus >/dev/null 2>&1 \
		|| sb_warn 'пакет uhttpd-mod-ubus не установлен — Web UI не сможет ходить в ubus'
else
	[ -f /usr/lib/uhttpd/ubus.so ] \
		|| sb_warn 'нет /usr/lib/uhttpd/ubus.so — Web UI не сможет ходить в ubus (uhttpd-mod-ubus)'
fi

# ---------------------------------------------------------------- sing-box ---

sb_sbx_ver() {
	sing-box version 2>/dev/null | head -n 1 | awk '{print $3}'
}

# >= 1.12? (Reality-схема требует 1.12+).
sb_ver_ge_112() {
	local v maj rest min
	v="${1:-}"
	[ -n "$v" ] || return 1
	maj="${v%%.*}"
	rest="${v#*.}"
	min="${rest%%.*}"
	case "$maj" in ''|*[!0-9]*) return 1 ;; esac
	case "$min" in ''|*[!0-9]*) return 1 ;; esac
	if [ "$maj" -gt 1 ]; then return 0; fi
	if [ "$maj" -eq 1 ] && [ "$min" -ge 12 ]; then return 0; fi
	return 1
}

# sing-box отсутствует: скачать сборку по архитектуре uname -m из
# релизов shtorm-7/sing-box-tiny (tiny), затем SagerNet/sing-box
# (extended). Ветка авто-установки требует ручной проверки на роутере
# без предустановленного sing-box.
sb_sbx_install_github() {
	local arch gharch repo api dl tmpd bin
	arch="$(uname -m)"
	case "$arch" in
		aarch64)           gharch='arm64' ;;
		x86_64)            gharch='amd64' ;;
		i386|i486|i586)    gharch='386' ;;
		armv6l|armv7l)     gharch='armv7' ;;
		*) sb_warn "неизвестная архитектура $arch — авто-установка sing-box невозможна"; return 1 ;;
	esac
	tmpd="$(mktemp -d /tmp/sing-box-install.XXXXXX)" || return 1
	for repo in shtorm-7/sing-box-tiny SagerNet/sing-box; do
		api="https://api.github.com/repos/$repo/releases/latest"
		sb_log "пробую релизы $repo (linux-$gharch)"
		dl="$(curl -fsSL --max-time 30 "$api" 2>/dev/null \
			| grep -o '"browser_download_url": *"[^"]*"' | cut -d'"' -f4 \
			| grep "linux-$gharch.*\.tar\.gz$" | head -n 1)"
		[ -n "$dl" ] || continue
		curl -fsSL --max-time 180 -o "$tmpd/sbx.tar.gz" "$dl" || continue
		tar -xzf "$tmpd/sbx.tar.gz" -C "$tmpd" || continue
		bin="$(find "$tmpd" -type f -name 'sing-box' | head -n 1)"
		[ -n "$bin" ] || continue
		cp "$bin" /usr/bin/sing-box && chmod 755 /usr/bin/sing-box || continue
		[ -n "$(sb_sbx_ver)" ] && { rm -rf "$tmpd"; return 0; }
	done
	rm -rf "$tmpd"
	return 1
}

SB_SBX_VER="$(sb_sbx_ver)"
if [ -n "$SB_SBX_VER" ]; then
	sb_log "sing-box уже установлен: $SB_SBX_VER (не переустанавливаю)"
	sb_ver_ge_112 "$SB_SBX_VER" || {
		sb_warn "sing-box $SB_SBX_VER ниже требуемой 1.12: Reality-конфиги не пройдут sing-box check."
		sb_warn "обновите sing-box (opkg upgrade sing-box / apk upgrade sing-box — либо релизы SagerNet/shtorm-7 по архитектуре uname -m) и перезапустите установку."
		sb_die 'требуется sing-box >= 1.12'
	}
else
	sb_log 'sing-box не найден — устанавливаю (фиды -> релизы GitHub)'
	if $SB_PM_ADD sing-box >/dev/null 2>&1 && command -v sing-box >/dev/null 2>&1; then
		sb_log "sing-box установлен из фидов: $(sb_sbx_ver)"
	elif sb_sbx_install_github; then
		sb_log "sing-box установлен из релизов GitHub: $(sb_sbx_ver)"
	else
		sb_die 'не удалось установить sing-box. Установите sing-box >= 1.12 вручную (релизы SagerNet / shtorm-7 tiny, архитектура uname -m) и перезапустите установку.'
	fi
	SB_SBX_VER="$(sb_sbx_ver)"
	sb_ver_ge_112 "$SB_SBX_VER" || sb_die 'установленный sing-box всё ещё < 1.12'
fi

# ------------------------------------------- бэкап затрагиваемого (до прав) ---

# /etc/config/firewall копируем ДО любых наших изменений (правила
# создаются только add_inbound, но бэкап — страховка).
# НЕ перезаписываем существующий бэкап: он хранит состояние до ПЕРВОЙ
# установки (идемпотентность повторных запусков).
mkdir -p /etc/sing-bounds/backup || sb_die 'не могу создать /etc/sing-bounds/backup'
chmod 755 /etc/sing-bounds /etc/sing-bounds/backup
if [ -f /etc/config/firewall ] && [ ! -f /etc/sing-bounds/backup/firewall.pre-install ]; then
	cp /etc/config/firewall /etc/sing-bounds/backup/firewall.pre-install \
		|| sb_die 'не могу забэкапить /etc/config/firewall'
	chmod 644 /etc/sing-bounds/backup/firewall.pre-install
	sb_log 'бэкап: /etc/config/firewall -> /etc/sing-bounds/backup/firewall.pre-install'
fi
# Отметка: был ли конфиг singbounds до установки.
if [ ! -f /etc/sing-bounds/backup/state.pre-install ]; then
	if [ -f /etc/config/singbounds ]; then
		printf 'singbounds_config_present\n' > /etc/sing-bounds/backup/state.pre-install
	else
		printf 'singbounds_config_absent\n' > /etc/sing-bounds/backup/state.pre-install
	fi
	chmod 644 /etc/sing-bounds/backup/state.pre-install
	sb_log "отметка: конфиг /etc/config/singbounds до установки — $(cat /etc/sing-bounds/backup/state.pre-install)"
fi

# ------------------------------------- копирование файлов (карта путей) ---

# Карта путей — ЕДИНАЯ для install/uninstall.
# sb_put <путь-в-репо> <целевой-путь> <режим>: mkdir -p + cp + chmod.
SB_DST_LIB=/usr/lib/sing-bounds

sb_put() {
	local rel dst mode
	rel="$1"; dst="$2"; mode="$3"
	[ -f "$SB_SRC/$rel" ] || sb_die "в репозитории нет файла $rel"
	mkdir -p "$(dirname "$dst")" || sb_die "не могу создать каталог для $dst"
	cp "$SB_SRC/$rel" "$dst" || sb_die "не могу скопировать $rel -> $dst"
	chmod "$mode" "$dst" || sb_die "не могу выставить права $mode на $dst"
}

sb_log 'копирую файлы по карте путей'

# Бэкенд: /usr/lib/sing-bounds/ (644)
sb_put files/backend/netbounds.uc "$SB_DST_LIB/netbounds.uc" 644
sb_put files/backend/render.uc    "$SB_DST_LIB/render.uc"    644
sb_put files/backend/backend.sh   "$SB_DST_LIB/backend.sh"   644
sb_put files/backend/firewall.sh  "$SB_DST_LIB/firewall.sh"  644
sb_put files/backend/vip.sh       "$SB_DST_LIB/vip.sh"       644
chmod 755 "$SB_DST_LIB"
# CLI: /usr/bin/singbounds-ctl (755)
sb_put files/backend/singbounds-ctl /usr/bin/singbounds-ctl 755
# init: /etc/init.d/singbounds (755)
sb_put files/init.d/singbounds /etc/init.d/singbounds 755
# rpcd-плагин: /usr/libexec/rpcd/singbounds (755)
sb_put files/rpcd/singbounds /usr/libexec/rpcd/singbounds 755
# ACL rpcd: /usr/share/rpcd/acl.d/luci-app-singbounds.json (644)
sb_put files/acl.d/luci-app-singbounds.json /usr/share/rpcd/acl.d/luci-app-singbounds.json 644
# Меню LuCI: /usr/share/luci/menu.d/luci-app-singbounds.json (644)
sb_put files/menu.d/luci-app-singbounds.json /usr/share/luci/menu.d/luci-app-singbounds.json 644
# View-классы LuCI: ДВА места: uhttpd отдаёт статику из /www, а LuCI
# грузит модули по HTTP-пути — только /usr/lib-копии невидимы
# браузеру; рабочие приложения этого роутера живут в /www.
# ОДИН view-файл app.js (4 таба внутри страницы) + вендорный
# qrcode.js (QR-рендер Таба «Обзор/Инбаунды»); старые
# inbounds/settings/system.js из карты удалены.
# v1.2: web UI на 7789 и стенды выпилены — интерфейс ТОЛЬКО LuCI.
sb_put files/www/luci-static/resources/view/singbounds/app.js     /www/luci-static/resources/view/singbounds/app.js     644
sb_put files/www/luci-static/resources/view/singbounds/qrcode.js /www/luci-static/resources/view/singbounds/qrcode.js 644
chmod 755 /www/luci-static/resources/view/singbounds 2>/dev/null
# /usr/lib-копия — для каноничности пакетного менеджера (apk ставит
# view туда); держим обе синхронными.
cp /www/luci-static/resources/view/singbounds/app.js \
   /www/luci-static/resources/view/singbounds/qrcode.js \
   /usr/lib/luci-static/resources/view/singbounds/ 2>/dev/null \
	|| sb_warn '/usr/lib/luci-static/resources/view/singbounds: копия не создана (не критично — LuCI грузит из /www)'

# --- v1.2 миграция: снести артефакты web UI 7789, если остались от v1.1 ---
if [ -d /www/singbounds ] || uci -q get uhttpd.singbounds >/dev/null 2>&1; then
	sb_log 'v1.2 миграция: удаляю web UI 7789 (дашборд/стенды/uhttpd-секцию)'
	rm -rf /www/singbounds /usr/lib/sing-bounds/webui.sh 2>/dev/null
	if uci -q get uhttpd.singbounds >/dev/null 2>&1; then
		uci delete uhttpd.singbounds && uci commit uhttpd \
			&& /etc/init.d/uhttpd reload \
			|| sb_warn 'не могу удалить uhttpd.singbounds — уберите секцию вручную'
	fi
fi

# --------------------------------------------------- UCI: touch + global ---

sb_log 'UCI: конфиг singbounds + global-секция'
# uci не создаёт файл конфига сам — touch идемпотентен.
[ -f /etc/config/singbounds ] || : > /etc/config/singbounds
# Бэкенд уже на месте — используем его sb_ensure_global: создаёт секцию
# с дефолтами ТОЛЬКО при отсутствии (не перезаписывает значения).
. "$SB_DST_LIB/backend.sh"
sb_ensure_global || sb_die 'не могу создать global-секцию UCI'
sb_migrate_ids
# installed_at — отметка первой установки (повторные запуски не меняют).
if [ -z "$(uci -q get singbounds.global.installed_at)" ]; then
	uci set singbounds.global.installed_at="$(date '+%Y-%m-%d %H:%M:%S')" \
		|| sb_warn 'не могу записать installed_at'
fi
uci -q commit singbounds

# ------------------------------------------------------------- rpcd reload ---
# (web UI на 7789 удалён в v1.2: весь интерфейс теперь в LuCI;
# при апгрейде с v1.1 снимаем старые артефакты — см. блок миграции ниже.)

sb_log 'rpcd reload (регистрация ubus-объекта singbounds)'
/etc/init.d/rpcd reload || sb_warn 'rpcd reload не сработал — проверьте /usr/libexec/rpcd/singbounds'
ubus list singbounds >/dev/null 2>&1 \
	|| sb_warn 'ubus-объект singbounds ещё не виден (rpcd подхватывает плагин не мгновенно; проверьте через пару секунд: ubus list singbounds)'

# -------------------------------------------------------- init + сервис ---

sb_log 'сервис: enable + start'
/etc/init.d/singbounds enable || sb_die 'init enable провалился'
# Старт: с инбаундами сервис поднимется; ПУСТОЕ состояние — render
# откажет (это ОК: сервис стартует при первом add_inbound).
if /etc/init.d/singbounds start >/dev/null 2>&1; then
	sb_log 'сервис singbounds запущен'
else
	sb_log 'сервис не поднялся (нет инбаундов — рендер пуст; стартует при первом add_inbound)'
fi

# -------------------------------------------------------- статус-отчёт ---

# Самопроверка после установки: ubus-объект жив и отвечает.
sb_log 'самопроверка: ubus-объект singbounds'
SB_HC_ERR=0
if ! ubus call singbounds status >/dev/null 2>&1; then
	# rpcd подхватывает плагин не мгновенно — одна повторная попытка.
	sleep 2
	ubus call singbounds status >/dev/null 2>&1 \
		|| { sb_warn 'самопроверка НЕ ПРОШЛА: ubus не отвечает (попробуйте /etc/init.d/rpcd restart и перезапустите установку)'; SB_HC_ERR=1; }
fi
[ "$SB_HC_ERR" = "0" ] && sb_log 'самопроверка: OK (ubus отвечает)'

# ipaddr может быть списком адресов через пробел (алиасы LAN) — берём
# первый; отсекаем CIDR-суффикс, если он есть.
SB_LAN_IP="$(uci -q get network.lan.ipaddr)"
SB_LAN_IP="${SB_LAN_IP%% *}"
SB_LAN_IP="${SB_LAN_IP%%/*}"
echo ''
echo '=============================================================='
echo " sing-bounds установлен (v1.2.1)."
echo "   LuCI:      Сервисы -> sing-bounds (http://${SB_LAN_IP}/cgi-bin/luci)"
echo "   sing-box:  ${SB_SBX_VER}; конфиг UCI: /etc/config/singbounds"
echo '   Бэкап firewall: /etc/sing-bounds/backup/firewall.pre-install'
[ "$SB_HC_ERR" = "0" ] && echo '   Самопроверка: OK — панель готова к работе'
echo ''
echo ' Первый инбаунд — через LuCI, или из консоли:'
echo '   ubus call singbounds add_inbound "{ \"name\": \"Друг\" }"'
echo '=============================================================='

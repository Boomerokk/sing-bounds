#!/bin/sh
# vip.sh — sourcable-библиотека VIP-устройств sing-bounds.
#
# НЕ ИСПОЛНЯЕТСЯ САМА: библиотека функций для source. Вызов до source:
#   . /usr/lib/sing-bounds/backend.sh   # backend сам source'ит vip.sh
#   sb_vip_up 192.168.1.240
#   sb_vip_down 192.168.1.240
#   sb_vip_close_all
#
# СУТЬ: VIP инбаунда
# (192.168.1.240–.250) становится ВИДИМЫМ LAN-устройством
# «Sing-bounds Tunnel» в панели роутера:
#   1) ip-алиас <vip>/24 на br-lan (адрес отвечает на ping — это наш
#      собственный адрес на интерфейсе роутера);
#   2) статическая dhcp-host запись odhcpd с MAC 02:00:00:xx:xx:xx
#      (локально-администрируемый, СТАБИЛЬНЫЙ из последних октетов VIP —
#      один и тот же VIP всегда даёт один и тот же MAC). SNAT НЕ делаем
#      (YAGNI).
#
# OWNERSHIP-МАРКЕР (как sing-bounds- префикс у firewall): dhcp-host
# запись НАША <=> option name='Sing-bounds Tunnel'. По этому имени
# sb_vip_down / sb_vip_close_all находят и снимают ТОЛЬКО наши записи;
# чужие host-секции (прочие устройства LAN) не трогаем,
# даже если у чужой записи совпал ip/mac.
#
# odhcpd-перечитывание: `/etc/init.d/odhcpd reload` (мягче рестарта —
# не пересоздаёт lease-набор). Проверено: reload достаточно — host-запись
# появляется в LuCI-списке активных хостов (ubus call dhcp ipv4leases),
# leases-файл /tmp/dhcp.leases не меняется. restart НЕ потребовался.
# Leases-файл руками НЕ трогаем никогда.
#
# ИДЕМПОТЕНТНОСТЬ: повторный sb_vip_up — не ошибка (ip addr add
# «already exists» глушится; dhcp-host секция не дублируется — до
# добавления ищем существующую по ip+mac). Повторный sb_vip_down
# по отсутствующим артефактам — тихий успех.

# ЗАПИСЬ ДЛЯ DNSMASQ КРИТИЧНА: dnsmasq читает наши host-строки при
# старте и падает на невалидном имени («bad DHCP host name ...
# FAILED to start up») — это роняет DNS+DHCP всего роутера.
# Имя может быть испорчено при передаче (кириллица -> '?'), поэтому
# три защиты:
#   1) имя ТОЛЬКО ASCII [a-z0-9-] (валидный hostname-символ dnsmasq);
#      человекочитаемое «Sing-bounds Tunnel» живёт в UI, не в uci-dhcp;
#   2) после каждой мутации dhcp-секций — dnsmasq --test конфига и
#      при провале НЕМЕДЛЕННЫЙ откат нашей записи (dnsmasq обязан
#      остаться валидным);
#   3) все uci set dhcp-опций идут через переменные (не сырые строки),
#      порча не попадает в конфиг молча.

SB_VIP_NAME='singbounds-tunnel'

# sb_vip_log <msg> — единая точка логирования (syslog + stderr).
sb_vip_log() {
	logger -t singbounds -s "vip: $*"
}

# sb_vip_name_ok <name> — валиден ли hostname для dnsmasq (ASCII
# [a-z0-9-], не пусто, без ведущих/хвостовых дефисов). Валидатор стоит
# на входе sb_vip_up: имя с '?', кириллицей или пробелом НЕ попадёт в
# uci (иначе dnsmasq FAILED to start up).
sb_vip_name_ok() {
	case "${1:-}" in
		''|-*|*-) return 1 ;;
		*[!a-z0-9-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# sb_vip_dnsmasq_check — проверить, что dnsmasq-конфиг (он собирается из
# uci при старте; у нас — уже применённые uci-опции) не сломан нашей
# записью. Возврат: 0 — ок / 1 — конфиг невалиден / 2 — проверить не
# смогли (нет dnsmasq в PATH: не блокируем работу — но и не врём, что
# проверено).
sb_vip_dnsmasq_check() {
	command -v dnsmasq >/dev/null 2>&1 || return 2
	# dnsmasq --test -C <файл>: собираем актуальный конфиг так же, как
	# init-скрипт (через ubus/uci-путь не выйдет — берём существующий
	# сгенерированный конфиг, если он есть; иначе считаем «не проверили»).
	local cfg
	for cfg in /var/etc/dnsmasq.conf.*; do
		[ -f "$cfg" ] || continue
		dnsmasq --test -C "$cfg" >/dev/null 2>&1 || return 1
	done
	return 0
}

# sb_vip_dnsmasq_restart_checked — перезапустить dnsmasq и убедиться, что
# он ПОДНЯЛСЯ. Если не поднялся — это авария DNS всего роутера;
# возвращаем 1, вызыватель откатывает свою запись.
sb_vip_dnsmasq_restart_checked() {
	sb_vip_dnsmasq_check
	case "$?" in
		1) sb_vip_log "dnsmasq-конфиг НЕВАЛИДЕН — рестарт не делаю"; return 1 ;;
	esac
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
	# проверка живости: процесс есть И порт 53 слушается
	local i
	i=0
	while [ "$i" -lt 10 ]; do
		if pgrep -x dnsmasq >/dev/null 2>&1 \
			&& netstat -tlnu 2>/dev/null | grep -q ':53 '; then
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	sb_vip_log "dnsmasq НЕ поднялся после рестарта — откат"
	return 1
}

# sb_vip_mac <vip> -> MAC 02:00:00:O2:O3:O4 (стабильный из октетов VIP).
# Локально-администрируемый: первый октет 02 (bit1=local, bit0=unicast).
# printf %02x принимает десятичные значения полей через IFS-разбор.
sb_vip_mac() {
	local o2 o3 o4
	o2="$(printf '%s' "$1" | cut -d. -f2)"
	o3="$(printf '%s' "$1" | cut -d. -f3)"
	o4="$(printf '%s' "$1" | cut -d. -f4)"
	printf '02:00:00:%02x:%02x:%02x\n' "$o2" "$o3" "$o4"
}

# sb_vip_host_sect <vip> [mac] -> имя dhcp-секции НАШЕЙ host-записи с этим
# ip (пусто = нет). uci show печатает для анонимной секции
# dhcp.@host[N]=host и опции dhcp.@host[N].ip='…'. Наша = ip совпал И
# name='Sing-bounds Tunnel' (ownership-маркер). Только по ip НЕ ищем:
# чужая запись с тем же ip — не наша, не трогаем (анти- guard firewall-схемы).
sb_vip_host_sect() {
	local vip target_mac sect sect_ip sect_name sect_mac
	vip="${1:-}"
	target_mac="${2:-}"
	[ -n "$vip" ] || return 0
	# sed по однострочному выводу uci show: ищем сначала ip=, затем
	# проверяем name (и опционально mac) той же секции через uci get.
	# РЕНУМЕРОВКА @host[N] после delete: вызыватели удаляют по одному и
	# переспрашивают — здесь только поиск, не удаление.
	for sect in $(uci -q show dhcp 2>/dev/null \
		| sed -n "s/^dhcp\.\([^.=]*\)\.ip='$vip'\$/\1/p"); do
		sect_name="$(uci -q get "dhcp.$sect.name" 2>/dev/null)"
		[ "$sect_name" = "$SB_VIP_NAME" ] || continue
		if [ -n "$target_mac" ]; then
			sect_mac="$(uci -q get "dhcp.$sect.mac" 2>/dev/null)"
			[ "$sect_mac" = "$target_mac" ] || continue
		fi
		printf '%s\n' "$sect"
		return 0
	done
	return 0
}

# sb_vip_odhcpd_reload — перечитать dhcp-конфиг odhcpd. reload достаточно;
# при провале reload — один раз restart с
# проверкой живости сервиса до рестарта (не ронять odhcpd).
sb_vip_odhcpd_reload() {
	if /etc/init.d/odhcpd reload >/dev/null 2>&1; then
		return 0
	fi
	sb_vip_log "odhcpd reload не сработал — проверяю сервис и пробую restart"
	# сервис жив? (перед рестартом — ubus call service list)
	if ! ubus call service list 2>/dev/null | grep -q '"odhcpd"'; then
		sb_vip_log "odhcpd не в service list — рестарт не делаю (не наш случай)"
		return 1
	fi
	/etc/init.d/odhcpd restart >/dev/null 2>&1
}

# sb_vip_up <vip> — поднять VIP-устройство: ip-алиас на br-lan + наша
# dhcp-host запись + odhcpd reload. Идемпотентен. Отказ логируется,
# НЕ валит вызывателя (add_inbound: VIP-видимость — некритичная надстройка
# над рабочим инбаундом; rc инбаунда не должен зависеть от odhcpd-фокусов).
sb_vip_up() {
	local vip mac sect added
	vip="${1:-}"
	case "$vip" in
		''|*[!0-9.]*)
			sb_vip_log "up: некорректный VIP '$vip' — пропускаю"
			return 1
			;;
	esac

	# ЗАЩИТА 1: имя записи обязано быть валидным hostname (см. шапку —
	# защита от dnsmasq FAILED). Проверяем ДО любых мутаций.
	if ! sb_vip_name_ok "$SB_VIP_NAME"; then
		sb_vip_log "up: SB_VIP_NAME '$SB_VIP_NAME' не проходит hostname-валидатор — ABORT (это защита роутера)"
		return 1
	fi

	mac="$(sb_vip_mac "$vip")"

	# --- 1. ip-алиас на br-lan (повтор — НЕ ошибка: RTNETLINK exists) ---
	ip -4 addr add "$vip/24" dev br-lan 2>/dev/null || true

	# --- 2. dhcp-host запись (ТОЛЬКО если нашей ещё нет) ---
	added=0
	sect="$(sb_vip_host_sect "$vip" "$mac")"
	if [ -n "$sect" ]; then
		sb_vip_log "up: dhcp-host для $vip уже есть ($sect) — не дублирую"
	else
		# чужая запись с тем же ip, но БЕЗ нашего name: не трогаем,
		# свою не создаём (коллизия имени/ip в odhcpd — честный отказ).
		if [ -n "$(sb_vip_host_any_ip "$vip")" ]; then
			sb_vip_log "up: ip $vip занят ЧУЖОЙ dhcp-host записью — свою не создаю"
		else
			uci add dhcp host >/dev/null 2>&1 || {
				sb_vip_log "up: не могу добавить dhcp host для $vip"
				return 1
			}
			# ЗАЩИТА 3: опции через переменные; провал любого set —
			# откат секции сразу (не оставляем полу-записанную).
			if ! { uci set "dhcp.@host[-1].name=$SB_VIP_NAME" \
				&& uci set "dhcp.@host[-1].mac=$mac" \
				&& uci set "dhcp.@host[-1].ip=$vip"; }; then
				uci delete 'dhcp.@host[-1]' >/dev/null 2>&1
				sb_vip_log "up: не могу записать опции dhcp-host ($vip) — секция откатана"
				return 1
			fi
			uci commit dhcp 2>/dev/null \
				|| sb_vip_log "up: uci commit dhcp провалился ($vip)"
			added=1
			sb_vip_log "up: VIP $vip ($mac) поднят на br-lan + dhcp-host"
		fi
	fi

	# --- 3. odhcpd перечитать (мягкий reload; restart — только при
	#     провале reload, см. sb_vip_odhcpd_reload) ---
	sb_vip_odhcpd_reload \
		|| sb_vip_log "up: odhcpd не перечитал конфиг ($vip) — запись применится при его штатном рестарте"

	# --- 4. ЗАЩИТА 2: мы трогали dhcp-секции — dnsmasq обязан остаться
	#     валидным. Новой записи нет -> конфиг не менялся -> пропускаем.
	if [ "$added" = "1" ]; then
		sb_vip_dnsmasq_check
		if [ "$?" = "1" ]; then
			sb_vip_log "up: dnsmasq-конфиг сломан нашей записью — ОТКАТ записи $vip"
			sb_vip_down "$vip"
			return 1
		fi
	fi

	return 0
}

# sb_vip_host_any_ip <vip> -> секция ЛЮБОЙ host-записи с этим ip
# (наша или чужая; только для коллизионной проверки в up).
sb_vip_host_any_ip() {
	uci -q show dhcp 2>/dev/null \
		| sed -n "s/^dhcp\.\([^.=]*\)\.ip='$1'\$/\1/p" | head -n 1
}

# sb_vip_down <vip> — снять VIP-устройство: убрать наш dhcp-host
# (только НАШ: ip совпал + name='Sing-bounds Tunnel'; чужие с тем же
# ip не трогаем) + ip-алиас. Идемпотентен. Отказ логируется, rc мягкий.
sb_vip_down() {
	local vip mac sect prefix changed
	vip="${1:-}"
	case "$vip" in
		''|*[!0-9.]*)
			sb_vip_log "down: некорректный VIP '$vip' — пропускаю"
			return 1
			;;
	esac

	mac="$(sb_vip_mac "$vip")"

	# --- 1. наша dhcp-host запись (по ip, проверив ownership-маркер) ---
	# РЕНУМЕРОВКА @host[N] после delete: цикл «найди первый, удали,
	# повтори» — каждая итерация видит свежую нумерацию.
	changed=0
	while sect="$(sb_vip_host_sect "$vip" "$mac")"; [ -n "$sect" ]; do
		uci delete "dhcp.$sect" 2>/dev/null || {
			sb_vip_log "down: не могу удалить dhcp.$sect ($vip)"
			break
		}
		changed=1
	done
	if [ "$changed" = "1" ]; then
		uci commit dhcp 2>/dev/null \
			|| sb_vip_log "down: uci commit dhcp провалился ($vip)"
	fi

	# --- 2. ip-алиас с br-lan: точный префикс (не хардкод /24) ---
	prefix="$(ip -4 addr show br-lan 2>/dev/null \
		| awk -v v="$vip" '$2 ~ "^" v "/" {print $2}')"
	case "$prefix" in
		*/*) ip addr del "$prefix" dev br-lan 2>/dev/null \
			|| sb_vip_log "down: не могу снять VIP $vip с br-lan" ;;
	esac

	# --- 3. мы меняли dhcp-секции — dnsmasq перечитать с проверкой
	#     подъёма: удалённая запись может оставаться в
	#     конфиге dnsmasq до его рестарта — поэтому рестарт проверяемый. ---
	if [ "$changed" = "1" ]; then
		if ! sb_vip_dnsmasq_restart_checked; then
				# dnsmasq не поднялся — но наша запись УДАЛЕНА из uci
			# (следующий старт dnsmasq валиден). Проверка после
			# отзыва: если и сейчас невалиден — чужая поломка,
			# логируем и не паникуем.
			sb_vip_dnsmasq_check
			[ "$?" = "1" ] \
				&& sb_vip_log "down: dnsmasq-конфиг невалиден БЕЗ нашей записи — это чужая проблема, не трогаю"
		fi
	fi

	sb_vip_log "down: VIP $vip снят (ip-алиас + наша dhcp-host запись)"
	return 0
}

# sb_vip_close_all — снять ВСЕ наши VIP-устройства: по UCI-инбаундам
# ДО их удаления (uninstall) sb_vip_down каждый наш VIP + подчистить
# все dhcp-host с name='Sing-bounds Tunnel' (даже сироты без инбаунда —
# остатки ручных экспериментов).
sb_vip_close_all() {
	local vips vip sect changed
	# --- наши VIP из UCI singbounds ---
	vips="$(sb_taken_vips 2>/dev/null)"
	for vip in $vips; do
		case "$vip" in
			''|*[!0-9.]*) continue ;;
		esac
		sb_vip_down "$vip"
	done
	# --- сироты: любые dhcp-host с НАШИМ name, чей ip не покрыт выше ---
	# РЕНУМЕРОВКА @host[N] после delete: цикл «найди первый, удали».
	changed=0
	while sect="$(uci -q show dhcp 2>/dev/null \
		| sed -n "s/^dhcp\.\([^.=]*\)\.name='$SB_VIP_NAME'\$/\1/p" | head -n 1)" \
		&& [ -n "$sect" ]; do
		uci delete "dhcp.$sect" 2>/dev/null || break
		changed=1
	done
	[ "$changed" = "1" ] && uci -q commit dhcp 2>/dev/null
	sb_vip_odhcpd_reload 2>/dev/null \
		|| sb_vip_log "close_all: odhcpd reload не сработал"
	# ГАРАНТИЯ: после удаления наших dhcp-записей dnsmasq обязан
	# перезапуститься и подняться (иначе конфиг останется с удалённой
	# строкой и DNS не поднимется).
	# sb_vip_down внутри уже делает проверяемый
	# рестарт, но здесь — страховка для пути «сироты без цикла down».
	sb_vip_dnsmasq_restart_checked \
		|| sb_vip_log "close_all: dnsmasq не поднялся — проверьте logread (наши записи из uci уже удалены)"
	sb_vip_log "close_all: наши VIP-устройства сняты"
	return 0
}

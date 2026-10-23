#!/bin/sh
# backend.sh — оркестратор sing-bounds.
#
# НЕ самостоятельная CLI-программа: sourcable-библиотека, которую
# вызывает rpcd-плагин /usr/libexec/rpcd/singbounds. Разделение:
# rpcd-плагин — ТОЛЬКО ubus-контракт (list/call, jshn, STDIN->JSON,
# JSON->stdout, exit 1+stderr -> текст ошибки ubus);
# backend.sh — бизнес-флоу: генерация ключей (sing-box generate),
# запись UCI-состояния, sb_fw_open/close, рестарт
# сервиса; netbounds.uc — чистая модель.
#
# Установка: files/backend/backend.sh -> /usr/lib/sing-bounds/backend.sh.
# Вызов до source:
#. /usr/lib/sing-bounds/backend.sh
# sb_backend_add_inbound 'Home' # -> id<TAB>port<TAB>vip
#
# КОНТРАКТ ВЫВОДА (важно для rpcd-плагина): функции результата печатают
# поля, РАЗДЕЛЁННЫЕ ТАБУЛЯЦИЕЙ, на stdout; rc=0 — успех. Любой отказ:
# rc!=0, диагностикой на STDERR (плагин превращает её в ubus-ошибку —
# «порт занят» и т.п.). stdout при отказе ПУСТ.
# sb_fw_log уже пишет в stderr через logger -s — это не
# наш слой, мы НЕ дублируем лог в stderr вторым слоем.
#
# АТОМАРНОСТЬ: все проверки (порт занят, VIP исчерпан) выполняются ДО
# первой мутации; мутации идут в порядке, где отказ каждой следующей
# оставляет систему в консистентном состоянии
# (см. sb_backend_add_inbound).

SB_LIB_DIR=/usr/lib/sing-bounds
SB_UCI_CFG=singbounds

# firewall.sh — единственный источник sb_fw_open/close/close_all.
# backend — их единственный вызыватель, поэтому source здесь,
# а НЕ в rpcd-плагине (иначе `sb_fw_open: not found`).
[ -r "$SB_LIB_DIR/firewall.sh" ] &&. "$SB_LIB_DIR/firewall.sh"

# vip.sh — sb_vip_up/down/close_all: VIP-инбаунда как видимое
# LAN-устройство «Sing-bounds Tunnel» (ip-алиас на br-lan +
# dhcp-host odhcpd с ownership-маркером по имени). backend — их
# единственный вызыватель (add/del_inbound, uninstall), поэтому source
# здесь, рядом с firewall.sh.
[ -r "$SB_LIB_DIR/vip.sh" ] &&. "$SB_LIB_DIR/vip.sh"

# sb_err <msg> — единая точка диагностики backend-слоя: stderr + syslog.
# НЕ дублируем sb_fw_log (та пишет только о firewall-операциях).
sb_err() {
	logger -t singbounds "backend: $*"
	echo "backend: $*" >&2
}

# sb_millis -> миллисекунды монотонного времени (замер check_wan).
# busybox date НЕ поддерживает %N (37.0: `busybox date +%s%N` печатает только СЕКУНДЫ — наносекундной
# части нет, мс-разрешение недостижимо). /proc/uptime — десятичные
# доли секунды: «54904.73 104245.08» -> 54904730 мс.
# Возврат — число мс; пусто при недоступности /proc/uptime.
sb_millis() {
	awk '{printf "%.0f\n", $1*1000}' /proc/uptime 2>/dev/null
}

# sb_state_call <func> [args...] -> JSON на stdout.
# Единственная точка входа в ucode/netbounds: backend сам ucode НЕ
# дублирует — модель чистая. Функции netbounds вызываются
# ucode-однострочником; аргументы передаются как ucode-литералы,
# собираемые строкой — вызыватели ниже передают только [0-9A-Za-z_.-]
# (id/имена секций), поэтому инъекция в строку-литерал исключена
# (валидация см. sb_id_ok / sb_slug).
sb_state_call() {
	ucode -e "
		push(REQUIRE_SEARCH_PATH, '$SB_LIB_DIR/*.uc');
		let nb = require('netbounds');
		let state = nb.loadState();
		$*
	"
}

# sb_listening_ports -> ОДНОСТРОЧНЫЙ пробел-разделённый список портов
# TCP-листенеров (netstat -tln: чужой 443 слушает чужой процесс; PID
# не нужен, нужны порты). ВАЖНО: вывод по строкам на порт; сырой
# многострочный вывод ломает case-подстрочный матчинг (« 443 » не
# находится) — сплющиваем tr-ом здесь, а не в каждом вызывателе.
sb_listening_ports() {
	netstat -tln 2>/dev/null | awk '/^tcp/ { n = split($4, a, ":"); print a[n] }' | sort -n | uniq | tr '\n' ' '
}

# sb_taken_vips -> пробел-разделённый список VIP наших инбаундов.
sb_taken_vips() {
	sb_state_call 'print(join(" ", map(state.inbounds, i => i.vip)))'
}

# sb_taken_ports -> пробел-разделённые порты наших инбаундов.
sb_taken_ports() {
	sb_state_call 'print(join(" ", map(state.inbounds, i => i.port)))'
}

# sb_id_ok <str>: id/имя секции — только [A-Za-z0-9_-].
# Имя инбаунда-ЧЕЛОВЕКА проходит отдельно (оно не идентификатор).
sb_id_ok() {
	case "$1" in
		''|*[!A-Za-z0-9_-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# sb_slug <name> -> санитизированный идентификатор для fw_rule/id.
# Транслитерации НЕТ: не-ASCII выбрасываются, пробел->дефис, lower-case.
# Гарантированно проходит sb_id_ok (пустой результат -> 'in').
sb_slug() {
	printf '%s' "$1" | tr '[:upper:] ' '[:lower:--' | tr -cd 'A-Za-z0-9-'
}

# sb_gen_keypair -> печатает "<private>\t<public>".
# sing-box generate reality-keypair отдаёт JSON {PrivateKey, PublicKey}.
sb_gen_keypair() {
	local out priv pub
	out="$(sing-box generate reality-keypair 2>/dev/null)" || {
		sb_err "не могу сгенерировать Reality-ключи (sing-box generate)"
		return 1
	}
	# sing-box 1.13.21 печатает YAML-вид «PrivateKey: <key>»,
	# более старые/иные сборки — JSON {"PrivateKey": "...", "PublicKey": "..."}.
	# Парсим оба формата: сначала YAML-строку, потом JSON.
	priv="$(printf '%s' "$out" | sed -n 's/^PrivateKey:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p; s/.*"PrivateKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	pub="$(printf '%s' "$out" | sed -n 's/^PublicKey:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p; s/.*"PublicKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
	[ -n "$priv" ] && [ -n "$pub" ] || {
		sb_err "sing-box generate: неожиданный вывод (нет PrivateKey/PublicKey)"
		return 1
	}
	printf '%s\t%s\n' "$priv" "$pub"
}

# sb_gen_id <prefix> -> '<prefix>' + 6 случайных hex-символов [0-9a-f].
# ВАЖНО: id инбаунда/клиента = имя
# анонимной UCI-секции — UCI ПЕРЕИСПОЛЬЗУЕТ cfg-имена после
# удалений (наблюдения: cfg043d74 у нового инбаунда после удаления
# старого «Друг» — клиенты «прилипали» к новому инбаунду; cfg056184 у
# двух клиентов после uninstall+install). Глобальная уникальность —
# проверка по ВСЕМ опциям.id в конфиге; цикл гарантирует отсутствие
# коллизий. Префикс: 'in' / 'c'.
sb_gen_id() {
	local pfx cand i
	pfx="${1:-x}"
	i=0
	while [ $i -lt 10 ]; do
		cand="$pfx$(head -c 16 /dev/urandom 2>/dev/null \
			| hexdump -e '16/1 "%02x"' | cut -c1-6)"
		case "$cand" in
			"$pfx"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
			*) i=$((i + 1)); continue ;;
		esac
		# Глобальная проверка: любая опция.id с этим значением
		# (grep по выводу uci show — плоский текст, надёжен).
		if ! uci -q show "$SB_UCI_CFG" 2>/dev/null \
			| grep -q "id='$cand'"; then
			printf '%s\n' "$cand"
			return 0
		fi
		i=$((i + 1))
	done
	sb_err "не могу сгенерировать уникальный id ($pfx, 10 попыток)"
	return 1
}

# sb_gen_client_id -> 'c' + 6 hex (см. sb_gen_id).
sb_gen_client_id() {
	sb_gen_id c
}

# sb_gen_uuid -> печатает UUID.
sb_gen_uuid() {
	local uuid
	uuid="$(sing-box generate uuid 2>/dev/null)" || {
		sb_err "не могу сгенерировать UUID (sing-box generate uuid)"
		return 1
	}
	printf '%s\n' "$uuid"
}

# sb_gen_short_id -> 8 hex-символов (4 байта /dev/urandom).
sb_gen_short_id() {
	head -c 4 /dev/urandom 2>/dev/null | hexdump -e '4/1 "%02x"' \
		|| { sb_err "не могу сгенерировать short_id"; return 1; }
	printf '\n'
}

# sb_uci_touch — конфиг обязан существовать ДО первого add (uci не
# создаёт файл сам. Идемпотентно.
sb_uci_touch() {
	[ -f "/etc/config/$SB_UCI_CFG" ] || : > "/etc/config/$SB_UCI_CFG"
}

# sb_uci_backup — снимок UCI-конфига после успешного commit. Держит 5
# последних снимков в /etc/sing-bounds/backup/uci/: config.YYYYmmdd-HHMMSS.
# Ошибка копирования НЕ валит операцию (бэкап — страховка, не барьер).
sb_uci_backup() {
	local dir="/etc/sing-bounds/backup/uci"
	local src="/etc/config/$SB_UCI_CFG"
	[ -f "$src" ] || return 0
	mkdir -p "$dir" 2>/dev/null || return 0
	cp "$src" "$dir/$(date '+config.%Y%m%d-%H%M%S')" 2>/dev/null || return 0
	# ротация: оставляем 5 свежих, старшие удаляем.
	ls -1r "$dir"/config.* 2>/dev/null | tail -n +6 | while read -r f; do
		rm -f "$f"
	done
	return 0
}

# sb_ensure_global — глобальная секция с sni (нужен ссылкам/рендеру).
sb_ensure_global() {
	uci -q get "$SB_UCI_CFG.global.sni" >/dev/null 2>&1 || {
		sb_uci_touch
		uci set "$SB_UCI_CFG.global=global" || return 1
		uci set "$SB_UCI_CFG.global.sni=www.vk.com" || return 1
	}
	return 0
}

# sb_migrate_ids — секциям inbound/client без опции id записать id = имя секции
# (иначе панель не находит клиентов инбаунда и ключи не показываются).
sb_migrate_ids() {
	local names n t done_n=0
	for t in inbound client; do
		names="$(ucode -e "
			let c = require('uci').cursor();
			c.foreach('$SB_UCI_CFG', '$t', (s) => {
				if (s.id == null || s.id == '') print(s['.name'] + '\n');
				return true;
			});
		" 2>/dev/null)"
		for n in $names; do
			sb_id_ok "$n" || continue
			uci set "$SB_UCI_CFG.$n.id=$n" && done_n=$((done_n + 1))
		done
	done
	[ "$done_n" -gt 0 ] && { uci commit "$SB_UCI_CFG"; sb_uci_backup; }
	return 0
}

# sb_wan_host -> внешний IP роутера (кэш в UCI global.wan_ip).
# Порядок: кэш -> curl ifconfig.me -> ip pppoe-wan (фолбэк: еслиconfig.me
# флакует/занят, аутентичный внешний IP уже есть на WAN-интерфейсе;
# 
sb_wan_host() {
	local cached fresh
	cached="$(uci -q get "$SB_UCI_CFG.global.wan_ip")"
	if [ -n "$cached" ]; then
		printf '%s\n' "$cached"
		return 0
	fi
	fresh="$(curl -s --max-time 10 ifconfig.me 2>/dev/null)" || fresh=''
	case "$fresh" in
		''|*[!0-9.]*) fresh='' ;;
		*) ;;
	esac
	# фолбэк: адрес WAN-интерфейса (pppoe-wan у автора; ищем глобальный
	# inet-адрес не на lo/br-lan — первый подходящий).
	if [ -z "$fresh" ]; then
		fresh="$(ip -4 addr show 2>/dev/null \
			| grep -v 'scope host' \
			| sed -n 's/.*inet \([0-9.]*\).*pppoe-wan.*/\1/p' | head -n 1)"
	fi
	if [ -z "$fresh" ]; then
		fresh="$(ip -4 addr show pppoe-wan 2>/dev/null \
			| sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n 1)"
	fi
	case "$fresh" in
		''|*[!0-9.]*)
			sb_err "не могу определить внешний IP (curl ifconfig.me, ip addr) и нет кэша global.wan_ip"
			return 1
			;;
		*)
			uci set "$SB_UCI_CFG.global.wan_ip=$fresh" \
				&& uci commit "$SB_UCI_CFG" >/dev/null 2>&1
			printf '%s\n' "$fresh"
			return 0
			;;
	esac
}

# sb_lan_cidr -> LAN-подсеть для allocateVip ('192.168.1.0/24'-вид).
# Источник: uci network.lan.ipaddr (OpenWrt 25.12 хранит её уже в CIDR-
# виде '192.168.1.1/24', БЕЗ опции netmask — /24-подсеть достраиваем по последнему
# октету.0; для не-/24 требуем уже CIDR-вид (редкий сценарий — v1,
# см. известные ограничения в отчёте).
sb_lan_cidr() {
	local ip mask prefix
	ip="$(uci -q get network.lan.ipaddr)"
	mask="$(uci -q get network.lan.netmask)"
	[ -n "$ip" ] || return 1
	# ipaddr уже в CIDR-виде ('192.168.1.1/24') — печатаем как есть.
	# Это НОРМАЛЬНЫЙ кейс 25.12, а не исключение.
	case "$ip" in
		*/*) printf '%s\n' "$ip"; return 0 ;;
	esac
	if [ -n "$mask" ]; then
		case "$mask" in
			255.255.255.0) prefix=24 ;;
			255.255.0.0) prefix=16 ;;
			255.0.0.0) prefix=8 ;;
			*) prefix='' ;;
		esac
	else
		prefix=24
	fi
	[ -n "$prefix" ] || return 1
	printf '%s.0/%s\n' "${ip%.*}" "$prefix"
}

# ---------------------------------------------------------------------------
# Методы API. Все возвращают таб-поля на stdout при rc=0.
# ---------------------------------------------------------------------------

# sb_backend_status -> running TAB version TAB inbounds TAB next_port TAB next_vip
# running: PID живого `sing-box run -c /etc/sing-bounds/config.json`;
# version: sing-box version; inbounds: количество наших инбаундов;
# next_port/next_vip: следующий свободный порт/VIP — подсказка для
# автозаполнения модалки создания. next_port считает занятыми ВСЕ
# наши порты, ВКЛЮЧАЯ выключенные инбаунды (порт выключенного занят —
# иначе коллизия при повторном включении), плюс netstat-листенеров
#; next_vip — все наши VIP без различия enabled
# (VIP из UCI не снимается при toggle).
sb_backend_status() {
	local pid ver count running next_port next_vip
	pid="$(pgrep -f 'sing-box run -c /etc/sing-bounds/config.json' | head -n 1)"
	if [ -n "$pid" ]; then running=true; else running=false; fi
	# `sing-box version | head -1` = «sing-box version 1.13.21»:
	# $1=sing-box $2=version $3=<версия> ($2 — слово «version», не версия).
	ver="$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')"
	count="$(sb_state_call 'print(length(state.inbounds))')"
	next_port="$(sb_next_free_port_hint)"
	next_vip="$(sb_next_free_vip_hint)"
	printf '%s\t%s\t%s\t%s\t%s\n' "$running" "${ver:-unknown}" "${count:-0}" "${next_port:-0}" "${next_vip:-}"
	return 0
}

# sb_next_free_port_hint — общий (для status и edit_inbound) расчёт
# первого свободного порта: наши порты (ВСЕ, включая выключенные —
# контракт атомарности) + netstat-листенеры. Старт 8443 (см. add_inbound).
# Пустой вывод = не смогли посчитать (не ошибка бизнес-логики; status
# в этом случае печатает next_port=0 — плагин отдаёт int).
sb_next_free_port_hint() {
	local our_ports listeners taken_json port_str
	our_ports="$(sb_taken_ports)"
	listeners="$(sb_listening_ports)"
	taken_json='['
	for port_str in $our_ports $listeners; do
		case "$port_str" in
			''|*[!0-9]*) continue ;;
		esac
		taken_json="$taken_json$port_str,"
	done
	taken_json="${taken_json%,}]"
	sb_state_call "print(nb.nextFreePort($taken_json, 8443))"
}

# sb_next_free_vip_hint — первый свободный VIP (allocateVip по нашим
# VIP; выключенные тоже занимают — адрес из UCI не снимается).
sb_next_free_vip_hint() {
	local vips_json vip_str lan_cidr
	vips_json='['
	for vip_str in $(sb_taken_vips); do
		vips_json="$vips_json\"$vip_str\","
	done
	vips_json="${vips_json%,}]"
	lan_cidr="$(sb_lan_cidr 2>/dev/null)" || return 0
	sb_state_call "print(nb.allocateVip('$lan_cidr', $vips_json))" \
		| sed 's/^null$//'
}

# sb_backend_list -> JSON-подобные таб-строки не подходят,
# поэтому list печатает готовый JSON напрямую (модель собирает его
# в ucode — там структуры уже под рукой; это тоже оркестрация
# netbounds, не дублирование модели).
# ВАЖНО (ucode 0.0.20250529):
# 1) object-литерал после `=>` ОБЯЗАН быть в скобках — `x =>`;
# без скобок `{` парсится как блок → «Syntax error: Unexpected token»;
# 2) rpcd/ubus отклоняет top-level массив `[...]` как ответ метода
# («Invalid argument» на ubus call) — оборачиваем в {"inbounds":[...]}.
sb_backend_list() {
	sb_state_call '
		print(sprintf("%J", { inbounds: map(state.inbounds, i => ({
			id: i.id, name: i.name, port: i.port, vip: i.vip,
			public_key: i.public_key, short_id: i.short_id,
			sni: i.sni ?? state.global.sni,
			enabled: i.enabled ? 1 : 0,
			clients: map(i.clients, c => ({ id: c.id, name: c.name, enabled: c.enabled ? 1 : 0 }))
		})) }))
	'
}

# sb_backend_add_inbound <name> [port] [sni] [vip] -> id TAB port TAB vip
# v1.1 (+ правка плана): port/sni/vip — ОПЦИОНАЛЬНЫЕ параметры
# модалки создания; пустой/отсутствующий = авто-выбор как раньше.
# port: конкретный порт; валидация (1-65535, не занят) ДО мутаций;
# пусто = nextFreePort (наши порты ВСЕ + netstat).
# sni: фиксируется в inbound.sni (per-inbound, НЕ global); пусто =
# фиксируем текущий global.sni (модалка фронта подставляет его
# как дефолт — поэтому пустое значение явным ходом «замораживаем»
# global, а не оставляем null: у созданного через v1.1-инбаунд
# sni обязан быть свой, ruling спеки v1.1).
# vip: конкретный VIP; валидация (IP-формат, в LAN-подсети, не
# занят нашими) ДО мутаций; пусто = allocateVip.
# Флоу (порядок фиксирует контракт атомарности— мутации только после всех
# проверок):
# 1. валидация имени; глобальная секция (sni нужен рендеру/ссылкам);
# 2. порт: передан -> валидация+занятость; пусто -> nextFreePort по
# НАШИМ портам (включая выключенные) + netstat-листенерам (чужой
# 443 виден netstat-ом; контракт атомарности: «порт занят», только если
# свободных выше нет);
# 3. VIP: передан -> валидация; пусто -> allocateVip по нашим VIP;
# 4. генерация ключей (Reality + short_id);
# 5. fw_rule = sing-bounds-in-<slug> (контракт sb_fw_*);
# 6. sb_fw_open ДО uci commit: если firewall-слой откажет, UCI ещё
# чист (откат = просто не писать состояние);
# 7. UCI-секция inbound + опции; uci commit;
# 8. /etc/init.d/singbounds restart (check-and-rollback из :
# при провале check старый конфиг жив; НОВЫЙ инбаунд не поднимется —
# rc!=0, но UCI/firewall уже записаны; вызывающий видит честную
# ошибку «сервис не перезапущен», состояние консистентно: след.
# рестарт поднимет инбаунд).
sb_backend_add_inbound() {
	local name port vip sni keys priv pub sid scode slug fw_rule section iid

	name="${1:-}"
	[ -n "$name" ] || { sb_err "имя инбаунда не задано"; return 1; }
	port="${2:-}"
	sni="${3:-}"
	vip="${4:-}"

	sb_ensure_global || { sb_err "не могу создать global-секцию UCI"; return 1; }

	# --- порт: передан -> валидация; пусто -> авто ---
	if [ -n "$port" ]; then
		case "$port" in
			''|*[!0-9]*)
				sb_err "порт должен быть числом (получено: '$port')"
				return 1
				;;
		esac
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
			sb_err "порт должен быть в диапазоне 1-65535"
			return 1
		}
		# занятость: наши порты (ВСЕ, включая выключенные) + чужие
		# листенеры. Свои/чужие листенеры видит netstat.
		local listeners our_ports
		our_ports="$(sb_taken_ports)"
		listeners="$(sb_listening_ports)"
		case " $listeners $our_ports " in
			*" $port "*)
				sb_err "порт $port занят"
				return 1
				;;
		esac
	else
		# авто: наш общий расчёт (наши ВСЕ + netstat), старт 8443.
		port="$(sb_next_free_port_hint)"
		case "$port" in
			''|*[!0-9]*)
				sb_err "не удалось выделить порт"
				return 1
				;;
		esac
		# гонка: выделенный порт вдруг занят — честный отказ.
		case " $(sb_listening_ports) " in
			*" $port "*)
				sb_err "порт занят"
				return 1
				;;
		esac
	fi

	# --- SNI: пусто = фиксируем текущий global.sni ---
	if [ -z "$sni" ]; then
		sni="$(uci -q get "$SB_UCI_CFG.global.sni")"
	fi
	# валидация: домен (не IP, не URL, без слэшей/пробелов; [.] и -
	# в середине разрешены — как у существующей sb_state_call-практики).
	case "$sni" in
		''|*[!A-Za-z0-9.-]*)
			sb_err "некорректный SNI '$sni' (ожидается домен, например www.cloudflare.com)"
			return 1
			;;
	esac

	# --- VIP: передан -> валидация; пусто -> allocateVip ---
	local vips_json vip_str lan_cidr
	vips_json='['
	for vip_str in $(sb_taken_vips); do
		vips_json="$vips_json\"$vip_str\","
	done
	vips_json="${vips_json%,}]"
	lan_cidr="$(sb_lan_cidr)" || {
		sb_err "не могу определить LAN-подсеть (network.lan.ipaddr)"
		return 1
	}
	if [ -n "$vip" ]; then
		# формат: четыре точечных октета, все 0-255.
		case "$vip" in
			*[!0-9.]*) sb_err "некорректный VIP '$vip'"; return 1 ;;
		esac
		local vip_ok=0
		[ "$(printf '%s' "$vip" | awk -F. 'NF==4 {ok=1; for(i=1;i<=4;i++) if($i=="" || $i>255) ok=0; print ok}')" = "1" ] \
			&& vip_ok=1
		[ "$vip_ok" = "1" ] || {
			sb_err "некорректный VIP '$vip' (ожидается IPv4)"
			return 1
		}
		# в LAN-подсети и не занят нашими.
		sb_state_call "print(nb.allocateVip('$lan_cidr', $vips_json) == '$vip' ? 'ok' : 'bad')" | grep -q '^ok$' || {
			sb_err "VIP $vip вне диапазона.240-.250 LAN-подсети или уже занят"
			return 1
		}
	else
		vip="$(sb_state_call "print(nb.allocateVip('$lan_cidr', $vips_json))")"
		case "$vip" in
			''|null)
				sb_err "нет свободного VIP в диапазоне.240-.250"
				return 1
				;;
		esac
	fi

	# --- ключи ---
	keys="$(sb_gen_keypair)" || return 1
	priv="${keys%%	*}"
	pub="${keys#*	}"
	sid="$(sb_gen_short_id)" || return 1
	# v1.2: стенды (/stand/<code>/) удалены вместе с web UI 7789;
	# stand_code больше не генерируется и не пишется в UCI.

	# --- идентификаторы ---
	slug="$(sb_slug "$name")"
	[ -n "$slug" ] || slug='in'
	fw_rule="sing-bounds-in-$slug"

	# --- firewall ДО UCI: отказ fw оставляет state нетронутым ---
	sb_fw_open "$fw_rule" "$port" || {
		sb_err "не могу открыть порт $port в firewall (правило $fw_rule)"
		return 1
	}

	# --- UCI ---
	sb_uci_touch
	# id инбаунда = ГЕНЕРИРОВАННЫЙ, НЕ имя uci-секции:
	# UCI переиспользует cfg-имена после удалений — старые клиенты
	# «прилипали» к новому инбаунду с совпавшим cfg-именем 
	iid="$(sb_gen_id in)" || { sb_fw_close "$fw_rule"; return 1; }
	section="$(uci add "$SB_UCI_CFG" inbound 2>/dev/null)" || {
		sb_fw_close "$fw_rule"
		sb_err "uci add inbound провалился"
		return 1
	}
	if ! { uci set "$SB_UCI_CFG.$section.id=$iid" \
		&& uci set "$SB_UCI_CFG.$section.name=$name" \
		&& uci set "$SB_UCI_CFG.$section.port=$port" \
		&& uci set "$SB_UCI_CFG.$section.vip=$vip" \
		&& uci set "$SB_UCI_CFG.$section.sni=$sni" \
		&& uci set "$SB_UCI_CFG.$section.enabled=1" \
		&& uci set "$SB_UCI_CFG.$section.private_key=$priv" \
		&& uci set "$SB_UCI_CFG.$section.public_key=$pub" \
		&& uci set "$SB_UCI_CFG.$section.short_id=$sid" \
		&& uci set "$SB_UCI_CFG.$section.fw_rule=$fw_rule"; }; then
		uci delete "$SB_UCI_CFG.$section"
		sb_fw_close "$fw_rule"
		sb_err "не могу записать опции инбаунда в UCI"
		return 1
	fi
	uci commit "$SB_UCI_CFG" || {
		sb_err "uci commit singbounds провалился"
		return 1
	}
	sb_uci_backup

	# --- сервис ---
	if ! /etc/init.d/singbounds restart >/dev/null 2>&1; then
		sb_err "инбаунд записан (port=$port vip=$vip), но рестарт сервиса провалился — см. logread"
		return 1
	fi

	# --- VIP-устройство : ПОСЛЕ успешного рестарта ---
	# VIP-видимость — надстройка над рабочим инбаундом: sb_vip_up сам
	# глушит свои отказы в лог, НЕ валит создание инбаунда (rc add-а
	# не зависит от odhcpd).
	sb_vip_up "$vip" || true

	printf '%s\t%s\t%s\n' "$iid" "$port" "$vip"
	return 0
}

# sb_backend_del_inbound <id> — закрыть fw-правило, удалить UCI-секции
# инбаунда и его клиентов, рестарт. Отказ на любом шаге — с stderr.
# id — ОПЦИЯ.id инбаунда (генерированная in…); секция ищется по ней,
# НЕ по имени секции (cfg-имена переиспользуются — 
sb_backend_del_inbound() {
	local id sect fw_rule client_sect vip
	id="${1:-}"
	sb_id_ok "$id" || { sb_err "некорректный id инбаунда"; return 1; }

	# Резолв секции по опции id (первая с совпавшей.id).
	sect="$(uci -q show "$SB_UCI_CFG" 2>/dev/null \
		| sed -n "s/^$SB_UCI_CFG\.\([^.]*\)\.id='$id'\$/\1/p" | head -n 1)"
	[ -n "$sect" ] || { sb_err "инбаунд $id не найден"; return 1; }

	fw_rule="$(uci -q get "$SB_UCI_CFG.$sect.fw_rule")"
	[ -n "$fw_rule" ] || { sb_err "инбаунд $id не найден"; return 1; }

	# VIP-устройство снимаем ДО UCI-delete: vip читается из ещё
	# существующей секции. Снимаем ip-алиас и НАШУ dhcp-host запись (по
	# ownership-маркеру 'Sing-bounds Tunnel'; чужие с тем же ip не
	# трогаем — см. vip.sh). Отказ НЕ валит удаление инбаунда.
	vip="$(uci -q get "$SB_UCI_CFG.$sect.vip")"
	if [ -n "$vip" ]; then
		sb_vip_down "$vip" || \
			logger -t singbounds "backend: VIP $vip не снят (del_inbound $id)"
	fi

	# Сначала UCI-удаление (клиенты + инбаунд), потом fw — при отказе
	# fw-слоя state уже без инбаунда, а fw_close можно повторить
	#; обратный порядок оставил бы осиротевшее правило.
	# КРИТИЧНО (Поэтому цикл «найди первый, удали, повтори» (как в
	# sb_fw_close), каждая итерация видит свежую нумерацию.
	while client_sect="$(uci -q show "$SB_UCI_CFG" 2>/dev/null \
		| sed -n "s/^$SB_UCI_CFG\.\([^.]*\)\.inbound='$id'\$/\1/p" | head -n 1)" \
		&& [ -n "$client_sect" ]; do
		uci -q delete "$SB_UCI_CFG.$client_sect"
	done
	uci -q delete "$SB_UCI_CFG.$sect" || {
		sb_err "не могу удалить UCI-секцию инбаунда $id"
		return 1
	}
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	sb_fw_close "$fw_rule" || {
		sb_err "UCI удалён, но fw-правило $fw_rule не закрылось — см. лог"
		return 1
	}

	# Пустое состояние: render уйдёт в rollback и restart НЕ остановит
	# наш sing-box (rollback-семантика: «работающий сервис не тронут»).
	# Это наш процесс — обязателен явный stop, иначе он останется жить
	# на удалённом порту. НЕ restart: restart с пустым state отклонится
	# ДО stop, процесс переживёт удаление инбаунда (# Останавливаем только если наш процесс действительно жив.
	if pgrep -f 'sing-box run -c /etc/sing-bounds/config.json' >/dev/null 2>&1; then
		/etc/init.d/singbounds stop >/dev/null 2>&1 || \
			logger -t singbounds "backend: del_inbound: stop сервиса провалился"
	else
		# непустой state — штатный restart (check-and-rollback)
		/etc/init.d/singbounds restart >/dev/null 2>&1 || \
			logger -t singbounds "backend: del_inbound: рестарт сервиса отклонён"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# toggle/edit/check_wan.
# ---------------------------------------------------------------------------

# sb_resolve_inbound <id> -> имя UCI-секции на stdout (пусто = не найден).
# Резолв по ОПЦИИ id (sed-паттерн по uci show, как в del_inbound) —
# cfg-имена переиспользуются, опция id стабильна.
sb_resolve_inbound() {
	uci -q show "$SB_UCI_CFG" 2>/dev/null \
		| sed -n "s/^$SB_UCI_CFG\.\([^.]*\)\.id='$1'\$/\1/p" | head -n 1
}

# sb_resolve_client <id> -> имя UCI-секции клиента (пусто = не найден).
# id клиента глобальный, не привязан к инбаунду.
sb_resolve_client() {
	uci -q show "$SB_UCI_CFG" 2>/dev/null \
		| sed -n "s/^$SB_UCI_CFG\.\([^.]*\)\.id='$1'\$/\1/p" | head -n 1
}

# sb_backend_toggle_inbound <id> <0|1>
# Выключенный инбаунд НЕ удаляется: uci set enabled='0', renderConfig
# пропускает его , UCI-секция/клиенты/ключи остаются. Флаг fw
# НЕ трогаем: порт выключенного считается занятым (контракт атомарности—
# правило держим, чтобы повторное включение не встретило коллизию).
# Стенд не перегенерируем: карточка остаётся, ссылка не меняется
# (бейдж погаснет на фронте из list.enabled).
sb_backend_toggle_inbound() {
	local id sect enabled
	id="${1:-}"
	enabled="${2:-}"
	sb_id_ok "$id" || { sb_err "некорректный id инбаунда"; return 1; }
	case "$enabled" in
		0|1) ;;
		*) sb_err "enabled должен быть 0 или 1"; return 1 ;;
	esac

	sect="$(sb_resolve_inbound "$id")"
	[ -n "$sect" ] || { sb_err "инбаунд $id не найден"; return 1; }

	uci set "$SB_UCI_CFG.$sect.enabled=$enabled" || {
		sb_err "не могу записать enabled=$enabled для инбаунда $id"
		return 1
	}
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	/etc/init.d/singbounds restart >/dev/null 2>&1 || {
		sb_err "флаг записан (enabled=$enabled), но рестарт сервиса провалился — см. logread"
		return 1
	}
	printf 'toggled\t%s\n' "$enabled"
	return 0
}

# sb_backend_toggle_client <id> <0|1>
# id клиента глобальный; disabled-клиент не попадает в users инбаунда
#, uuid сохраняется. Стенд-реген: карточка
# остаётся, QR/ссылка погаснут на фронте (фронт сам скрывает по
# enabled), но содержимое стенда обновляем — там только включённые
# клиенты (реген строится по state, фильтра не делает — погасим в
# фронте; стенду оставляем полный список, человек увидит всех).
sb_backend_toggle_client() {
	local id sect enabled inbound
	id="${1:-}"
	enabled="${2:-}"
	sb_id_ok "$id" || { sb_err "некорректный id клиента"; return 1; }
	case "$enabled" in
		0|1) ;;
		*) sb_err "enabled должен быть 0 или 1"; return 1 ;;
	esac

	sect="$(sb_resolve_client "$id")"
	[ -n "$sect" ] || { sb_err "клиент $id не найден"; return 1; }
	# принадлежность (для регена стенда): опция inbound хранит id
	# родительского инбаунда
	inbound="$(uci -q get "$SB_UCI_CFG.$sect.inbound")"

	uci set "$SB_UCI_CFG.$sect.enabled=$enabled" || {
		sb_err "не могу записать enabled=$enabled для клиента $id"
		return 1
	}
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	/etc/init.d/singbounds restart >/dev/null 2>&1 || {
		sb_err "флаг записан (enabled=$enabled), но рестарт сервиса провалился — см. logread"
		return 1
	}

	printf 'toggled\t%s\n' "$enabled"
	return 0
}

# sb_backend_edit_inbound <id> [name] [port] [sni]
# Пустые параметры = не менять. Валидации — ДО мутаций.
# Смена порта: sb_fw_open(нового) ДО uci-мутаций (отказ fw оставляет
# UCI нетронутым), sb_fw_close(старого) ПОСЛЕ успешного рестарта
# (иначе rollback-рестарт остался бы без правила). sni -> uci
# inbound.sni.
sb_backend_edit_inbound() {
	local id sect name port sni cur_port fw_rule cur_name port_changed
	id="${1:-}"
	name="${2:-}"
	port="${3:-}"
	sni="${4:-}"

	sb_id_ok "$id" || { sb_err "некорректный id инбаунда"; return 1; }
	sect="$(sb_resolve_inbound "$id")"
	[ -n "$sect" ] || { sb_err "инбаунд $id не найден"; return 1; }

	cur_name="$(uci -q get "$SB_UCI_CFG.$sect.name")"
	cur_port="$(uci -q get "$SB_UCI_CFG.$sect.port")"
	fw_rule="$(uci -q get "$SB_UCI_CFG.$sect.fw_rule")"
	[ -n "$cur_port" ] || { sb_err "инбаунд $id не найден"; return 1; }
	[ -n "$fw_rule" ] || { sb_err "инбаунд $id не найден"; return 1; }

	# --- валидации ДО мутаций ---
	if [ -n "$name" ] && [ "$name" != "$cur_name" ]; then
		# имя попадает в TAB-протоколы/JSON/HTML — контрольные символы
		# отклоняем (как имя клиента add_client).
		case "$name" in
			*[[:cntrl:]]*)
				sb_err "имя инбаунда не должно содержать управляющие символы"
				return 1
				;;
		esac
	fi
	port_changed=0
	if [ -n "$port" ] && [ "$port" != "$cur_port" ]; then
		case "$port" in
			''|*[!0-9]*)
				sb_err "порт должен быть числом (получено: '$port')"
				return 1
				;;
		esac
		[ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
			sb_err "порт должен быть в диапазоне 1-65535"
			return 1
		}
		# занятость: чужие листенеры + НАШИ порты, КРОМЕ своего текущего
		# (свой меняем — он «свободен» для себя). Итог занятости = любое
		# чужое прослушивание (наш процесс при живом инбаунде слушает
		# cur_port — НЕ новый; новый порт занят кем-то другим).
		# sb_listening_ports многострочный: case-матчинг по сырой
		# переменной НЕ находит порт (переносы строк ломают подстроку
		# « 443 » — Сплющиваем в одну строку пробелами.
		local listeners our_ports p
		listeners="$(sb_listening_ports)"
		our_ports=''
		for p in $(sb_taken_ports); do
			[ "$p" = "$cur_port" ] && continue
			our_ports="$our_ports $p"
		done
		case " $listeners $our_ports " in
			*" $port "*)
				sb_err "порт $port занят"
				return 1
				;;
		esac
		port_changed=1
	fi
	if [ -n "$sni" ]; then
		case "$sni" in
			''|*[!A-Za-z0-9.-]*)
				sb_err "некорректный SNI '$sni' (ожидается домен, например www.cloudflare.com)"
				return 1
				;;
		esac
	fi
	# ничего не меняем — честный no-op-успех (идемпотентность).
	[ "$port_changed" = "0" ] && [ -z "${name:-}" -o "$name" = "$cur_name" ] \
		&& { [ -z "$sni" ] || [ "$sni" = "$(uci -q get "$SB_UCI_CFG.$sect.sni")" ]; } \
		|| true
	if [ "$port_changed" = "0" ] \
		&& { [ -z "$name" ] || [ "$name" = "$cur_name" ]; } \
		&& { [ -z "$sni" ] || [ "$sni" = "$(uci -q get "$SB_UCI_CFG.$sect.sni")" ]; }; then
		printf 'edited\tno-changes\n'
		return 0
	fi

	# --- мутации (все проверки пройдены) ---
	# 1. порт: fw-правило НОВОГО порта открываем ДО uci — отказ fw
	# оставляет UCI нетронутым (откат не нужен).
	if [ "$port_changed" = "1" ]; then
		sb_fw_open "$fw_rule" "$port" || {
			sb_err "не могу открыть порт $port в firewall (правило $fw_rule)"
			return 1
		}
	fi

	# 2. UCI-опции.
	if [ -n "$name" ] && [ "$name" != "$cur_name" ]; then
		uci set "$SB_UCI_CFG.$sect.name=$name" || {
			[ "$port_changed" = "1" ] && sb_fw_open "$fw_rule" "$cur_port" >/dev/null 2>&1
			sb_err "не могу записать name для инбаунда $id"
			return 1
		}
	fi
	if [ "$port_changed" = "1" ]; then
		uci set "$SB_UCI_CFG.$sect.port=$port" || {
			sb_fw_open "$fw_rule" "$cur_port" >/dev/null 2>&1
			sb_err "не могу записать port для инбаунда $id"
			return 1
		}
	fi
	if [ -n "$sni" ]; then
		uci set "$SB_UCI_CFG.$sect.sni=$sni" || {
			[ "$port_changed" = "1" ] && sb_fw_open "$fw_rule" "$cur_port" >/dev/null 2>&1
			sb_err "не могу записать sni для инбаунда $id"
			return 1
		}
	fi
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	# 3. рестарт (check-and-rollback из).
	if ! /etc/init.d/singbounds restart >/dev/null 2>&1; then
		sb_err "опции записаны, но рестарт сервиса провалился — см. logread"
		return 1
	fi

	# 4. старый fw закрываем ПОСЛЕ успешного рестарта: правило
	# (fw_rule одно на инбаунд) уже пересоздано на новый порт
	# sb_fw_open-ом выше; sb_fw_open идемпотентен (пересоздал
	# правило), поэтому здесьfw_close НЕ нужен — правило уже
	# указывает на новый порт. (fw_close закрыл бы и новый!)

	printf 'edited\tok\n'
	return 0
}

# sb_backend_restart (, таб «Система») -> restarted TAB ok
# Рестарт нашего сервиса: /etc/init.d/singbounds restart. Это НЕ рестарт
# роутера: VPN-инбаунд поднимается заново за секунды (Проверяем
# выживание процесса ПОСЛЕ рестарта — rc=1 + русский stderr, если
# сервис не поднялся (ubs-ошибка уведомит фронт, статус-бейдж
# покажет «остановлен»).
sb_backend_restart() {
	local pid_before pid_after
	pid_before="$(pgrep -f 'sing-box run -c /etc/sing-bounds/config.json' | head -n 1)"
	/etc/init.d/singbounds restart >/dev/null 2>&1 || {
		sb_err "рестарт сервиса провалился — см. logread | grep sing-box"
		return 1
	}
	# procd стартует инстанс асинхронно: даём секунду и проверяем
	# процесс; если старый PID жив и НЕ сменился И конфиг не содержит
	# включённых инбаундов — это нормальная ситуация (статус проверит
	# running по факту), но пустой конфиг мы не считаем ошибкой.
	sleep 1
	pid_after="$(pgrep -f 'sing-box run -c /etc/sing-bounds/config.json' | head -n 1)"
	if [ -z "$pid_after" ]; then
		sb_err "сервис не поднялся после рестарта — см. logread | grep sing-box"
		return 1
	fi
	printf 'restarted\t%s\n' "$pid_after"
	return 0
}

# sb_backend_check_wan -> ip TAB ms
# Внешний IP: curl -s --max-time 5 ifconfig.me (таймаут жёсткий —
# контракт атомарности: rpcd не блокируется дольше ~5с). Время: busybox
# date НЕ поддерживает %N (Ошибка сети — rc=1,
# русский stderr.
sb_backend_check_wan() {
	local t0 t1 ip ms
	t0="$(sb_millis)"
	ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null)" || ip=''
	t1="$(sb_millis)"
	case "$ip" in
		''|*[!0-9.]*)
			sb_err "не могу получить внешний IP (curl ifconfig.me, таймаут 5 c)"
			return 1
			;;
	esac
	ms=$(( ${t1:-0} - ${t0:-0}))
	[ "$ms" -lt 0 ] && ms=0
	printf '%s\t%s\n' "$ip" "$ms"
	return 0
}

# sb_backend_add_client <inbound> <name> -> id TAB uuid
sb_backend_add_client() {
	local inbound name uuid section cid in_sect
	inbound="${1:-}"
	name="${2:-}"
	sb_id_ok "$inbound" || { sb_err "некорректный id инбаунда"; return 1; }
	[ -n "$name" ] || { sb_err "имя клиента не задано"; return 1; }
	# Имя клиента попадает в вывод метода list и в vless-ссылку
	#, поэтому управляющие символы отклоняем на входе.
	case "$name" in
		*[[:cntrl:]]*)
			sb_err "имя клиента не должно содержать управляющие символы (таб, перевод строки и т.п.)"
			return 1
			;;
	esac
	# Резолв секции инбаунда по ОПЦИИ id (cfg-имена ненадёжны).
	in_sect="$(uci -q show "$SB_UCI_CFG" 2>/dev/null \
		| sed -n "s/^$SB_UCI_CFG\.\([^.]*\)\.id='$inbound'\$/\1/p" | head -n 1)"
	[ -n "$in_sect" ] || { sb_err "инбаунд $inbound не найден"; return 1; }
	uci -q get "$SB_UCI_CFG.$in_sect.port" >/dev/null 2>&1 || {
		sb_err "инбаунд $inbound не найден"
		return 1
	}

	uuid="$(sb_gen_uuid)" || return 1
	# id клиента = ГЕНЕРИРОВАННЫЙ уникальный, НЕ имя uci-
	# секции: счётчик cfg-имён сбрасывается при uninstall+install, что
	# давало коллизии id между клиентами разных установок
	#). Имя секции — внутреннее, наружу отдаём только id.
	cid="$(sb_gen_client_id)" || return 1

	sb_uci_touch
	section="$(uci add "$SB_UCI_CFG" client 2>/dev/null)" || {
		sb_err "uci add client провалился"
		return 1
	}
	if ! { uci set "$SB_UCI_CFG.$section.id=$cid" \
		&& uci set "$SB_UCI_CFG.$section.inbound=$inbound" \
		&& uci set "$SB_UCI_CFG.$section.name=$name" \
		&& uci set "$SB_UCI_CFG.$section.uuid=$uuid"; }; then
		uci delete "$SB_UCI_CFG.$section"
		sb_err "не могу записать опции клиента в UCI"
		return 1
	fi
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	/etc/init.d/singbounds restart >/dev/null 2>&1 || {
		sb_err "клиент записан, но рестарт сервиса провалился — см. logread"
		return 1
	}

	printf '%s\t%s\n' "$cid" "$uuid"
	return 0
}

# sb_backend_del_client <inbound> <id>
sb_backend_del_client() {
	local inbound id sect found
	inbound="${1:-}"
	id="${2:-}"
	sb_id_ok "$inbound" || { sb_err "некорректный id инбаунда"; return 1; }
	sb_id_ok "$id" || { sb_err "некорректный id клиента"; return 1; }

	# Поиск секции клиента по ОПЦИИ id (не по имени секции): id
	# генерируется независимо, имя секции — внутреннее cfg-имя
	# — устойчивость к коллизиям id. Перебор клиентских секций
	# устойчив и к анонимным, и к named.
	found=''
	for sect in $(uci -q show "$SB_UCI_CFG" 2>/dev/null \
		| sed -n "s/^$SB_UCI_CFG\.\([^.]*\)\.id='$id'$/\1/p"); do
		# принадлежность этому инбаунду — проверяем опцией inbound
		if [ "$(uci -q get "$SB_UCI_CFG.$sect.inbound")" = "$inbound" ]; then
			found="$sect"
			break
		fi
	done
	[ -n "$found" ] || {
		sb_err "клиент $id не найден в инбаунде $inbound"
		return 1
	}

	uci -q delete "$SB_UCI_CFG.$found" || {
		sb_err "не могу удалить UCI-секцию клиента $id"
		return 1
	}
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	/etc/init.d/singbounds restart >/dev/null 2>&1 || \
		logger -t singbounds "backend: del_client: рестарт сервиса отклонён"

	return 0
}

# ---------------------------------------------------------------------------
# v1.2: блок стенд-страниц и web UI 7789 удалены — весь
# интерфейс в LuCI. Функции sb_stand_*/sb_html_escape/sb_backend_get_stand
# убраны вместе с их вызовами (add_inbound/edit/toggle/del_client).
# ---------------------------------------------------------------------------

# sb_backend_get_links <inbound> -> JSON {links:[{name, link}]}
# host: внешний IP; ссылка — nb.buildVlessLink.
sb_backend_get_links() {
	local inbound host
	inbound="${1:-}"
	sb_id_ok "$inbound" || { sb_err "некорректный id инбаунда"; return 1; }
	sb_state_call "print(length(filter(state.inbounds, i => i.id == '$inbound')))" \
		| grep -q '^[1-9][0-9]*$' || {
		sb_err "инбаунд $inbound не найден"
		return 1
	}

	host="$(sb_wan_host)" || return 1

	# Обёртка-объект: rpcd/ubus отклоняет top-level массив как ответ.
	sb_state_call "
		let inb = filter(state.inbounds, i => i.id == '$inbound')[0];
		print(sprintf('%J', {
			links: map(inb.clients, c => ({
				name: c.name,
				link: nb.buildVlessLink(inb, c, state.global, '$host')
			}))
		}))
	"
}

# ---------------------------------------------------------------------------
# TAILSCALE (v1.3): mesh-туннель в той же модале «Новый туннель».
#
# Один туннель на роутер (один tailscaled = одна сеть): UCI-секция
# singbounds.tailscale хранит server/server_kind/advertise_routes;
# authkey — файл /etc/sing-bounds/tsc_authkey (umask 077, НЕ в UCI:
# ключ в конфиге читается любым `uci show`).
#
# server_kind: official (login.tailscale.com), routerich
# (https://rc.routerich.ru), custom (headscale/ionscale/совместимый).
# КОНТРАКТ всех sb_tsc_*: JSON на stdout, rc=0; отказ — rc!=0,
# диагностика на stderr (плагин превращает в ubus-ошибку).
# ---------------------------------------------------------------------------

SB_TSC_KEY=/etc/sing-bounds/tsc_authkey
SB_TSC_DIR=/var/etc/sing-bounds-tsc

# sb_tsc_installed -> rc 0, если пакет tailscale стоит.
sb_tsc_installed() {
	[ -x /usr/sbin/tailscale ] && [ -x /usr/sbin/tailscaled ]
}

# sb_tsc_kind_of <server> -> official|routerich|custom.
sb_tsc_kind_of() {
	case "$1" in
		'') echo official ;;
		https://rc.routerich.ru|https://rc.routerich.ru/*) echo routerich ;;
		*) echo custom ;;
	esac
}

# sb_tsc_json -> вывод `tailscale status --json` (пусто, если не стоит).
sb_tsc_json() {
	sb_tsc_installed || return 0
	tailscale status --json 2>/dev/null
}

# sb_tsc_srv -> адрес сервера из UCI (пусто = official).
sb_tsc_srv() {
	uci -q get "$SB_UCI_CFG.tailscale.server"
}

# sb_tsc_upflags -> аргументы `tailscale up`.
# --netfilter-mode=off: правила firewall создаём сами (наш firewall.sh
# владеет nft; дублирование правил tailscaled недопустимо).
# --accept-dns=false: DNS роутера не отдаём tailnet-серверу.
sb_tsc_upflags() {
	local srv routes
	srv="$(sb_tsc_srv)"
	routes="$(uci -q get "$SB_UCI_CFG.tailscale.advertise_routes")"
	printf '%s' '--netfilter-mode=off --accept-dns=false'
	[ -n "$srv" ] && printf ' --login-server=%s' "$srv"
	[ -n "$routes" ] && printf ' --advertise-routes=%s' "$routes"
}

# sb_tsc_start -> запустить/перезапустить tailscaled, дождаться ответа.
sb_tsc_start() {
	local t=0
	/etc/init.d/tailscale enable >/dev/null 2>&1
	/etc/init.d/tailscale restart >/dev/null 2>&1
	while [ "$t" -lt 20 ]; do
		[ -n "$(sb_tsc_json | jsonfilter -e '@.BackendState' 2>/dev/null)" ] && return 0
		sleep 1
		t=$((t + 1))
	done
	sb_err "tailscaled не ответил за 20 секунд (logread | grep tailscale)"
	return 1
}

# sb_tsc_backend_status -> JSON статуса Tailscale-туннеля для LuCI.
# {configured, installed, state, server, server_kind, authurl, self_ip, version}
# configured=true только при наличии UCI-секции tailscale (фронт по
# этому полю делает опцию Tailscale в модале недоступной).
sb_tsc_backend_status() {
	local inst=false cfg=false st="" url="" ip="" ver="" srv kind
	sb_tsc_installed && { inst=true; ver="$(tailscale version 2>/dev/null | head -n1)"; }
	[ "$(uci -q get "$SB_UCI_CFG.tailscale.enabled")" = 1 ] && cfg=true
	srv="$(sb_tsc_srv)"
	kind="$(sb_tsc_kind_of "$srv")"
	if $cfg && $inst; then
		st="$(sb_tsc_json | jsonfilter -e '@.BackendState' 2>/dev/null)"
		url="$(sb_tsc_json | jsonfilter -e '@.AuthURL' 2>/dev/null)"
		[ -z "$st" ] && st=Starting
		ip="$(sb_tsc_json | jsonfilter -e '@.Self.TailscaleIPs[0]' 2>/dev/null)"
	fi
	printf '{"configured":%s,"installed":%s,"state":"%s","server":"%s","server_kind":"%s","authurl":"%s","self_ip":"%s","version":"%s"}\n' \
		"$cfg" "$inst" "$st" "$srv" "$kind" "$url" "$ip" "$ver"
}

# sb_tsc_server_set <server> <authkey> [advertise_routes]
# Валидация ДО мутаций. Пустой server = official (ключ при этом
# игнорируется: у официального входа ключей нет, только браузер).
sb_tsc_server_set() {
	local srv key routes old
	srv="$(printf '%s' "${1:-}" | tr -d '\r ')"
	key="$(printf '%s' "${2:-}" | tr -d '\r ')"
	routes="$(printf '%s' "${3:-}" | tr -d '\r ')"

	case "$srv" in
		'') key="" ;;
		http://*|https://*)
			printf '%s' "$srv" | grep -qE \
				'^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' || {
				sb_err "адрес сервера записан с ошибкой — пример: https://rc.routerich.ru"
				return 1
			}
			;;
		*)
			sb_err "адрес сервера должен начинаться с https://"
			return 1
			;;
	esac

	# Ключ (auth key): символы base64-подобного алфавита, разумная длина.
	if [ -n "$key" ]; then
		[ "${#key}" -le 300 ] && printf '%s' "$key" \
			| grep -qE '^[A-Za-z0-9_:.+/=-]+$' || {
			sb_err "в ключе есть лишние символы — скопируйте его целиком, без пробелов"
			return 1
		}
	fi

	# Маршруты: CIDR через запятую (пусто = не анонсировать).
	if [ -n "$routes" ]; then
		printf '%s' "$routes" | grep -qE \
			'^[0-9./,[:space:]]+$' || {
			sb_err "маршруты: ожидается список CIDR через запятую (например 192.168.1.0/24)"
			return 1
		}
	fi

	old="$(sb_tsc_srv)"

	# Пакет НЕ ставим принудительно (флеш часто мал): пакет
	# устанавливается вручную в Настройках; здесь только проверка.
	sb_tsc_installed || {
		sb_err "tailscale не установлен — сначала установите пакет в Настройках (выбор: память роутера или USB-носитель)"
		return 3
	}

	sb_uci_touch
	uci -q set "$SB_UCI_CFG.tailscale=tailscale"
	uci -q set "$SB_UCI_CFG.tailscale.server=$srv"
	uci -q set "$SB_UCI_CFG.tailscale.server_kind=$(sb_tsc_kind_of "$srv")"
	uci -q set "$SB_UCI_CFG.tailscale.enabled=1"
	if [ -n "$routes" ]; then
		uci -q set "$SB_UCI_CFG.tailscale.advertise_routes=$routes"
	else
		uci -q delete "$SB_UCI_CFG.tailscale.advertise_routes"
	fi
	uci commit "$SB_UCI_CFG" || { sb_err "uci commit провалился"; return 1; }
	sb_uci_backup

	# Ключ — в файл 0600 (не в UCI).
	mkdir -p /etc/sing-bounds
	if [ -n "$key" ]; then
		( umask 077; printf '%s' "$key" > "$SB_TSC_KEY" )
	else
		rm -f "$SB_TSC_KEY"
	fi

	# Смена сервера на живом туннеле: logout, чтобы up пошёл к новому.
	if [ "$old" != "$srv" ] && sb_tsc_installed; then
		case "$(sb_tsc_json | jsonfilter -e '@.BackendState' 2>/dev/null)" in
			Running|NeedsMachineAuth|Starting|Stopped)
				pkill -f 'tailscale up' >/dev/null 2>&1
				tailscale logout >/dev/null 2>&1
				;;
		esac
	fi

	printf 'ok\n'
}

# sb_tsc_login -> подключение к сети.
# С ключом: tailscale up --auth-key (Routerich/headscale-автовход).
# Без ключа: tailscale up в фоне; до 15 сек ждём AuthURL и отдаём
# её фронту (юзер открывает в браузере, вход через Google/GitHub/etc).
sb_tsc_login() {
	local i=0 st url key log
	sb_tsc_installed || { sb_err "tailscale не установлен"; return 1; }

	sb_tsc_start || return 1

	st="$(sb_tsc_json | jsonfilter -e '@.BackendState' 2>/dev/null)"
	[ "$st" = Running ] && { printf '{"state":"Running"}\n'; return 0; }

	pkill -f 'tailscale up' >/dev/null 2>&1
	log="$SB_TSC_DIR/up.log"
	mkdir -p "$SB_TSC_DIR"

	key="$(cat "$SB_TSC_KEY" 2>/dev/null)"
	if [ -n "$key" ]; then
		# shellcheck disable=SC2046
		tailscale up --reset $(sb_tsc_upflags) --auth-key="$key" > "$log" 2>&1
		st="$(sb_tsc_json | jsonfilter -e '@.BackendState' 2>/dev/null)"
		case "$st" in
			Running|NeedsMachineAuth)
				printf '{"state":"%s"}\n' "$st"
				return 0
				;;
		esac
		sb_err "сервер не принял ключ: $(tail -n 2 "$log" 2>/dev/null | sed "s#$key#***#g" | tr '\n' ' ')"
		return 1
	fi

	# Без ключа: up в фоне, ждём AuthURL.
	# shellcheck disable=SC2046
	( tailscale up --reset $(sb_tsc_upflags) > "$log" 2>&1 ) >/dev/null 2>&1 &
	while [ "$i" -lt 15 ]; do
		sleep 1
		i=$((i + 1))
		url="$(sb_tsc_json | jsonfilter -e '@.AuthURL' 2>/dev/null)"
		[ -z "$url" ] && url="$(grep -o 'https\{0,1\}://[^[:space:]]*' "$log" 2>/dev/null | head -n1)"
		[ -n "$url" ] && { printf '{"state":"NeedsLogin","authurl":"%s"}\n' "$url"; return 0; }
		st="$(sb_tsc_json | jsonfilter -e '@.BackendState' 2>/dev/null)"
		[ "$st" = Running ] && { printf '{"state":"Running"}\n'; return 0; }
	done
	sb_err "tailscale не выдал ссылку для входа: $(tail -n 2 "$log" 2>/dev/null | tr '\n' ' ')"
	return 1
}

# sb_tsc_logout -> выход из сети (сервер/ключ остаются в UCI).
sb_tsc_logout() {
	sb_tsc_installed || { sb_err "tailscale не установлен"; return 1; }
	pkill -f 'tailscale up' >/dev/null 2>&1
	tailscale logout >/dev/null 2>&1 || { sb_err "logout отклонён"; return 1; }
	printf 'ok\n'
}

# sb_tsc_remove -> полное удаление Tailscale-туннеля (пакет остаётся).
sb_tsc_remove() {
	sb_tsc_installed && {
		pkill -f 'tailscale up' >/dev/null 2>&1
		tailscale logout >/dev/null 2>&1
		/etc/init.d/tailscale stop >/dev/null 2>&1
		/etc/init.d/tailscale disable >/dev/null 2>&1
	}
	uci -q delete "$SB_UCI_CFG.tailscale"
	uci commit "$SB_UCI_CFG"
	sb_uci_backup
	rm -f "$SB_TSC_KEY"
	rm -rf "$SB_TSC_DIR"
	printf 'ok\n'
}

# ---------------------------------------------------------------------------
# УСТАНОВКА TAILSCALE В РУЧНОМ РЕЖИМЕ (Настройки): пользователь сам решает,
# ставить пакет и куда — в память роутера (overlay) или на USB-носитель.
# Модал создания туннеля пакет НЕ ставит: она предлагает сделать это
# заранее в Настройках (флеш роутера часто слишком мал для 26 МБ пакета).
# ---------------------------------------------------------------------------

# sb_tsc_free_kb <path> -> свободно (КБ) в ФС точки (пусто = неизвестно).
sb_tsc_free_kb() {
	df -k "$1" 2>/dev/null | tail -n1 | awk '{print $4}'
}

# sb_tsc_pkg_size_kb -> размер пакета tailscale после распаковки (КБ).
sb_tsc_pkg_size_kb() {
	if command -v apk >/dev/null 2>&1; then
		# apk info -s печатает «<size> MiB» — умножаем на 1024.
		apk info -s tailscale 2>/dev/null \
			| sed -n 's/^installed size: \([0-9.]*\)[[:space:]]*MiB/\1/p' \
			| awk '{printf "%d\n", $1*1024; exit}'
	else
		# opkg не знает размер заранее; ~26 МБ известная величина пакета.
		echo 26624
	fi
}

# sb_tsc_usb_mounts -> смонтированные блочные устройства (точки для
# установки «на флешку»): /dev/sd* или /dev/nvme*, ext4/f2fs.
sb_tsc_usb_mounts() {
	local dev mnt fst
	mount 2>/dev/null | while read -r dev on mnt fst rest; do
		case "$dev" in
			/dev/sd*|/dev/nvme*)
				case "$fst" in
					ext4|f2fs|ext2|ext3) printf '%s\t%s\n' "$dev" "$mnt" ;;
				esac
				;;
		esac
	done
}

# sb_tsc_install_on <where>: where = "overlay" | "usb:<точка>".
# Установка пакета с целевой ФС: overlay — обычный apk/opkg add;
# usb — apk --root (<сила overlay-паттерна не нужна: package попадает
# на USB, а симлинки в /usr/sbin дают бинарники системе).
# ДО установки проверяем свободное место: отказ ДО мутаций.
sb_tsc_install_on() {
	local where need have mnt dev tmp
	where="${1:-overlay}"
	need="$(sb_tsc_pkg_size_kb)"
	[ -n "$need" ] || need=26624

	case "$where" in
		overlay)
			# в запас — 20% сверху (структура каталогов, конфиги).
			have="$(sb_tsc_free_kb /)"
			[ -n "$have" ] && [ "$have" -lt $((need + need / 5)) ] && {
				sb_err "недостаточно места в памяти роутера: нужно ~$((need/1024)) МБ, свободно $((have/1024)) МБ. Подключите USB-носитель и выберите его в Настройках"
				return 2
			}
			sb_tsc_install || return 1
			;;
		usb:*)
			mnt="${where#usb:}"
			[ -d "$mnt" ] || { sb_err "точка $mnt не смонтирована"; return 1; }
			have="$(sb_tsc_free_kb "$mnt")"
			[ -n "$have" ] && [ "$have" -lt $((need + need / 10)) ] && {
				sb_err "недостаточно места на $mnt: нужно ~$((need/1024)) МБ, свободно $((have/1024)) МБ"
				return 2
			}
			# apk с распаковкой прямо на носитель, затем симлинки.
			if command -v apk >/dev/null 2>&1; then
				tmp="$mnt/sb-tsc-pkg"
				mkdir -p "$tmp" || { sb_err "не могу создать $tmp"; return 1; }
				apk fetch --output "$tmp" tailscale >/dev/null 2>&1 \
					|| { rm -rf "$tmp"; sb_err "не удалось скачать пакет tailscale"; return 1; }
				# распаковка .apk (это tar.gz c подписью)
				( cd "$tmp" && \
					tar -xzf tailscale-*.apk 2>/dev/null || \
					tar -xf tailscale-*.apk 2>/dev/null ) || {
					rm -rf "$tmp"; sb_err "не удалось распаковать пакет"; return 1
				}
				mkdir -p "$mnt/usr/sbin" "$mnt/etc/init.d"
				[ -d "$tmp/usr/sbin" ] && \
					mv "$tmp"/usr/sbin/tailscale "$tmp"/usr/sbin/tailscaled \
					"$mnt/usr/sbin/" 2>/dev/null
				[ -f "$tmp/etc/init.d/tailscale" ] && \
					mv "$tmp/etc/init.d/tailscale" "$mnt/etc/init.d/" 2>/dev/null
				rm -rf "$tmp"
				mkdir -p /usr/sbin /etc/init.d
				ln -sf "$mnt/usr/sbin/tailscale" /usr/sbin/tailscale
				ln -sf "$mnt/usr/sbin/tailscaled" /usr/sbin/tailscaled
				# init-скрипт копируем в систему (он маленький, патчим start):
				[ -f "$mnt/etc/init.d/tailscale" ] && \
					cp "$mnt/etc/init.d/tailscale" /etc/init.d/tailscale
				chmod 755 /etc/init.d/tailscale 2>/dev/null
			else
				sb_err "установка на USB поддерживается только на apk (OpenWrt 24.x+)"
				return 1
			fi
			;;
		*)
			sb_err "неизвестное место установки: $where"
			return 1
			;;
	esac

	sb_tsc_installed || {
		sb_err "пакет поставился, но бинарники не найдены"
		return 1
	}
	return 0
}

# sb_tsc_backend_install_info -> JSON для карточки в Настройках:
# {installed, space_ok, free_kb, need_kb, usb: [{dev, mnt}]}
sb_tsc_backend_install_info() {
	local inst=false free need mounts_json
	sb_tsc_installed && inst=true
	free="$(sb_tsc_free_kb /)"
	need="$(sb_tsc_pkg_size_kb)"
	[ -n "$need" ] || need=26624
	mounts_json="$(sb_tsc_usb_mounts | awk -F'\t' '
		BEGIN { printf "["; n = 0 }
		{ printf "%s{\"dev\":\"%s\",\"mnt\":\"%s\"}", (n ? "," : ""), $1, $2; n = 1 }
		END { printf "]" }')"
	[ -n "$mounts_json" ] || mounts_json='[]'
	printf '{"installed":%s,"space_ok":%s,"free_kb":%s,"need_kb":%s,"usb":%s}\n' \
		"$inst" \
		"$([ -n "$free" ] && [ "$free" -ge $((need + need / 5)) ] && echo true || echo false)" \
		"${free:-0}" "$need" "$mounts_json"
}

# sb_tsc_install -> пакет tailscale из фидов OpenWrt (24.10 opkg / 25.x apk).
sb_tsc_install() {
	if command -v apk >/dev/null 2>&1; then
		apk add tailscale >/dev/null 2>&1 || {
			apk update >/dev/null 2>&1
			apk add tailscale >/dev/null 2>&1 || {
				sb_err "не удалось установить пакет tailscale (apk)"
				return 1
			}
		}
	else
		opkg install tailscale >/dev/null 2>&1 || {
			opkg update >/dev/null 2>&1
			opkg install tailscale >/dev/null 2>&1 || {
				sb_err "не удалось установить пакет tailscale (opkg)"
				return 1
			}
		}
	fi
	sb_tsc_installed || { sb_err "пакет поставился, но бинарники не найдены"; return 1; }
	return 0
}

# sb_backend_uninstall — ПОЛНОЕ удаление sing-bounds.
#
# Удаляет ВСЁ наше (карта путей install.sh — единая для install/uninstall):
# - наш sing-box-процесс + init-скрипт (stop, disable, rm);
# - виртуальные IP (ip addr del по UCI-состоянию ДО его удаления);
# - все fw-правила sing-bounds-* (sb_fw_close_all);
# - файлы: /usr/lib/sing-bounds, /www/singbounds, /etc/sing-bounds,
# singbounds-ctl, rpcd-плагин, ACL, LuCI menu.d + view-каталог;
# - uci-секцию uhttpd.singbounds (sb_webui_remove из webui.sh);
# - весь UCI-конфиг /etc/config/singbounds;
# - rpcd reload (снимает ubus-объект).
# НЕ трогает: sing-box (пакет/бинарник), чужие конфиги /etc/sing-box/,
# uhttpd.main/zmweb, dnsmasq, zapret, netshift.
#
# ВЫЗОВ ИЗ ПЛАГИНА rpcd (, главная тонкость): uninstall исполняется
# ПРОЦЕССОМ плагина /usr/libexec/rpcd/singbounds. rm этого файла НЕ убивает
# уже запущенный процесс (unix-семантика), а rpcd reload НЕ убивает нашего
# sh-процесса-потомка: rpcd шлёт сигнал объекту rpcd, потомки успевают
# допечатать ответ в pipe. ОТВЕТ ПЕЧАТАЕМ ДО rpcd reload — ответ ubus
# уходит вызывающему раньше, чем объект исчезнет.
#
# Отказ любого ШАГА — НЕ валит удаление (warn в лог, продолжаем): каждый шаг
# uninstall — максимально чистое состояние, а не транзакция; итоговый
# rc=0 c {removed:true} означает «все шаги отработали», предупреждения —
# в syslog (logread | grep singbounds).
sb_backend_uninstall() {
	local vips vip prefix pids pids2

	sb_un_log 'uninstall: начинаю полное удаление sing-bounds'

	# --- 0. VIP-устройства ---
	# Снимаем ip-алиасы и НАШИ dhcp-host записи (name='singbounds-tunnel')
	# ПО UCI-инбаундам ДО удаления UCI-состояния (sb_vip_close_all —
	# полный флоу со всеми guard'ами vip.sh). Отказ не валит uninstall.
	sb_vip_close_all || \
		sb_un_warn 'VIP-устройства сняты не полностью'
	# ГАРАНТИЯ: после удаления наших dhcp-записей dnsmasq обязан
	# перезапуститься и ПОДНЯТЬСЯ (иначе конфиг останется с удалённой
	# строкой и сеть не поднимется). sb_vip_dnsmasq_restart_checked:
	# рестарт + pgrep/порт-53 проверка живости.
	if ! sb_vip_dnsmasq_restart_checked; then
		sb_un_warn 'dnsmasq не поднялся после чистки dhcp-записей — проверьте logread!'
	fi

	# --- 1. наш sing-box-процесс + init-скрипт ---
	# Сначала stop: procd убивает инстанс (rm init-скрипта процесс не
	# останавливает — это сделала бы перезагрузка, а она запрещена).
	if [ -x /etc/init.d/singbounds ]; then
		/etc/init.d/singbounds stop >/dev/null 2>&1 \
			|| sb_un_warn 'не удалось остановить сервис singbounds (или он не был запущен)'
		/etc/init.d/singbounds disable >/dev/null 2>&1 \
			|| sb_un_warn 'не удалось disable init-скрипта singbounds'
	fi
	# Контроль: процесс обязан умереть (procd-инстанс + pgrep-проверка).
	# Ловим ВСЕ PID (наследники/зомби-форки возможны), TERM → пауза → KILL
	# выжившим.
	if pids="$(pgrep -f 'sing-box run -c /etc/sing-bounds/config.json' \
		2>/dev/null)" && [ -n "$pids" ]; then
		kill $pids 2>/dev/null \
			|| sb_un_warn 'наш sing-box-процесс жив после stop'
		sleep 2
		pids2="$(pgrep -f 'sing-box run -c /etc/sing-bounds/config.json' \
			2>/dev/null)"
		if [ -n "$pids2" ]; then
			kill -9 $pids2 2>/dev/null \
				|| sb_un_warn 'sing-box-процесс не умер даже после kill -9'
		fi
	fi
	sb_un_log 'uninstall: сервис остановлен'

	# --- 2. виртуальные IP (по UCI ДО его удаления) ---
	# VIP назначаются на br-lan чем-то внешним? НЕТ: VIP-строки — только
	# состояние для ссылок/allocateVip (см. del_inbound: адрес на br-lan
	.
	# Также «ip addr del по UCI-состоянию до удаления» —
	# на случай ручных экспериментов снимаем любой
	# назначенный адрес, равный VIP инбаунда. ГРЁХ НЕ НАВЕРШИМ: удаляем
	# только адрес, точно совпадающий с VIP ИЗ НАШЕГО UCI.
	vips="$(sb_taken_vips 2>/dev/null)"
	for vip in $vips; do
		case "$vip" in
			''|*[!0-9.]*) continue ;;
		esac
		# Точный матч: извлекаем ФАКТИЧЕСКИЙ префикс адреса (например
		# 192.168.1.240/24) и удаляем ровно его — не хардкод /24.
		# Не найден — VIP не назначен, пропускаем молча.
		prefix="$(ip -4 addr show br-lan 2>/dev/null \
			| awk -v v="$vip" '$2 ~ "^" v "/" {print $2}')"
		case "$prefix" in
			*/*)
				ip addr del "$prefix" dev br-lan 2>/dev/null \
					|| sb_un_warn "не могу снять VIP $vip с br-lan"
				;;
		esac
	done
	sb_un_log 'uninstall: виртуальные IP сняты (если были назначены)'

	# --- 3. fw-правила sing-bounds-* (sb_fw_close_all) ---
	# sb_fw_close_all печатает количество удалённых секций на stdout —
	# глушим stdout, диагностика идёт через sb_fw_log (stderr/syslog).
	if sb_fw_close_all >/dev/null 2>&1; then
		sb_un_log 'uninstall: firewall-правила sing-bounds- удалены'
	else
		sb_un_warn 'sb_fw_close_all не отработал — проверьте firewall вручную'
	fi

	# --- 4. файлы по карте путей ---
	rm -rf /usr/lib/sing-bounds /www/singbounds /etc/sing-bounds \
		|| sb_un_warn 'не удалось удалить каталоги /usr/lib|www|etc/sing-bounds'
	rm -f /usr/bin/singbounds-ctl /usr/libexec/rpcd/singbounds \
		/usr/share/rpcd/acl.d/luci-app-singbounds.json \
		/usr/share/rpcd/acl.d/singbounds.json \
		/usr/share/luci/menu.d/luci-app-singbounds.json \
		|| sb_un_warn 'не удалось удалить файлы singbounds-ctl/rpcd/ACL/menu'
	# ACL-хвост /usr/share/rpcd/acl.d/
	# остался после uninstall на роутере — чистим оба имени ACL.
	rm -rf /usr/lib/luci-static/resources/view/singbounds \
		|| sb_un_warn 'не удалось удалить LuCI view-каталог singbounds'
	# /www-копия view-файлов: LuCI этого роутера грузит их именно из /www
	# (install кладёт обе копии — чистим обе).
	rm -rf /www/luci-static/resources/view/singbounds \
		|| sb_un_warn 'не удалось удалить LuCI view-каталог singbounds'
	# Каталог ранних экспериментальных установок.
	rm -rf /opt/sing-bounds \
		|| sb_un_warn 'не удалось удалить /opt/sing-bounds'
	# init-скрипт удаляем ЗДЕСЬ (после stop/disable): rc.d-симлинки
	# снимает enable-отмена, сам файл — обычный rm.
	rm -f /etc/init.d/singbounds \
		|| sb_un_warn 'не могу удалить /etc/init.d/singbounds'
	sb_un_log 'uninstall: файлы по карте путей удалены'

	# --- 5. uhttpd-секция (web UI v1.x, если осталась от старых установок) ---
	# Guard: удаляем только СВОЮ секцию uhttpd.singbounds.
	if uci -q get uhttpd.singbounds >/dev/null 2>&1; then
		uci -q delete uhttpd.singbounds \
			|| sb_un_warn 'не могу удалить uci-секцию uhttpd.singbounds'
		uci -q commit uhttpd \
			|| sb_un_warn 'uci commit uhttpd провалился'
		# reload пересоздаёт ВСЕ инстансы uhttpd (LuCI 80/443 и zmweb 7788
		# поднимаются тем же reload-ом — штатно).
		/etc/init.d/uhttpd reload >/dev/null 2>&1 \
			|| sb_un_warn 'uhttpd reload не сработал'
		sb_un_log 'uninstall: uhttpd.singbounds удалён, порт 7789 закрыт'
	else
		sb_un_log 'uninstall: uhttpd.singbounds отсутствовал'
	fi

	# --- 6. UCI-конфиг singbounds ---
	uci -q delete singbounds 2>/dev/null \
		|| sb_un_log 'uninstall: /etc/config/singbounds отсутствовал'
	uci -q commit singbounds 2>/dev/null
	# uci delete у удаляемого файла — сам файл остаётся пустым на диске
	# при «delete» top-level конфига? НЕТ: `uci delete <config>` стирает
	# и файл. Страховка: пустой файл тоже убираем.
	[ -f /etc/config/singbounds ] && rm -f /etc/config/singbounds
	sb_un_log 'uninstall: /etc/config/singbounds удалён'

	# --- 7. ответ → LuCI-кэш → rpcd reload (снимает ubus-объект) ---
	# ПОРЯДОК ВАЖЕН (фикс-раунд R1): JSON-ответ печатаем ПЕРВОЙ строкой
	# шага, фоновый субшелл rpcd reload — ПОСЛЕ неё. Пока reload
	# перезапускает объект-владелец, ответ уже допечатан в pipe и ушёл
	# вызывающему — гонки «reload раньше ответа» нет.
	sb_un_log 'uninstall: все шаги выполнены, sing-bounds удалён'

	printf '%s\n' '{"removed":true}'

	# LuCI-кэш меню: view-каталог удалён — без чистки индексов меню
	# может показывать снятую страницу до пересборки кэша.
	rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache 2>/dev/null
	# Субшелл перенаправляем ЦЕЛИКОМ (не команду внутри): иначе он
	# наследует stdout-pipe плагина и rpcd ждёт EOF,
	# задерживая доставку уже напечатанного ответа.
	( /etc/init.d/rpcd reload \
		|| sb_un_warn 'rpcd reload не сработал — ubus-объект исчезнет при следующем перезапуске rpcd') >/dev/null 2>&1 &

	return 0
}

# sb_un_log / sb_un_warn — лог uninstall-флоу: шаги по-русски в
# syslog + stderr вызывающего. sb_err не подходит: он пишет «backend:» и
# предназначен для отказов; здесь же — повествование шагов.
sb_un_log() {
	logger -t singbounds "uninstall: $*"
	printf 'uninstall: %s\n' "$*" >&2
}
sb_un_warn() {
	# Маркер «ПРЕДУПРЕЖДЕНИЕ:» отличает warn от обычного шага в
	# logread | grep singbounds (иначе строки неразличимы).
	logger -t singbounds "uninstall: ПРЕДУПРЕЖДЕНИЕ: $*"
	printf 'uninstall: ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2
}

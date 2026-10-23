# firewall.sh — sourcable-библиотека фаервола sing-bounds.
#
# НЕ ИСПОЛНЯЕТСЯ САМА: библиотека функций для source (rpcd-плагин,
# init-скрипт, uninstall). Вызов до source:
#   . /usr/lib/sing-bounds/firewall.sh
#   sb_fw_open 'sing-bounds-in-test' 4443
#   sb_fw_close 'sing-bounds-in-test'   # close НЕ нормализует имя: требуем префикс
#
# УРОВЕНЬ АБСТРАКЦИИ: только UCI/firewall4 (config firewall), НИКАКОГО
# сырого nft: firewall4 сам транслирует UCI-правила в nftables при reload.
# Прямой nft здесь сознательно не используется —
# правила обязаны переживать fw4 reload и reboot, т.е. жить в UCI.
#
# СХЕМА СОБСТВЕННОСТИ: владение живёт в ОПЦИИ
# `name` секции (`sing-bounds-<...>`), а НЕ в имени секции. Причины:
#   - libuci ОТКАЗЫВАЕТСЯ создавать именованную секцию с дефисом
#     (`uci set firewall.sing-bounds-x='rule'` → "Invalid argument"), а
#     файл, вручную содержащий `config rule 'sing-bounds-x'`, ломает ВСЁ
#     uci-обращение к конфигу ("Parse error (invalid character in name
#     field)"). Секция с дефисом в имени — вне контракта uci, точка.
#   - поэтому наши правила — АНОНИМНЫЕ секции (`uci add firewall rule`,
#     идентификатор `@rule[N]`), а маркер собственности — значение опции
#     `name`: `option name 'sing-bounds-in-<slug>'`. Именно так (add+set
#     name) реально создаются правила в /etc/config/firewall на OpenWrt.
#   - перебор своих секций: `uci -q show firewall | sed -n
#     "s/^firewall\.\([^.]*\)\.name='sing-bounds-...'$/\1/p"` — id секции
#     (@rule[N] или именованный) в uci delete безопасно передаётся в
#     кавычках: `uci delete "firewall.@rule[3]"`.
# Правила:
#   - sb_fw_open/close ожидают УЖЕ ПОЛНОЕ имя (значение опции name,
#     `sing-bounds-in-<slug>` из UCI-опции fw_rule). Если префикс
#     забыт — open добавляет его сам («нормализация»), чтобы вызов из
#     rpcd не мог случайно создать непомеченное правило;
#   - sb_fw_close ОТКАЗЫВАЕТСЯ удалять секцию, чьё имя не начинается с
#     `sing-bounds-` (guard rail: чужое не трогаем даже «по ошибке»);
#     нормализация имени — только в open, НЕ в close (асимметрия
#     осознана, см. комментарии у функций).
#
# КОДИРОВКА: ash/busybox, кириллица в логах; лог идёт в logger (syslog,
# logread на роутере) с тегом singbounds. При локальных тестах logger
# подменяется дублем (tests/test-firewall.sh), см. run-local.sh.
# ПРИМЕЧАНИЕ ДЛЯ rpcd-плагина: rpcd не должен дублировать
# этот лог в stderr — sb_fw_log уже пишет в stderr вызывающего (-s);
# второй слой даст двойные строки в journal/syslog.

# SB_FW_PREFIX — маркер собственности; трогаем только правила с ним
# в ОПЦИИ name.
SB_FW_PREFIX='sing-bounds-'

# sb_fw_log <msg> — единая точка логирования (syslog + stderr вызывающего).
sb_fw_log() {
	logger -t singbounds -s "firewall: $*"
}

# sb_fw_norm <name> -> echo полного имени правила с префиксом.
# На stdout: имя; вызывающий сохраняет в переменную. Пустое имя — пустой
# вывод + return 1 (не создаём безымянные правила).
# Используется только sb_fw_open (создание); close — наоборот строгий,
# см. комментарий там.
sb_fw_norm() {
	local n="${1:-}"
	case "$n" in
		"$SB_FW_PREFIX"*) printf '%s\n' "$n"; return 0 ;;
		'') return 1 ;;
		*) printf '%s%s\n' "$SB_FW_PREFIX" "$n"; return 0 ;;
	esac
}

# sb_fw_ids <name-регэксп> -> список id секций (stdout), у которых опция
# name совпадает с регэкспом. Реальный `uci -q show firewall` печатает для
# анонимной секции `firewall.@rule[N]=rule` и опции
# `firewall.@rule[N].name='...'`; sed выделяет id (часть между
# `firewall.` и `.name=`). Вызов с именем без метасимволов — точное
# совпадение; с 'sing-bounds-.*' — префиксный поиск (close_all).
sb_fw_ids() {
	uci -q show firewall | sed -n "s/^firewall\.\\([^.]*\\)\\.name='$1'\$/\\1/p"
}

# sb_fw_open <name> <port> — создать (или обновить) правило firewall.
# Идемпотентно: ПЕРВЫМ делом удаляем существующие секции с тем же
# name-значением (анонимные секции не уникальны — без этого повторный
# open плодил бы дубли), затем создаём свежую. Смена порта = пересоздание.
#   uci add firewall rule                 (анонимная секция; НЕТ дефисов
#                                         в имени секции — их у неё нет)
#   uci set firewall.@rule[-1].name='<full>'   (владение — в опции name)
#   uci set firewall.@rule[-1].src='wan' .dest_port=<port> .proto='tcp'
#       .target='ACCEPT'
# uci commit firewall; затем reload (см. sb_fw_reload ниже — почему).
# `uci add` ПЕЧАТАЕТ на stdout id новой секции (cfg...) — busybox-uci
# так сообщает о создании. Его глушим (>/dev/null, stderr сохраняем),
# чтобы вызывающие (rpcd-плагин), захватывающие stdout
# sb_fw_open, не получали мусор. Секция сразу становится последней —
# поэтому опции ставим через @rule[-1], безопасно сразу после add.
# Возвращает rc последней операции (0 — успех).
sb_fw_open() {
	local name port full sect
	name="${1:-}"
	port="${2:-}"

	full="$(sb_fw_norm "$name")" || {
		sb_fw_log "open: пустое имя правила — отказ"
		return 1
	}

	[ -n "$port" ] || {
		sb_fw_log "open: не задан порт для $full — отказ"
		return 1
	}

	# идемпотентность: убрать существующие правила с этим name-значением
	# (анонимные дубли от прошлых open не накапливаются). РЕНУМЕРОВКА:
	# @rule[N] пересчитывается после каждого delete — идём циклом
	# «первый найденный → delete → повторить», а не по списку id.
	while sect="$(sb_fw_ids "$full" | head -n 1)"; [ -n "$sect" ]; do
		uci delete "firewall.$sect" || {
			sb_fw_log "open: не могу удалить старую секцию firewall.$sect ($full)"
			return 1
		}
	done

	uci add firewall rule >/dev/null || {
		sb_fw_log "open: не могу добавить rule в firewall ($full)"
		return 1
	}

	# владение — опция name: firewall4 показывает её
	# в nft-комменте, uci show выводит читаемо, мы находим свои по ней.
	# src wan — правило «из интернета»; proto tcp — только VLESS/Reality.
	# КАВОТЧИВАНИЕ: значение передаётся uci без внутренних кавычек —
	# uci сам квотит при записи (одинарные кавычки в аргументе он
	# сохраняет ЛИТЕРАЛЬНО в значение — проверено на роутере).
	uci set "firewall.@rule[-1].name=$full" \
		&& uci set "firewall.@rule[-1].src=wan" \
		&& uci set "firewall.@rule[-1].dest_port=$port" \
		&& uci set "firewall.@rule[-1].proto=tcp" \
		&& uci set "firewall.@rule[-1].target=ACCEPT" || {
		sb_fw_log "open: не могу записать опции секции для $full (@rule[-1])"
		return 1
	}

	uci commit firewall || {
		sb_fw_log "open: uci commit firewall провалился ($full)"
		return 1
	}

	sb_fw_reload || return 1

	sb_fw_log "открыт порт $port/tcp (правило $full)"
	return 0
}

# sb_fw_close <name> — удалить наше правило (только если оно НАШЕ).
# В отличие от open (который ДОБАВИТ префикс), close НЕ нормализует имя,
# а ТРЕБУЕТ полное имя с префиксом и ОТКАЗЫВАЕТСЯ работать с любым другим
# (guard rail: «refuse to delete sections not starting with
# sing-bounds- even if asked»). Асимметрия осознана: open прощающий
# (всё созданное — наше, с префиксом), close строгий (не угадываем, что
# имел в виду вызывающий — чужое не трогаем даже при опечатке).
# Удаляем ВСЕ секции, чья опция name равна искомому (исторические дубли
# анонимных секций не копим).
sb_fw_close() {
	local name full sect removed
	name="${1:-}"
	full="$name"

	# GUARD: имя НЕ начинается с нашего префикса — отказ, чужое не трогаем.
	case "$full" in
		"$SB_FW_PREFIX"*) : ;;
		'')
			sb_fw_log "close: пустое имя правила — отказ"
			return 1
			;;
		*)
			sb_fw_log "close: правило '$full' не помечено '$SB_FW_PREFIX' — чужое, не трогаю"
			return 1
			;;
	esac

	# КРИТИЧНО (обнаружено на роутере): анонимные id @rule[N]
	# ПЕРЕНУМЕРОВЫВАЮТСЯ после каждого delete (@rule[14] → @rule[13]).
	# Поэтому нельзя перебирать заранее собранный список id и удалять по
	# нему — после первого delete остальные id устаревают. Вместо этого:
	# находим первый совпавший id, удаляем, ПОВТОРЯЕМ (пока grep что-то
	# находит). Каждая итерация видит свежую нумерацию.
	removed=0
	while sect="$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='$full'\$/\1/p" | head -n 1)"; [ -n "$sect" ]; do
		uci delete "firewall.$sect" || {
			sb_fw_log "close: не могу удалить firewall.$sect"
			return 1
		}
		removed=$((removed + 1))
	done

	if [ "$removed" = "0" ]; then
		sb_fw_log "close: правило $full не найдено (уже закрыто)"
		# Не ошибка: повторный close идемпотентен.
		return 0
	fi

	uci commit firewall || {
		sb_fw_log "close: uci commit firewall провалился ($full)"
		return 1
	}

	sb_fw_reload || return 1

	sb_fw_log "закрыт порт: удалено секций для $full: $removed"
	return 0
}

# sb_fw_close_all — удалить ВСЕ наши правила (name начинается с
# sing-bounds-). Чужие не трогаем. Возврат: количество удалённых секций
# (stdout) — uninstall может доложить в лог.
sb_fw_close_all() {
	local sect total fails
	total=0

	# Контроль собственности: удаляем только по ПРЕФИКСУ опции name.
	# Шаблон 'sing-bounds-.*' в sed: метасимволов в префиксе нет, `.*`
	# достраивает хвост.
	# РЕНУМЕРОВКА @rule[N] после каждого delete (см. комментарий в
	# sb_fw_close) — поэтому тоже цикл «найди первый, удали, повтори»,
	# а не перебор готового списка.
	# ЗАЩИТА ОТ ВЕЧНОГО ЦИКЛА: если delete
	# стабильно проваливается, тот же id найдётся снова — голый continue
	# крутился бы бесконечно. Даём до 3 попыток на секцию, потом — как
	# sb_fw_close — выходим с ошибкой (return 1).
	fails=0
	while sect="$(uci -q show firewall | sed -n "s/^firewall\.\([^.]*\)\.name='$SB_FW_PREFIX.*'\$/\1/p" | head -n 1)"; [ -n "$sect" ]; do
		uci delete "firewall.$sect" || {
			fails=$((fails + 1))
			sb_fw_log "close_all: не могу удалить firewall.$sect (попытка $fails из 3)"
			if [ "$fails" -ge 3 ]; then
				sb_fw_log "close_all: секция firewall.$sect не удаляется — прерываю"
				return 1
			fi
			continue
		}
		fails=0
		total=$((total + 1))
	done

	if [ "$total" -gt 0 ]; then
		uci commit firewall || {
			sb_fw_log "close_all: uci commit firewall провалился"
			return 1
		}
		sb_fw_reload || return 1
	fi

	sb_fw_log "close_all: удалено секций: $total"
	printf '%s\n' "$total"
	return 0
}

# sb_fw_reload — применить UCI-конфиг firewall к живому nftables.
# Порядок: /etc/init.d/firewall reload (принят на 24 и 25: init-скрипт
# firewall4 с start/reload входит в оба), fallback `fw4 reload` (используется
# самим init-скриптом firewall4) — если init-скрипт отсутствует/сломан.
# ЗАЧЕМ fallback: полный `firewall reload` пересобирает весь ruleset —
# безопасно, но <0.5 c. fw4 reload — то же самое напрямую.
sb_fw_reload() {
	if /etc/init.d/firewall reload >/dev/null 2>&1; then
		return 0
	fi
	sb_fw_log "init.d/firewall reload не сработал, пробую fw4 reload"
	fw4 reload >/dev/null 2>&1
}

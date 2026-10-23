# uci-cli.awk — awk-ядро ДУБЛЯ uci CLI для локальных тестов firewall.sh
# (настоящий uci есть только на OpenWrt).
#
# Вызывается из tests/lib/uci-cli.sh. Переменные:
#   cfg  — имя конфига (у нас всегда 'firewall');
#   mode — show | setsect | setopt | delsect | delopt | get | addanon;
#   sect — ИМЯ именованной секции ("" если цель анонимная);
#   atype — тип анонимной цели ('rule' и т.п.; "" если цель named);
#   anum — УЖЕ РЕЗОЛВЛЁННЫЙ индекс анонимной секции (обёртка uci-cli.sh
#     пересчитывает @type[N] и @type[-1] в фактический индекс по
#     анонимным секциям типа в порядке файла, как libuci; -1 = не задан);
#   opt, val — операнды команды.
# Вход: UCI-файл конфига (синтаксис /etc/config). Выход:
#   mode=show    — строки uci show: анонимные `cfg.@type[N]=<тип>` +
#                  `cfg.@type[N].<opt>='v'`, именованные `cfg.<name>=<тип>`
#                  + опции (как libuci: секции в порядке файла, опции тоже);
#   mode=get     — значение опции (stdout);
#   mode=addanon — новая анонимная секция в конце файла;
#   прочие       — ПЕРЕЗАПИСАННЫЙ конфиг-файл (обёртка кладёт его на место).
#
# Ограничения дубля (честно): uci state/rollback не эмулируется — commit
# это no-op (состояние сразу в файле); печатный id `cfg<цифры>` из
# `uci add` — косметика (firewall.sh после add пишет через @rule[-1]).

BEGIN { q = sprintf("%c", 39) }   # одинарная кавычка без экранирования

# --- заголовок секции: config <type> ['<name>'] ---
$1 == "config" {
	type = $2
	raw = $0
	sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", raw)
	sub(/[ \t]*$/, "", raw)
	name = ""
	if (length(raw) >= 2 && substr(raw, 1, 1) == q && substr(raw, length(raw), 1) == q)
		name = substr(raw, 2, length(raw) - 2)

	# нумерация АНОНИМНЫХ секций данного типа (как libuci: по порядку
	# файла, с нуля). Нужна и show, и сопоставлению цели anum.
	if (name == "")
		anoncnt[type]++

	# цель-секция: именованная (по имени) или анонимная (тип+индекс).
	is_target = 0
	if (name != "")
		is_target = (sect != "" && name == sect)
	else
		is_target = (atype != "" && type == atype && anoncnt[type] - 1 == anum)

	if (mode == "show") {
		if (name != "") {
			printf "%s.%s=%s\n", cfg, name, type
			cur = name
		} else {
			printf "%s.@%s[%d]=%s\n", cfg, type, anoncnt[type] - 1, type
			cur = sprintf("@%s[%d]", type, anoncnt[type] - 1)
		}
		next
	}

	# get: сканируем — опция напечатается в option-ветке
	if (mode == "get") {
		in_target = is_target
		next
	}

	# setopt: при выходе из целевой секции — дописать опцию, если не
	# заменили существующую (вставка ПЕРЕД следующим заголовком).
	if (mode == "setopt" && in_target && !replaced)
		printf "\toption %s %s%s%s\n", opt, q, val, q
	in_target = is_target

	# delsect: целевую секцию пропускаем целиком
	skip = (mode == "delsect" && is_target)

	if (mode == "setsect" && name == sect)
		found = 1

	if (!skip)
		print
	next
}

# --- строка опции: [tab]option <key> '<value>' ---
# ВАЖНО: строки опций в /etc/config-файлах свёрстаны табом, поэтому
# все regex-«якоря» обязаны допускать [ \t]* в начале строки.
$1 == "option" {
	if (mode == "show") {
		if (cur != "") {
			v = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", v)
			sub(/[ \t]*$/, "", v)
			if (length(v) >= 2 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q)
				v = substr(v, 2, length(v) - 2)
			printf "%s.%s.%s=%s%s%s\n", cfg, cur, $2, q, v, q
		}
		next
	}

	if (mode == "get") {
		if (in_target && $2 == opt) {
			v = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", v)
			sub(/[ \t]*$/, "", v)
			if (length(v) >= 2 && substr(v, 1, 1) == q && substr(v, length(v), 1) == q)
				v = substr(v, 2, length(v) - 2)
			print v
			exit
		}
		next
	}

	if (skip)
		next

	if (mode == "setopt" && in_target && $2 == opt) {
		printf "\toption %s %s%s%s\n", opt, q, val, q
		replaced = 1
		next
	}

	if (mode == "delopt" && in_target && $2 == opt)
		next

	print
	next
}

# --- прочие строки (пустые, комментарии): на месте ---
{
	if (mode == "show" || mode == "get")
		next
	if (!skip)
		print
}

END {
	# setopt: целевая секция — последняя в файле, опции нет — дописать.
	if (mode == "setopt" && in_target && !replaced)
		printf "\toption %s %s%s%s\n", opt, q, val, q

	# setsect: секции не было — создать в конце файла (как uci set).
	if (mode == "setsect" && !found)
		printf "\nconfig %s %s%s%s\n", val, q, sect, q

	# addanon: добавить АНОНИМНУЮ секцию в конец (как `uci add`).
	if (mode == "addanon")
		printf "\nconfig %s\n", val
}

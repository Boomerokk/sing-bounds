#!/bin/sh
# uci-cli.sh — ДУБЛЬ uci CLI для локальных тестов firewall.sh (тест).
#
# ЧЕСТНО О ЗАГЛУШКЕ: настоящего uci в WSL/Alpine нет; этот дубль —
# подмножество CLI поверх временного файла в НАСТОЯЩЕМ UCI-синтаксисе.
# Ядро — awk-программа tests/lib/uci-cli.awk. Контракт совпадает с
# libuci там, где это важно firewall.sh (fix round 1, review I1):
#   - uci add firewall rule              → создать АНОНИМНУЮ секцию,
#     печатает временный id `cfg<цифры>` (реальный uci печатает
#     подобный cfg-хвост; firewall.sh его не использует — после add
#     пишет через @rule[-1]);
#   - uci set firewall.<name>='rule'     → создать named-секцию; в ИМЕНИ
#     секции uci легальны только [A-Za-z0-9_]: дефис → "Invalid
#     argument" (как libuci, review C1);
#   - uci set|delete|get с @rule[N] и @rule[-1] (анонимные секции);
#     @rule[-1] резолвится в фактический индекс ПЕРЕСЧЁТОМ анонимных
#     rule-секций (как libuci делает внутри);
#   - uci set firewall.@rule[N].<opt>='v' → опция анонимной секции;
#   - uci show firewall → `firewall.@rule[N]=rule` +
#     `firewall.@rule[N].<opt>='v'` (анонимные, нумерация libuci) и
#     `firewall.<named>=<тип>` + опции (именованные);
#   - uci commit <cfg>  → no-op (файл уже актуален);
#   - uci -q            → тихий режим (флаг съедается).
# НЕ эмулирует: uci state/delta (libuci держит изменения в staged-файле
# до commit), многоконфигурность. Для контракта firewall.sh достаточно
# staged-commit-эквивалента: тест проверяет и файл, и show-вывод ПОСЛЕ
# commit — расхождений нет.
#
# Использование (только из тестовой песочницы):
#   UCI_FW_FILE=<файл конфига> uci show firewall
# Путь awk-программы: tests/lib/uci-cli.awk рядом (UCI_AWK переопределяется).

set -u

UCI_FW_FILE="${UCI_FW_FILE:?UCI_FW_FILE не задан}"
UCI_AWK="${UCI_AWK:-$(dirname "$0")/uci-cli.awk}"

# Счётчик анонимных добавлений (уникальность печатного id `cfg<цифры>`
# в рамках одного процесса; каждый вызов uci — отдельный процесс, но
# SeqFile позволяет различать подряд идущие add в одном тесте).
UCI_ANON_SEQ_FILE="${UCI_ANON_SEQ_FILE:-/tmp/sb-uci-anon.seq}"
UCI_ANON_SEQ=$(cat "$UCI_ANON_SEQ_FILE" 2>/dev/null || echo 0)
UCI_ANON_SEQ=$((UCI_ANON_SEQ + 1))
echo "$UCI_ANON_SEQ" > "$UCI_ANON_SEQ_FILE" 2>/dev/null \
	|| UCI_ANON_SEQ=1

[ $# -ge 1 ] || { echo "uci(дубль): нужен аргумент" >&2; exit 2; }

# -q (quiet) — проглатываем, на вывод не влияет
while [ "$1" = "-q" ]; do
	shift
done
[ $# -ge 1 ] || { echo "uci(дубль): нужен аргумент" >&2; exit 2; }

cmd="$1"; shift

# uci_name_ok <sect>: libuci допускает в ИМЕНИ секции только [A-Za-z0-9_]
# (дефис → "Invalid argument"; review C1). Анонимные id (@rule[N]) —
# отдельная грамматика, сюда не попадают.
uci_name_ok() {
	case "$1" in
		''|*[!A-Za-z0-9_]*) return 1 ;;
		*) return 0 ;;
	esac
}

# uci_anon_count <type>: сколько АНОНИМНЫХ секций данного типа в файле.
uci_anon_count() {
	awk -v t="$1" '
		$1 == "config" {
			raw = $0
			sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", raw)
			sub(/[ \t]*$/, "", raw)
			if (raw == "") cnt[$2]++
		}
		END { print cnt[t] + 0 }
	' "$UCI_FW_FILE"
}

# uci_resolve_anon <type> <num|'-1'>: резолв @type[-1] в фактический
# индекс (последняя анонимная секция типа). Печатает индекс; если секций
# нет — ничего и rc=1 (как uci "Entry not found").
uci_resolve_anon() {
	_type="$1"; _num="$2"
	_total="$(uci_anon_count "$_type")"
	if [ "$_num" = "-1" ]; then
		if [ "$_total" -eq 0 ]; then
			return 1
		fi
		echo $((_total - 1))
	else
		if [ "$_num" -ge "$_total" ]; then
			return 1
		fi
		echo "$_num"
	fi
}

# uci_parse_anon <id>: разобрать "@type[N]"/"@type[-1]" → echo "type N";
# не-анонимный id → rc=1.
uci_parse_anon() {
	case "$1" in
	@*\[*)
		_t="${1#@}"; _t="${_t%%\[*}"
		_n="${1#*\[}"; _n="${_n%\]}"
		echo "$_t $_n"
		return 0
		;;
	*) return 1 ;;
	esac
}

case "$cmd" in
show)
	cfg="$1"
	awk -v mode=show -v cfg="$cfg" -f "$UCI_AWK" "$UCI_FW_FILE"
	;;
commit)
	# no-op: дубль правит файл сразу (см. шапку)
	;;
get)
	# $1 = firewall.<sect|@rule[N]>.<opt>
	rest="${1#firewall.}"
	sect="${rest%%.*}"
	opt="${rest#*.}"
	if [ "$opt" = "$rest" ]; then
		echo "uci(дубль): get: нужен <секция>.<опция>: $1" >&2; exit 2
	fi
	if parsed="$(uci_parse_anon "$sect")"; then
		_type="${parsed%% *}"; _n="${parsed#* }"
		_idx="$(uci_resolve_anon "$_type" "$_n")" \
			|| { echo "Entry not found" >&2; exit 1; }
		awk -v mode=get -v cfg=firewall -v sect="" -v opt="$opt" \
			-v atype="$_type" -v anum="$_idx" \
			-f "$UCI_AWK" "$UCI_FW_FILE"
	else
		awk -v mode=get -v cfg=firewall -v sect="$sect" -v opt="$opt" \
			-v atype="" -v anum="-1" \
			-f "$UCI_AWK" "$UCI_FW_FILE"
	fi
	;;
add)
	# add <cfg> <type>: создать АНОНИМНУЮ секцию в конце. Печатает её
	# временный id `cfg<цифры>` (косметика: firewall.sh пишет через
	# @rule[-1]; id нужен только чтобы походить на реальный uci).
	cfg="$1"; type="$2"
	[ -n "$type" ] || { echo "uci(дубль): add: нужен тип" >&2; exit 2; }
	id="cfg$((10000 + UCI_ANON_SEQ))"
	awk -v mode=addanon -v cfg="$cfg" -v val="$type" \
		-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
		&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE" \
		|| exit 1
	echo "$id"
	;;
set)
	expr="$1"
	# Разбор «firewall.<sect|@rule[N]>.<opt>='val'» либо
	# «firewall.<sect>='type'». ОПАСНАЯ тонкость: имя секции может быть
	# БЕЗ точки-опции, а значение заключено в '...' и может само
	# содержать точки. Разбираем так: (1) срезаем cfg; (2) всё до '=' —
	# путь (секция или секция.опция); (3) всё после '=' — значение в
	# кавычках. Точка внутри 'val' не путается, т.к. значение мы уже
	# отделили по '='.
	rest="${expr#firewall.}"
	path="${rest%%=*}"        # <sect> | <sect>.<opt>
	val="${rest#*=}"
	val="${val%\'}"; val="${val#\'}"
	if [ "$val" = "$rest" ]; then
		echo "uci(дубль): set без '=': $expr" >&2; exit 2
	fi
	sect="${path%%.*}"
	tail="${path#*.}"
	if [ "$tail" = "$path" ]; then
		# firewall.<sect>='rule' — создать/проверить named-секцию.
		# Контракт libuci (review C1): дефис в имени секции — ошибка
		# "Invalid argument" (хендрафт 'sing-bounds-x' ломает весь файл).
		if ! uci_name_ok "$sect"; then
			echo "Invalid argument" >&2
			exit 1
		fi
		awk -v mode=setsect -v cfg=firewall -v sect="$sect" -v val="$val" \
			-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
			&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE"
	else
		# firewall.<sect|@rule[N]>.<opt>='val'
		opt="$tail"
		if parsed="$(uci_parse_anon "$sect")"; then
			_type="${parsed%% *}"; _n="${parsed#* }"
			_idx="$(uci_resolve_anon "$_type" "$_n")" \
				|| { echo "Entry not found" >&2; exit 1; }
			awk -v mode=setopt -v cfg=firewall -v sect="" -v opt="$opt" \
				-v val="$val" -v atype="$_type" -v anum="$_idx" \
				-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
				&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE" \
				|| exit 1
		else
			# опция именованной секции — имя тоже проверяем (как uci).
			if ! uci_name_ok "$sect"; then
				echo "Invalid argument" >&2
				exit 1
			fi
			awk -v mode=setopt -v cfg=firewall -v sect="$sect" -v opt="$opt" \
				-v val="$val" -v atype="" -v anum="-1" \
				-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
				&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE"
		fi
	fi
	;;
delete)
	expr="$1"
	# Разбор «firewall.<sect|@rule[N]>[.<opt>]» — значения нет.
	rest="${expr#firewall.}"
	sect="${rest%%.*}"
	tail="${rest#*.}"
	if parsed="$(uci_parse_anon "$sect")"; then
		_type="${parsed%% *}"; _n="${parsed#* }"
		_idx="$(uci_resolve_anon "$_type" "$_n")" \
			|| { echo "Entry not found" >&2; exit 1; }
		if [ "$tail" = "$rest" ]; then
			awk -v mode=delsect -v cfg=firewall -v sect="" \
				-v atype="$_type" -v anum="$_idx" \
				-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
				&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE"
		else
			awk -v mode=delopt -v cfg=firewall -v sect="" -v opt="$tail" \
				-v atype="$_type" -v anum="$_idx" \
				-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
				&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE"
		fi
	else
		# именованная секция: имя проверяем как uci (дефис — ошибка).
		if ! uci_name_ok "$sect"; then
			echo "Invalid argument" >&2
			exit 1
		fi
		if [ "$tail" = "$rest" ]; then
			awk -v mode=delsect -v cfg=firewall -v sect="$sect" \
				-v atype="" -v anum="-1" \
				-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
				&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE"
		else
			awk -v mode=delopt -v cfg=firewall -v sect="$sect" -v opt="${tail%%=*}" \
				-v atype="" -v anum="-1" \
				-f "$UCI_AWK" "$UCI_FW_FILE" > "$UCI_FW_FILE.new" \
				&& mv "$UCI_FW_FILE.new" "$UCI_FW_FILE"
		fi
	fi
	;;
*)
	echo "uci(дубль): команда '$cmd' не поддерживается" >&2
	exit 2
	;;
esac

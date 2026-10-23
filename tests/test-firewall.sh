#!/bin/sh
# test-firewall.sh — локальный тест firewall.sh (тест) в WSL/Alpine (правило).
#
# ЧЕСТНО О ЗАГЛУШКАХ (ни uci, ни firewall4, ни init-скрипта в Alpine нет):
#   1) `uci` — ДУБЛЬ tests/lib/uci-cli.sh (+ ядро tests/lib/uci-cli.awk):
#      подмножество CLI поверх временного файла В НАСТОЯЩЕМ UCI-синтаксисе,
#      контракт реального uci (fix round 1, review I1): анонимные секции
#      @rule[N]/@rule[-1] в set/delete/get/show, `uci add`, ОТКАЗ на дефис
#      в имени секции ("Invalid argument"). НЕ проверяет интеграцию с
#      libuci (state/delta, staged-commit) — это ROUTER PENDING.
#   2) `/etc/init.d/firewall` — ДУБЛЬ: reload пишет факт вызова в файл-
#      журнал. Библиотека зовёт его по АБСОЛЮТНОМУ пути, поэтому тест
#      гоняет sed-КОПИЮ firewall.sh с заменой пути (как init-dryrun.sh
#      поступает с init-скриптом). Оригинал не меняется.
#   3) `logger` — ДУБЛЬ: пишет в $WORK/syslog.log + stderr (как
#      tests/init-stubs.sh).
#   4) fw4 fallback не тестируется (no firewall4 в Alpine) — путь
#      /etc/init.d/firewall при отсутствии скрипта уйдёт в fw4-ветку,
#      здесь это недоступно; зафиксировано в task-5-report.md.
#
# Схема собственности (fix round 1, review C1): наши правила — АНОНИМНЫЕ
# секции `config rule`, владение — в ОПЦИИ name ('sing-bounds-<...>').
# Все проверки ниже ищут наши секции по ЗНАЧЕНИЮ опции name, а не по
# имени секции (review M4).
#
# Покрывает (Step 1 спецификация, локальная эмуляция):
#   A. open создаёт анонимное правило с ТОЧНЫМИ полями (name/src/
#      dest_port/proto/target), reload вызван, действие залогировано;
#   B. идемпотентность: double-open — без дублирования, смена порта
#      обновляет опцию (пересоздание секции);
#   C. close удаляет ТОЛЬКО наше правило;
#   D. close_all: все наши удалены, count правильный, чужое правило
#      accept_test (контрольное из спецификация) НЕ тронуто;
#   E. guard rails: close('accept_test') — отказ и правило живо;
#      close('')/open('', ...)/open без порта — отказы;
#   F. close несуществующей — идемпотентный rc=0;
#   G. нормализация имени в open (префикс sing-bounds- добавляется);
#   H. файл-конфиг и `uci show firewall` согласованы после операций;
#      наши секции видны как @rule[N] с опцией .name;
#   I. контракт дубля uci = реальный uci: дефис в имени секции — отказ;
#      @rule[N] в set/get/delete работает; add печатает id.
#
# Запуск: из tests/ (run-local.sh вызывает сам), root не нужен:
#   sh tests/test-firewall.sh

set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$REPO/tests"
WORK="$(mktemp -d /tmp/sb-fw.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM

FAIL=0
CHECKS=0
ok()   { CHECKS=$((CHECKS+1)); echo "ok $CHECKS $1"; }
fail() { CHECKS=$((CHECKS+1)); FAIL=$((FAIL+1)); echo "FAIL $CHECKS $1: ${2:-}"; }

# ---------------------------------------------------------------------
# Песочница: конфиг firewall с ЗАРАНЕЕ ПОЛОЖЕННЫМ чужим правилом
# accept_test (контрольное из спецификация) и парой чужих zone-секций.
# ---------------------------------------------------------------------
mkdir -p "$WORK/etc/config" "$WORK/bin" "$WORK/init.d"

FW="$WORK/etc/config/firewall"
cat > "$FW" <<'EOF'
config firewall

config zone
	option name 'lan'
	option input 'ACCEPT'

config zone
	option name 'wan'
	option input 'REJECT'

# чужое правило — контрольное из спецификация: НЕ sing-bounds-*. АНОНИМНОЕ —
# так в реальном /etc/config/firewall выглядят и наши, и «ручные»
# правила, созданные через `uci add firewall rule`: владение отличается
# только значением опции name (схема fix round 1, review C1).
config rule
	option name 'accept_test'
	option src 'wan'
	option dest_port '8080'
	option proto 'tcp'
	option target 'ACCEPT'
EOF

# --- uci-дубль (ядро в tests/lib) ---
cp "$TESTS/lib/uci-cli.sh" "$WORK/bin/uci"
chmod +x "$WORK/bin/uci"

# --- /etc/init.d/firewall — дубль: лог вызовов ---
RELOAD_LOG="$WORK/reload.log"
: > "$RELOAD_LOG"
cat > "$WORK/init.d/firewall" <<EOF
#!/bin/sh
# дубль /etc/init.d/firewall (reload) для локального теста
echo "\$*" >> "$RELOAD_LOG"
exit 0
EOF
chmod +x "$WORK/init.d/firewall"

# --- logger — дубль (паттерн init-stubs.sh): -t tag -s msg ---
SYSLOG_LOG="$WORK/syslog.log"
: > "$SYSLOG_LOG"

# --- копия firewall.sh с путями песочницы (оригинал не трогаем) ---
sed "s|/etc/init.d/firewall|$WORK/init.d/firewall|" \
	"$REPO/files/backend/firewall.sh" > "$WORK/firewall.sh"

# sh -n: синтаксис оригинала
if sh -n "$REPO/files/backend/firewall.sh" 2>/dev/null; then
	ok "sh -n firewall.sh (синтаксис POSIX sh)"
else
	fail "sh -n firewall.sh" "синтаксическая ошибка"
fi

# sb_run <функции>: дочерний sh, изолированное окружение. logger/export
# ДО source копии — библиотека подхватит их (PATH с uci-дублем).
sb_run() {
	sh -c '
		PATH="'"$WORK"'/bin:$PATH"
		UCI_FW_FILE="'"$FW"'"
		UCI_AWK="'"$TESTS"'/lib/uci-cli.awk"
		UCI_ANON_SEQ_FILE="'"$WORK"'/anon.seq"
		export PATH UCI_FW_FILE UCI_AWK UCI_ANON_SEQ_FILE
		logger() {
			tag=""; msg=""
			while [ $# -gt 0 ]; do
				case "$1" in
					-t) tag="$2"; shift 2 ;;
					-s) shift ;;
					*) msg="$1"; shift ;;
				esac
			done
			echo "singbounds: $msg" >> "'"$SYSLOG_LOG"'"
			return 0
		}
		. "'"$WORK"'/firewall.sh"
		'"$1"'
	'
}

# uci_run <args...>: прямой вызов дубля uci (проверки контракта I).
uci_run() {
	UCI_FW_FILE="$FW" UCI_AWK="$TESTS/lib/uci-cli.awk" \
		UCI_ANON_SEQ_FILE="$WORK/anon.seq" \
		"$WORK/bin/uci" "$@"
}

# --- помощники-читатели конфига (напрямую из файла, НЕ через дубль) ---
# review M4: наши правила — АНОНИМНЫЕ секции, владение в опции name.
# Все счётчики/читатели матчат по ЗНАЧЕНИЮ опции name, а не по имени
# секции. Ядро сканирования одно: awk разбирает секции и их опции.

# sb_scan <name> <opt|''>: печатает значение опции <opt> секции rule,
# у которой option name == <name>; при <opt>='' печатает '@' на каждую
# такую секцию (для подсчёта). (exit в awk НЕ отменяет END — guard done.)
sb_scan() {
	awk -v want="$1" -v opt="$2" '
		BEGIN { q = sprintf("%c", 39) }
		$1 == "config" {
			if (inrule && matched && opt == "") print "@"
			if (inrule && matched && opt != "" && cur != "" && !done) {
				print cur
				done = 1
			}
			raw = $0
			sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", raw)
			sub(/[ \t]*$/, "", raw)
			nm = (length(raw) >= 2 && substr(raw,1,1) == q \
				&& substr(raw,length(raw),1) == q) \
				? substr(raw, 2, length(raw)-2) : ""
			inrule = ($2 == "rule")
			matched = 0
			cur = ""
			next
		}
		inrule && $1 == "option" {
			v = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", v)
			sub(/[ \t]*$/, "", v)
			v = (length(v) >= 2) ? substr(v, 2, length(v)-2) : ""
			if ($2 == "name" && v == want) matched = 1
			if ($2 == opt) cur = v
			next
		}
		END {
			if (inrule && matched && opt == "") print "@"
			if (inrule && matched && opt != "" && cur != "" && !done) print cur
		}
	' "$FW"
}

# count_sections <name-значение>: сколько rule-секций с этой опцией name
# (review M4 — по опции, НЕ по имени секции).
count_sections() { sb_scan "$1" '' | grep -c '^@$' || true; }

# opt_of <name-значение> <opt>: значение опции нашего правила.
opt_of() { sb_scan "$1" "$2"; }

# count_rules: всего rule-секций (наши + чужие) — для guard-проверок.
count_rules() { grep -c '^config rule' "$FW" || true; }

# foreign_rule_alive: чужое контрольное accept_test живо (все поля).
# (В awk exit НЕ отменяет END-блок — глушим вывод флагом done.)
foreign_opt_of() {
	awk -v want="accept_test" -v opt="$1" '
		BEGIN { q = sprintf("%c", 39) }
		$1 == "config" {
			if (inrule && matched && cur != "" && !done) { print cur; done = 1; exit }
			raw = $0
			sub(/^[ \t]*config[ \t]+[^ \t]+[ \t]*/, "", raw)
			sub(/[ \t]*$/, "", raw)
			nm = (length(raw) >= 2 && substr(raw,1,1) == q \
				&& substr(raw,length(raw),1) == q) \
				? substr(raw, 2, length(raw)-2) : ""
			inrule = ($2 == "rule")
			matched = 0
			cur = ""
			next
		}
		inrule && $1 == "option" {
			v = $0
			sub(/^[ \t]*option[ \t]+[^ \t]+[ \t]*/, "", v)
			sub(/[ \t]*$/, "", v)
			v = (length(v) >= 2) ? substr(v, 2, length(v)-2) : ""
			if ($2 == "name" && v == want) matched = 1
			if ($2 == opt) cur = v
			next
		}
		END { if (inrule && matched && cur != "" && !done) print cur }
	' "$FW"
}
foreign_rule_alive() { [ "$(foreign_opt_of dest_port)" = "8080" ]; }

echo "== I. контракт дубля uci = реальный uci (review I1)"
# I1: дефис в имени секции — «Invalid argument» (как libuci, review C1)
rc=0; err=""
err="$(uci_run set "firewall.sing-bounds-x='rule'" 2>&1)" || rc=$?
if [ "$rc" != "0" ] && [ "$err" = "Invalid argument" ]; then
	ok "uci set firewall.sing-bounds-x: отказ «Invalid argument»"
else
	fail "uci set с дефисом" "rc=$rc err='$err'"
fi
# I2: add печатает id; set/get/delete через @rule[-1]/@rule[N] работают
addid="$(uci_run add firewall rule)"
[ -n "$addid" ] \
	&& ok "uci add печатает id ($addid)" || fail "uci add" "пустой id"
uci_run set "firewall.@rule[-1].name='sb_anon_probe'" \
	&& ok "uci set @rule[-1].name" || fail "uci set @rule[-1]" "rc!=0"
uci_run set "firewall.@rule[-1].dest_port='19999'" || fail "set @rule[-1].dest_port" "rc!=0"
[ "$(uci_run get "firewall.@rule[1].dest_port")" = "19999" ] \
	&& ok "uci get @rule[1].dest_port (после add — индекс 1)" \
	|| fail "uci get @rule[1]" "получено: '$(uci_run get "firewall.@rule[1].dest_port")'"
uci_run delete "firewall.@rule[1]" \
	&& ok "uci delete @rule[1]" || fail "uci delete @rule[1]" "rc!=0"
[ "$(count_rules)" = "1" ] \
	&& ok "после delete probe: снова 1 rule-секция (чужая)" \
	|| fail "probe cleanup" "count_rules=$(count_rules)"
# I3: показ анонимных: show печатает @rule[N]=rule + опции .name
show_probe="$(uci_run show firewall | grep "^firewall\.@rule\[0\]\.name='accept_test'$")"
[ -n "$show_probe" ] \
	&& ok "uci show: @rule[0].name='accept_test' (формат libuci)" \
	|| fail "uci show anon" "нет: '$show_probe'"

echo "== A. sb_fw_open: правило с точными полями"
sb_run "sb_fw_open 'sing-bounds-in-test' 4443" >/dev/null 2>&1
[ "$(count_sections sing-bounds-in-test)" = "1" ] \
	&& ok "open: создано ровно 1 правило name=sing-bounds-in-test" \
	|| fail "open: правило sing-bounds-in-test" "count=$(count_sections sing-bounds-in-test)"
[ "$(opt_of sing-bounds-in-test src)" = "wan" ] \
	&& ok "open: .src = wan" || fail "open: .src" "получено: '$(opt_of sing-bounds-in-test src)'"
[ "$(opt_of sing-bounds-in-test dest_port)" = "4443" ] \
	&& ok "open: .dest_port = 4443" \
	|| fail "open: .dest_port" "получено: '$(opt_of sing-bounds-in-test dest_port)'"
[ "$(opt_of sing-bounds-in-test proto)" = "tcp" ] \
	&& ok "open: .proto = tcp" || fail "open: .proto" "получено: '$(opt_of sing-bounds-in-test proto)'"
[ "$(opt_of sing-bounds-in-test target)" = "ACCEPT" ] \
	&& ok "open: .target = ACCEPT" \
	|| fail "open: .target" "получено: '$(opt_of sing-bounds-in-test target)'"
[ "$(wc -l < "$RELOAD_LOG")" -ge 1 ] \
	&& ok "open: firewall reload вызван" || fail "open: reload" "не вызван"
grep -q "открыт порт 4443/tcp" "$SYSLOG_LOG" \
	&& ok "open: действие залогировано (по-русски)" \
	|| fail "open: лог" "нет записи в syslog.log"
# наша секция — АНОНИМНАЯ (нет именованных 'sing-bounds-*' в файле)
if grep -q "^config rule 'sing-bounds" "$FW"; then
	fail "open: секция анонимна" "в файле именованная sing-bounds-секция"
else
	ok "open: секция анонимная (владение — в опции name, review C1)"
fi

echo "== B. идемпотентность open"
sb_run "sb_fw_open 'sing-bounds-in-test' 4443" >/dev/null 2>&1
[ "$(count_sections sing-bounds-in-test)" = "1" ] \
	&& ok "double-open: дублирования НЕТ (правило одно)" \
	|| fail "double-open: дубли" "count=$(count_sections sing-bounds-in-test)"
sb_run "sb_fw_open 'sing-bounds-in-test' 4444" >/dev/null 2>&1
[ "$(opt_of sing-bounds-in-test dest_port)" = "4444" ] \
	&& ok "open с другим портом: dest_port обновляется (пересоздание)" \
	|| fail "open: смена порта" "получено: '$(opt_of sing-bounds-in-test dest_port)'"
[ "$(count_sections sing-bounds-in-test)" = "1" ] \
	&& ok "смена порта: дубли НЕ плодятся" \
	|| fail "open: смена порта дубли" "count=$(count_sections sing-bounds-in-test)"

echo "== C. sb_fw_close: только наше правило"
sb_run "sb_fw_open 'sing-bounds-in-second' 4445" >/dev/null 2>&1
sb_run "sb_fw_close 'sing-bounds-in-test'" >/dev/null 2>&1
[ "$(count_sections sing-bounds-in-test)" = "0" ] \
	&& ok "close: наше правило удалено" \
	|| fail "close: наше правило" "count=$(count_sections sing-bounds-in-test)"
foreign_rule_alive \
	&& ok "close: чужое правило accept_test живо" || fail "close: чужое accept_test" "удалено"
[ "$(count_sections sing-bounds-in-second)" = "1" ] \
	&& ok "close: другое наше правило живо" || fail "close: другое наше" "удалено"

echo "== D. sb_fw_close_all: все наши, чужие не трогаем"
count=$(sb_run "sb_fw_close_all" 2>/dev/null | tail -n 1)
[ "$count" = "1" ] \
	&& ok "close_all: count=1 (наше осталось одно)" \
	|| fail "close_all: count" "получено: '$count'"
[ "$(count_sections sing-bounds-in-second)" = "0" ] \
	&& ok "close_all: наше правило удалено" || fail "close_all: наше правило" "осталось"
foreign_rule_alive \
	&& ok "close_all: чужое правило accept_test НЕ тронуто (контроль спецификация)" \
	|| fail "close_all: accept_test" "удалено"
[ "$(foreign_opt_of dest_port)" = "8080" ] \
	&& ok "close_all: поля чужого правила целы" \
	|| fail "close_all: поля accept_test" "изменены"

echo "== E. guard rails"
# E1: close на чужое имя — отказ, правило живо
rc=0
sb_run "sb_fw_close 'accept_test'" >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && foreign_rule_alive \
	&& ok "guard: close('accept_test') отказ, правило живо" \
	|| fail "guard: close чужого" "rc=$rc, alive=$(foreign_rule_alive && echo yes || echo no)"
grep -q "не помечено" "$SYSLOG_LOG" \
	&& ok "guard: отказ залогирован" || fail "guard: лог отказа" "нет записи"

# E2: close пустое имя — отказ
rc=0
sb_run "sb_fw_close ''" >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && ok "guard: close('') — отказ" || fail "guard: close('')" "rc=0"

# E3: open пустое имя — отказ, новых секций нет (осталась только accept_test)
rc=0
sb_run "sb_fw_open '' 4443" >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && [ "$(count_rules)" = "1" ] \
	&& ok "guard: open('', ...) — отказ, новых секций нет" \
	|| fail "guard: open('')" "rc=$rc, rules=$(count_rules)"

# E4: open без порта — отказ
rc=0
sb_run "sb_fw_open 'sing-bounds-in-x'" >/dev/null 2>&1 || rc=$?
[ "$rc" != "0" ] && [ "$(count_sections sing-bounds-in-x)" = "0" ] \
	&& ok "guard: open без порта — отказ" || fail "guard: open без порта" "rc=$rc"

echo "== F. close несуществующей — идемпотентный успех"
rc=0
sb_run "sb_fw_close 'sing-bounds-in-nosuch'" >/dev/null 2>&1 || rc=$?
[ "$rc" = "0" ] && ok "close несуществующей: rc=0" \
	|| fail "close несуществующей" "rc=$rc"

echo "== G. нормализация имени в open"
sb_run "sb_fw_open 'in-normalized' 4446" >/dev/null 2>&1
[ "$(count_sections sing-bounds-in-normalized)" = "1" ] \
	&& ok "open('in-normalized') → правило name=sing-bounds-in-normalized" \
	|| fail "open: нормализация" "count=$(count_sections sing-bounds-in-normalized)"
sb_run "sb_fw_close 'sing-bounds-in-normalized'" >/dev/null 2>&1

echo "== H. файл-конфиг согласован с uci show (дубль)"
show_out="$WORK/show.txt"
uci_run show firewall > "$show_out"
grep -q "^firewall.@rule\[0\]=rule$" "$show_out" \
	&& ok "uci show: чужая анонимная секция видна (@rule[0])" \
	|| fail "uci show: accept_test" "нет строки секции: $(grep '@rule' "$show_out" || echo нет)"
grep -q "^firewall.@rule\[0\].dest_port='8080'$" "$show_out" \
	&& ok "uci show: опции чужой секции целы" \
	|| fail "uci show: accept_test.dest_port" "нет/неверно"
if grep -q "sing-bounds" "$show_out"; then
	fail "uci show: наших правил не осталось" "что-то осталось: $(grep sing-bounds "$show_out")"
else
	ok "uci show: наших правил не осталось (чисто)"
fi

# --- ещё раз полный цикл через show (наши видны как @rule[N].name) ---
sb_run "sb_fw_open 'sing-bounds-in-showchk' 4447" >/dev/null 2>&1
uci_run show firewall > "$show_out"
grep -q "^firewall.@rule\[1\].name='sing-bounds-in-showchk'$" "$show_out" \
	&& ok "uci show: наше правило видно как @rule[1].name='sing-bounds-...'" \
	|| fail "uci show: наше правило" "$(grep sing-bounds "$show_out" || echo нет)"
grep -q "^firewall.@rule\[1\].dest_port='4447'$" "$show_out" \
	&& ok "uci show: .dest_port нашего правила" \
	|| fail "uci show: наше dest_port" "нет/неверно"
sb_run "sb_fw_close 'sing-bounds-in-showchk'" >/dev/null 2>&1

echo "---"
echo "$CHECKS checks, $FAIL failures"
if [ "$FAIL" = "0" ]; then
	echo "OK: локальные тесты firewall.sh пройдены"
	exit 0
fi
exit 1

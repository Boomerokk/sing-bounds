#!/bin/sh
# init-dryrun.sh — сухой прогон init-скрипта singbounds в WSL/Alpine (тест).
#
# Роутера нет (правило), procd и /etc/rc.common в Alpine отсутствуют.
# Поэтому прогоняется ЛОГИКА скрипта, а не procd-интеграция:
#   1) sh -n files/init.d/singbounds — синтаксис POSIX sh;
#   2) sourced-режим: stub-реализации procd_* / service_stop / rc.common-
#      окружение, затем вызываются start_service / restart /
#      status_service как функции и проверяется их поведение на дублях
#      (fake singbounds-ctl, fake sing-box check через PATH-обёртки);
#   3) пять сценариев (Steps 1-2 спецификация, локальная эмуляция):
#        A OK      — валидный рендер  -> config.json записан, инстанс создан,
#                    запущен fake-процесс «sing-box run»;
#        B ROLLBACK— битый ключ (render ок, check провал) -> restart
#                    отклонён, tmp удалён, config.json НЕ тронут (md5),
#                    инстанс НЕ создан, диагностика в логе, fake-процесс
#                    жив с тем же PID («старый конфиг продолжает работать»);
#        C EMPTY   — пустой UCI (ctl exit 1) -> та же rollback-ветка;
#        B2 START  — start при битом конфиге -> инстанс НЕ создан,
#                    exit != 0, диагностика в логе, config.json не тронут
#                    (ограничение: живой инстанс на реальном procd будет
#                    остановлен пустым set — см. шапку init-скрипта);
#        D REPAIR  — починка ключа -> restart успешен, новый инстанс.
#     Плюс статус-контракт status_service(): rc=0 при живом процессе,
#     rc=3 при остановленном (I1/M1, review R1).
#
# НА РОУТЕРЕ этот харнесс не нужен — там работает tests/router-rollback-test.sh.
#
# Запуск: из tests/, под root (нужен /etc/config для uci-заглушки):
#   sh tests/init-dryrun.sh
# (run-local.sh вызывает его сам в root-ветке.)

set -eu
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TESTS="$REPO/tests"
UCODE="${UCODE:-ucode}"

FAIL=0
CHECKS=0
ok()   { CHECKS=$((CHECKS+1)); echo "ok $CHECKS $1"; }
fail() { CHECKS=$((CHECKS+1)); FAIL=$((FAIL+1)); echo "FAIL $CHECKS $1: ${2:-}"; }

command -v "$UCODE" >/dev/null 2>&1 || { echo "ERROR: ucode не найден"; exit 2; }

WORK="$(mktemp -d /tmp/sb-init.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- подгоняем пути init-скрипта под песочницу через env-переопределение ---
# init-скрипт жёстко пиннит /etc/sing-bounds и /usr/bin — легально для
# роутера; для сухого прогона подменяем ДО source (скрипт объявляет их
# заново... поэтому вместо source редактируем копию: sed-заменяем пути
# на песочницу). Копия = только для теста, оригинал не меняется.
SB_DIR="$WORK/etc-sing-bounds"
CTL="$WORK/bin/singbounds-ctl"
mkdir -p "$SB_DIR" "$WORK/bin"

sed \
	-e "s|^SINGBOUNDS_DIR=.*|SINGBOUNDS_DIR=$SB_DIR|" \
	-e "s|^SINGBOUNDS_CTL=.*|SINGBOUNDS_CTL=$CTL|" \
	-e "s|^SINGBOX_BIN=.*|SINGBOX_BIN=$WORK/bin/sing-box|" \
	"$REPO/files/init.d/singbounds" > "$WORK/init-body.sh"

# Убираем shebang-строку с /etc/rc.common (её источник невозможен):
sed -i '1{/rc.common/d}' "$WORK/init-body.sh"

# --- 1. синтаксис ---
if sh -n "$REPO/files/init.d/singbounds" 2>/dev/null; then
	ok "sh -n init-скрипта"
else
	fail "sh -n init-скрипта" "синтаксическая ошибка"
fi

# --- 2. stub-окружение procd ---
. "$TESTS/init-stubs.sh"

# --- 3. дубль singbounds-ctl: вызывает НАСТОЯЩИЙ render.uc ---
# SINGBOUNDS_UCI_STUB (шаблон «каталог/*.uc»; «голый» каталог require()
# не сканирует): render.uc в WSL без настоящего uci.so берёт заглушку
# тестов по этому env. На роутере переменная не задаётся — берётся uci.so.
cat > "$CTL" <<EOF
#!/bin/sh
SINGBOUNDS_UCI_STUB="$TESTS/lib/*.uc" exec $UCODE "$REPO/files/backend/render.uc" "\$@"
EOF
chmod +x "$CTL"

# UCI-конфиг для render.uc (заглушка uci из run-local.sh уже создала
# /etc/config/singbounds к моменту вызова из run-local.sh; при автономном
# запуске создаём сами).
if [ ! -f /etc/config/singbounds ]; then
	cat > /etc/config/singbounds <<'EOF'
config global 'global'
	option webui_port '7789'
	option sni 'www.microsoft.com'

config inbound
	option id 'in1'
	option name 'in-1'
	option port '443'
	option vip '192.168.1.240'
	option private_key 'PRIVATE_KEY_1'
	option public_key 'PUBLIC_KEY_1'
	option short_id '0123456789abcdef'
	option fw_rule 'sing-bounds-in-in-1'

config client
	option id 'c1'
	option inbound 'in1'
	option name 'client1'
	option uuid '11111111-1111-1111-1111-111111111111'
EOF
fi

# --- 4. дубль sing-box: check/run ведут себя как настоящие (сценарии) ---
# $WORK/fake-check-rc: 0 = check проходит, 1 = провал.
echo 0 > "$WORK/fake-check-rc"
cat > "$WORK/bin/sing-box" <<EOF
#!/bin/sh
# дубль sing-box для сухого прогона
case "\$1" in
	check)
		rc=\$(cat "$WORK/fake-check-rc")
		[ "\$rc" = "0" ] || { echo "ERROR: invalid private_key in reality config" >&2; exit 1; }
		echo "configuration OK" >&2
		exit 0
		;;
	run)
		echo "fake sing-box run \$*" >> "$WORK/run.log"
		# «работающий процесс»: спим, пока нас не убьют
		while :; do sleep 1; done
		;;
	*)
		echo "unknown cmd" >&2; exit 2;;
esac
EOF
chmod +x "$WORK/bin/sing-box"

# ── СЦЕНАРИЙ A: нормальный старт (Step 2 спецификация) ──
. "$WORK/init-body.sh"

# stop/start: в rc.common их определяет САМ rc.common (функции поверх
# start_service/stop_service). В песочнице это делаем мы:
stop() { stop_service; }
start() { start_service; }

# запускаем команду инстанса в фоне и запоминаем PID
PROCD_RESET
if start_service; then ok "start_service: exit 0 (валидный конфиг)"; else fail "start_service: exit 0" "вернул != 0"; fi
PROCD_LAUNCH $(PROCD_COMMAND | tail -n 1) || true
[ -f "$SB_DIR/config.json" ] && ok "config.json создан" || fail "config.json создан" "нет файла"
[ -f "$SB_DIR/config.json.tmp" ] && fail "tmp удалён после успеха" "tmp остался" || ok "tmp удалён после успеха"
grep -q '"inbounds"' "$SB_DIR/config.json" 2>/dev/null && ok "config.json — JSON с inbounds" || fail "config.json — JSON с inbounds" "нет inbounds"
PROCD_INSTANCES 1 && ok "procd-инстанс создан (1)" || fail "procd-инстанс создан (1)" "инстансов: $(PROCD_COUNT)"
PROCD_RESPAWN && ok "respawn задан" || fail "respawn задан" "procd_set_param respawn не вызван"
PROCD_COMMAND | grep -q "run.*config.json" && ok "команда: sing-box run -c config.json" || fail "команда: sing-box run -c config.json" "$(PROCD_COMMAND)"

# config.json == CLI stdout (байт-в-байт, минус echo > file)
"$CTL" render > "$WORK/cli.json"
cmp -s "$WORK/cli.json" "$SB_DIR/config.json" && ok "config.json == singbounds-ctl render" || fail "config.json == singbounds-ctl render" "файлы различаются"

# ── СЦЕНАРИЙ B: rollback — битый inbound (Step 1 спецификация, локальная эмуляция) ──
# Сохраняем «старый рабочий» конфиг и PID работающего процесса.
OLD_CFG_MD5="$(md5sum "$SB_DIR/config.json" | cut -d' ' -f1)"
# I3 (review R1): host-UCI-конфиг бэкапим и восстанавливаем вокруг
# сценария B (тот же паттерн, что test-render-cli.uc) — BROKEN_KEY не
# должен протекать в /etc/config/singbounds при автономном запуске.
UCI_BAK_B="$WORK/uci.scenario-b.bak"
cp /etc/config/singbounds "$UCI_BAK_B"

# ломаем private_key в UCI: render ВАЛИДЕН (это просто строка), но check — нет.
# CLI uci в WSL/Alpine отсутствует — правим /etc/config/singbounds
# напрямую (sed); на роутере это делает router-rollback-test.sh через uci.
if command -v uci >/dev/null 2>&1; then
	# M2 (review R1): секция inbound в конфиге АНОНИМНАЯ (нет имени) —
	# адресуем по типу через @inbound[0], а не по несуществующему имени in1
	# (id 'in1' — это ucode-опция, не имя uci-секции).
	uci set singbounds.@inbound[0].private_key='BROKEN_KEY'
	uci commit singbounds
else
	sed -i "s|option private_key 'PRIVATE_KEY_1'|option private_key 'BROKEN_KEY'|" \
		/etc/config/singbounds
	grep -q "BROKEN_KEY" /etc/config/singbounds
fi
echo 1 > "$WORK/fake-check-rc"   # дубль sing-box check теперь проваливается

PROCD_RESET
if restart; then fail "restart: отклонён при битом конфиге" "restart вернул 0"; else ok "restart: отклонён при битом конфиге"; fi
[ -f "$SB_DIR/config.json.tmp" ] && fail "rollback: tmp удалён" "tmp остался" || ok "rollback: tmp удалён"
NEW_CFG_MD5="$(md5sum "$SB_DIR/config.json" 2>/dev/null | cut -d' ' -f1)"
[ "$OLD_CFG_MD5" = "$NEW_CFG_MD5" ] && ok "rollback: старый config.json не тронут" || fail "rollback: старый config.json не тронут" "конфиг изменился"
PROCD_INSTANCES 0 && ok "rollback: procd-инстанс не создан" || fail "rollback: procd-инстанс не создан" "инстансов: $(PROCD_COUNT)"
# Дублируем диагностический вывод и в procd-журнал: rc.common пишет
# stderr rc-команды в procd-лог; sb_log у нас logger-дубль пишет в
# syslog.log + stderr. Проверяем syslog.log (главный контракт: logread
# на роутере) И stderr-текст из самого вызова.
grep -q "sing-box check провалился" "$WORK/syslog.log" && ok "rollback: диагностика в логе (logger/syslog)" || fail "rollback: диагностика в логе (logger/syslog)" "нет diagnostic в syslog.log"

# «работающий процесс не тронут»: наш fake run из сценария A жив?
# (start_service в сценарии A породил fake sing-box через procd-стаб,
# который запускает команду в фоне.)
if [ -n "${FAKE_PID:-}" ] && kill -0 "$FAKE_PID" 2>/dev/null; then
	ok "rollback: процесс sing-box жив (тот же PID)"
else
	fail "rollback: процесс sing-box жив" "fake-процесс не найден/умер"
fi

# ── СЦЕНАРИЙ C: пустой UCI -> render exit 1, тоже rollback-ветка ──
mv /etc/config/singbounds "$WORK/uci.bak"
PROCD_RESET
if restart; then fail "restart: отклонён при пустом UCI" "restart вернул 0"; else ok "restart: отклонён при пустом UCI"; fi
grep -q "render провалился" "$WORK/syslog.log" && ok "пустой UCI: диагностика в логе" || fail "пустой UCI: диагностика в логе" "нет записи"
mv "$WORK/uci.bak" /etc/config/singbounds

# ── СЦЕНАРИЙ B2: start-путь с битым конфигом (I2, review R1) ──
# Гарантия отката (спецификация) держится на restart; start при битом конфиге
# обязан как минимум: (1) НЕ создавать инстанс, (2) вернуть != 0,
# (3) залогировать отказ, (4) не тронуть config.json. (То, что procd
# при пустом set всё же остановит работающий инстанс на реальном роутере,
# — известное ограничение, задокументировано в шапке init-скрипта.)
sed -i "s|option private_key 'PRIVATE_KEY_1'|option private_key 'BROKEN_KEY'|" \
	/etc/config/singbounds
echo 1 > "$WORK/fake-check-rc"
OLD_CFG_MD5_B2="$(md5sum "$SB_DIR/config.json" | cut -d' ' -f1)"
PROCD_RESET
if start_service; then fail "start_service: отклонён при битом конфиге" "вернул 0"; else ok "start_service: отклонён при битом конфиге"; fi
PROCD_INSTANCES 0 && ok "start при битом конфиге: инстанс НЕ создан" || fail "start при битом конфиге: инстанс НЕ создан" "инстансов: $(PROCD_COUNT)"
[ "$(md5sum "$SB_DIR/config.json" | cut -d' ' -f1)" = "$OLD_CFG_MD5_B2" ] \
	&& ok "start при битом конфиге: config.json не тронут" \
	|| fail "start при битом конфиге: config.json не тронут" "конфиг изменился"
grep -q "start отклонён" "$WORK/syslog.log" && ok "start при битом конфиге: диагностика в логе" || fail "start при битом конфиге: диагностика в логе" "нет записи"
# I3: возвращаем host-UCI в исходное состояние.
cp "$UCI_BAK_B" /etc/config/singbounds
rm -f "$UCI_BAK_B"

# ── СЦЕНАРИЙ D: восстановление после чинения (нормальный restart) ──
# I2: сценарий D должен ЗАПУСКАТЬ fake-процесс (как это делает реальный
# rc.common start -> rc_procd -> procd поднимает инстанс). До фикса
# restart оставлял FAKE_PID пустым после stop — статус «работает»
# не мог быть rc=0.
echo 0 > "$WORK/fake-check-rc"
PROCD_RESET
if restart; then ok "restart: exit 0 после чинения"; else fail "restart: exit 0 после чинения" "restart != 0"; fi
PROCD_INSTANCES 1 && ok "restart: новый инстанс создан" || fail "restart: новый инстанс создан" "инстансов: $(PROCD_COUNT)"
[ -f "$SB_DIR/config.json" ] && ok "restart: config.json на месте" || fail "restart: config.json на месте" "нет файла"
PROCD_LAUNCH $(PROCD_COMMAND | tail -n 1) || true

# --- status ---
# I1 (review R1): на реальном rc.common USE_PROCD сам регистрирует команду
# `status` и диспетчеризует её в status_service() (наш старый status()
# был мёртвым кодом — USE_PROCD-блок его переопределял). Тестируем
# функцию под её реальным именем.
# Контракт: 0 — работает, 3 — не запущен. В этом месте сценария D
# fake-процесс запущен -> ожидаем rc=0; после остановки -> rc=3.
# M1 (review R1): rc проверяется честно, а не «!= 1/2». `|| st_rc=$?`
# вместо `|| true`: без него под set -u/rc-subshell нельзя узнать rc.
st_rc=0
status_service >/dev/null 2>&1 || st_rc=$?
[ "$st_rc" = "0" ] && ok "status_service: rc=0 при работающем процессе" \
	|| fail "status_service: rc=0 при работающем" "rc=$st_rc"

# останавливаем процесс (штатный stop) и проверяем rc=3. Обёртка-
# функция: прямой `st_out=$(status_service) || st_rc=$?` тоже работает,
# но обёртка читабельнее и не зависит от тонкостей set -e в subshell.
st_out=''
st_rc=0
stop
status_service_out() { status_service; }
st_out=$(status_service_out) || st_rc=$?
[ "$st_rc" = "3" ] && [ -n "$st_out" ] \
	&& ok "status_service: rc=3 и вывод при остановленном процессе" \
	|| { fail "status_service: rc=3 при остановленном" "rc=$st_rc, вывод: $st_out"; true; }

echo "---"
echo "$CHECKS checks, $FAIL failures"
if [ "$FAIL" = "0" ]; then
	echo "OK: сухой прогон init-скрипта пройден"
	exit 0
fi
exit 1

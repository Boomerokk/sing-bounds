# init-stubs.sh — procd/rc.common-заглушки для init-dryrun.sh (тест).
# Source-ится, НЕ исполняется. Реализуют ровно тот API, который использует
# files/init.d/singbounds (по документации OpenWrt procd/rc.common):
#
#   procd_open_instance [name]  — начать описание инстанса;
#   procd_set_param command ... — команда инстанса;
#   procd_set_param respawn ... — параметры респауна;
#   procd_set_param stdout/stderr 1 — лог в procd;
#   procd_set_param file ...    — триггер-файл;
#   procd_close_instance        — закрыть описание;
#   service_stop               — хук остановки (дефолт procd);
#   logger                     — дубль (пишет в $WORK/syslog.log).
#
# Подменяемые глобали: WORK (каталог песочницы, задаёт init-dryrun.sh),
# PROCD_COUNT/PROCD_CMDS (счётчик инстансов/собранные параметры),
# FAKE_PID (PID фонового «sing-box run», чтобы сценарий rollback
# проверял живость), PROCD_LOG/SYSLOG_LOG (журналы песочницы).

# NB: variables shared with init-dryrun.sh
WORK="${WORK:?init-dryrun.sh должен задать WORK}"
PROCD_COUNT=0
PROCD_CMDS=''
PROCD_RESPAWN_SET=0
PROCD_OPEN=0
FAKE_PID=''
PROCD_LOG="$WORK/procd.log"
: > "$PROCD_LOG"
SYSLOG_LOG="$WORK/syslog.log"
: > "$SYSLOG_LOG"

PROCD_RESET() {
	PROCD_COUNT=0
	PROCD_CMDS=''
	PROCD_RESPAWN_SET=0
	PROCD_OPEN=0
}

PROCD_INSTANCES() {
	# $1 — ожидаемое число инстансов с прошлого RESET
	[ "$PROCD_COUNT" = "$1" ]
}

PROCD_COMMAND() {
	printf '%s\n' "$PROCD_CMDS"
}

PROCD_RESPAWN() {
	[ "$PROCD_RESPAWN_SET" = "1" ]
}

procd_open_instance() {
	PROCD_OPEN=1
	PROCD_COUNT=$((PROCD_COUNT+1))
	echo "procd_open_instance $*" >> "$PROCD_LOG"
}

procd_set_param() {
	echo "procd_set_param $*" >> "$PROCD_LOG"
	case "$1" in
		command) shift; PROCD_CMDS="$PROCD_CMDS
$*";;
		respawn) PROCD_RESPAWN_SET=1;;
	esac
}

procd_close_instance() {
	PROCD_OPEN=0
	echo "procd_close_instance" >> "$PROCD_LOG"
}

service_stop() {
	# Дефолтный procd-хук: убивает инстансы. В песочнице — fake-процесс.
	if [ -n "$FAKE_PID" ]; then
		kill "$FAKE_PID" 2>/dev/null || true
		wait "$FAKE_PID" 2>/dev/null || true
		FAKE_PID=''
	fi
}

logger() {
	# Дубль /bin/logger: -t tag -s msg...
	# Заглушка пишет всё в файл-журнал песочницы. Строку сообщения
	# берём КАК ЕСТЬ: rc.common вызывает `logger -t x -s "$msg"` одной
	# строкой-аргументом, поэтому склейка $* была бы избыточной.
	local tag='' msg='' sflag=0
	while [ $# -gt 0 ]; do
		case "$1" in
			-t) tag="$2"; shift 2;;
			-s) sflag=1; shift;;
			*) msg="$1"; shift;;
		esac
	done
	echo "$msg" >> "$SYSLOG_LOG"
	if [ "$sflag" = "1" ]; then
		echo "$msg" >&2
	fi
	return 0
}

# init-dryrun.sh после start_service хочет «работающий процесс» —
# запускаем команду инстанса в фоне и запоминаем PID. Вызывается
# харнессом ЯВНО (PROCD_LAUNCH), procd сам так не делает.
PROCD_LAUNCH() {
	# $@ — команда инстанса
	"$@" >> "$WORK/run.log" 2>&1 &
	FAKE_PID=$!
}

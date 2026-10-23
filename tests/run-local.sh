#!/bin/sh
# run-local.sh — локальный харнесс тестов тест/4/5 (без роутера, правило).
#
# Что делает: подкладывает uci-заглушку (tests/lib/uci.uc) вместо настоящего
# uci.so, которого нет в не-OpenWrt сборках ucode, и гоняет все тесты:
#   tests/test-config.uc    — golden renderConfig + allocateVip + nextFreePort (тест)
#   tests/test-loadstate.uc — loadState на синтетическом /etc/config/singbounds
#                             (требует прав на запись в /etc/config; запускается
#                             только если конфиг уже существует или мы root —
#                             иначе пропускается с пометкой; host-файл бэкапится
#                             и восстанавливается)
#   tests/test-links.uc     — urlencode + buildVlessLink: golden-ссылка и
#                             кириллица/emoji (тест)
#   tests/test-render-cli.uc — CLI render.uc: stdout == golden config-basic,
#                             exit-коды, контракт пустого состояния (тест)
#   tests/init-dryrun.sh    — сухой прогон init-скрипта с procd-заглушками:
#                             сценарии start/rollback/empty/repair (тест)
#   tests/test-firewall.sh  — firewall.sh с uci-CLI-заглушкой (тест):
#                             open/close/close_all, guard rails, чужое
#                             правило accept_test не трогается
# Golden-сравнение — истинное строковое равенство канонического %J-вида
# (golden-файлы хранятся в каноническом виде).
#
# Требования: любой ucode с модулем fs (проверено: Alpine 0.0.20250529-r0
# через `apk add ucode` в docker-desktop WSL; должен работать и на других
# Linux). На Windows запускать из WSL.
#
# Использование:
#   sh tests/run-local.sh          # из корня репозитория
#   UCODE=... sh tests/run-local.sh
#
# Проверенная среда (Windows):
#   wsl -d docker-desktop -u root -- sh -c "apk add --no-cache ucode && cd /mnt/host/c/<путь>/sing-bounds && sh tests/run-local.sh"
#
# НА РОУТЕРЕ (позже, правило) — настоящий uci, без заглушки:
#   scp files/backend/netbounds.uc root@$ROUTER:/usr/lib/sing-bounds/
#   scp -r tests root@$ROUTER:/tmp/sing-bounds-tests
#   ssh root@$ROUTER 'apk add --no-cache ucode-mod-uci ucode-mod-fs 2>/dev/null; \
#       cd /tmp/sing-bounds-tests/tests && ucode test-config.uc && ucode test-loadstate.uc'
#   # валидация сгенерированного конфига sing-box (Step 4 спецификация):
#   ssh root@$ROUTER 'ucode -e "
#       push(REQUIRE_SEARCH_PATH, \"/usr/lib/sing-bounds/*.uc\");
#       let nb = require(\"netbounds\");
#       let state = nb.loadState();
#       print(sprintf(\"%J\", nb.renderConfig(state, state.global)));
#     " | sing-box check -c /dev/stdin'
#   # (если модуль не резолвится по имени — запускать из каталога с -L, см. спецификация Step 2)

set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UCODE="${UCODE:-ucode}"

command -v "$UCODE" >/dev/null 2>&1 || {
	echo "ERROR: ucode не найден. Установите (Alpine: apk add ucode) или задайте UCODE=..." >&2
	echo "Проверено: wsl -d docker-desktop (Alpine) -> apk add ucode" >&2
	exit 2
}

cd "$REPO/tests"

# Заглушка uci резолвится по шаблону ./lib/*.uc (тест пушит его первым),
# netbounds — по ../files/backend/*.uc. На роутере с настоящим uci.so
# заглушка не нужна: у него приоритет в стандартном /usr/lib/ucode/*.so
# только если ./lib/*.uc не пушить — на роутере можно удалить tests/lib.
"$UCODE" test-config.uc

# loadState-тест требует синтетический /etc/config/singbounds.
# Готовим его, если мы root; иначе — пропускаем с пометкой.
# M-4 (review R1): существующий /etc/config/singbounds бэкапим и восстанавливаем
# после теста — хост-конфиг не должен изменяться/оставаться после прогона.
if [ "$(id -u)" = "0" ] && [ -d /etc/config ]; then
	UCI_FILE=/etc/config/singbounds
	UCI_BAK=
	if [ -e "$UCI_FILE" ]; then
		UCI_BAK="$(mktemp /etc/config/singbounds.bak.XXXXXX)"
		cp "$UCI_FILE" "$UCI_BAK"
	fi
	# Гарантированное восстановление даже при падении теста (set -eu).
	cleanup() {
		if [ -n "$UCI_BAK" ]; then
			mv "$UCI_BAK" "$UCI_FILE"
		else
			rm -f "$UCI_FILE"
		fi
	}
	trap cleanup EXIT INT TERM

	cat > "$UCI_FILE" <<'EOF'
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
	option stand_code 'a1b2c3d4e5f6'

config client
	option id 'c1'
	option inbound 'in1'
	option name 'Для Сергея'
	option uuid '11111111-1111-1111-1111-111111111111'

config client
	option id 'c2'
	option inbound 'in1'
	option name 'Для жены'
	option uuid '22222222-2222-2222-2222-222222222222'
EOF
	# ВАЖНО: заглушка в ./lib подменяет uci даже на системе с настоящим uci.so.
	# Поэтому loadState-тест здесь всегда идёт через заглушку — на роутере
	# он пойдёт через настоящий uci.so.
	"$UCODE" test-loadstate.uc

	# тест: CLI-рендер (render.uc как дочерний процесс ucode).
	# UCI-конфиг уже создан выше; тест сам бэкапит/восстанавливает его
	# для сценария «пустое состояние».
	"$UCODE" test-render-cli.uc

	# тест: сухой прогон init-скрипта (procd-заглушки, rollback-сценарии).
	# Нужен uci CLI для инъекции битого ключа — в Alpine/WSL нет /sbin/uci,
	# поэтому харнесс использует его только если есть, иначе правит файл
	# напрямую (внутри init-dryrun.sh).
	sh init-dryrun.sh

	# Восстановление host-конфига — cleanup() по trap EXIT (M-4).
	trap - EXIT INT TERM
	cleanup
else
	echo "SKIP: test-loadstate.uc (нужен root и /etc/config; на роутере — обязательно)"
fi

# тест: vless-ссылки — uci не нужен (структуры передаются явно),
# работает под любым пользователем.
"$UCODE" test-links.uc

# тест: фаервол-библиотека — uci-CLI-заглушка (tests/lib/uci-cli.sh),
# root не нужен (конфиг в temp-файле песочницы).
sh test-firewall.sh

echo "OK: локальные тесты тест+3+4+5 пройдены"

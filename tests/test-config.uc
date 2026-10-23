// test-config.uc — golden-тесты netbounds.uc (тест).
//
// Запуск на роутере (правило: отложено, см. tests/run-local.sh):
//   scp files/backend/netbounds.uc tests/test-config.uc tests/golden/*.json root@$ROUTER:/tmp/
//   ssh root@$ROUTER 'cd /tmp && ucode test-config.uc'
//
// Локально (любой ucode с модулем fs): см. tests/run-local.sh.
//
// Формат имени модуля: спецификация пиннит require("netbounds.uc"). В ucode require()
// ищет имя с заменой '.' на '/' в путях из REQUIRE_SEARCH_PATH, поэтому имя
// "netbounds.uc" фактически не резолвится в файл netbounds.uc. Ниже модуль
// ищется под обоими именами ('netbounds' — фактическое, 'netbounds.uc' —
// спецификация), с шаблонами, покрывающими локальный запуск и роутер.

'use strict';

import { readfile } from 'fs';

// --- подключение netbounds.uc (несколько стратегий, один результат) ---
// ВАЖНО: uci-заглушка (tests/lib/uci.uc) пушится ПЕРВОЙ: если настоящий
// uci.so не собран (не-OpenWrt сборка ucode), require('uci') внутри
// netbounds.uc найдёт заглушку. На роутере настоящий uci.so стоит раньше
// в стандартном пути — заглушка не мешает.
let nb = null;
let candidates = [ 'netbounds', 'netbounds.uc' ];
let patterns = [
	'./lib/*.uc',            // uci-заглушка (локально)
	'./netbounds.uc',        // файл рядом с тестом (на роутере, /tmp)
	'files/backend/*.uc',    // запуск из корня репозитория
	'../files/backend/*.uc', // запуск из tests/
	'/usr/lib/sing-bounds/*.uc', // установка на роутере
	'/opt/sing-bounds/backend/*.uc',
];

for (let p in patterns)
	push(REQUIRE_SEARCH_PATH, p);

for (let c in candidates) {
	try {
		let m = require(c);
		if (m && type(m.renderConfig) == 'function') {
			nb = m;
			break;
		}
	} catch (e) { /* пробуем следующий вариант */ }
}

if (!nb)
	die('FAIL: netbounds.uc не найден/не загружен (require)\n');

// --- мини-фреймворк ---
let failures = 0;
let checks = 0;

function check(name, ok, detail) {
	checks++;
	if (ok) {
		printf('ok %d %s\n', checks, name);
	} else {
		failures++;
		printf('FAIL %d %s: %s\n', checks, name, detail ?? '(нет деталей)');
	}
}

function goldenCompare(name, rendered, goldenPath) {
	// rendered — уже object (вывод renderConfig); golden — канонический JSON-текст.
	// Истинное строковое равенство (спецификация Step 1): канонический %J-вид рендера
	// обязан совпадать с golden-файлом байт-в-байт. Golden-файлы хранятся
	// ровно в каноническом %J-виде (одна строка, без завершающего \n).
	let got = sprintf('%J', rendered);
	let want = trim(readfile(goldenPath) ?? '');

	if (want == '')
		die('FAIL: golden-файл не найден: ' + goldenPath + '\n');

	check(name + ' (строковое равенство)', got == want,
		sprintf('got: %.200s...', got));
}

// --- golden-состояние №1: 1 инбаунд «Для Сергея», порт 443, vip 192.168.1.240, 2 клиента ---
let global1 = {
	webui_port: 7789,
	sni: 'www.microsoft.com'
};

let state1 = {
	global: { webui_port: 7789, sni: 'www.microsoft.com' },
	inbounds: [
		{
			id: 'in1',
			name: 'in-1',
			port: 443,
			vip: '192.168.1.240',
			private_key: 'PRIVATE_KEY_1',
			public_key: 'PUBLIC_KEY_1',
			short_id: '0123456789abcdef',
			fw_rule: 'sing-bounds-in-in-1',
			clients: [
				{ id: 'c1', inbound: 'in1', name: 'Для Сергея', uuid: '11111111-1111-1111-1111-111111111111' },
				{ id: 'c2', inbound: 'in1', name: 'Для жены', uuid: '22222222-2222-2222-2222-222222222222' }
			]
		}
	]
};

let cfg1 = nb.renderConfig(state1, global1);
goldenCompare('renderConfig basic', cfg1, 'golden/config-basic.json');

// --- golden-состояние №2: 2 инбаунда ---
let state2 = {
	global: { webui_port: 7789, sni: 'www.microsoft.com' },
	inbounds: [
		state1.inbounds[0],
		{
			id: 'in2',
			name: 'in-2',
			port: 8443,
			vip: '192.168.1.241',
			private_key: 'PRIVATE_KEY_2',
			public_key: 'PUBLIC_KEY_2',
			short_id: 'fedcba9876543210',
			fw_rule: 'sing-bounds-in-in-2',
			clients: [
				{ id: 'c3', inbound: 'in2', name: 'YouTube-only', uuid: '33333333-3333-3333-3333-333333333333' }
			]
		}
	]
};

let cfg2 = nb.renderConfig(state2, global1);
goldenCompare('renderConfig two inbounds', cfg2, 'golden/config-two.json');

// --- базовые инварианты формата sing-box 1.12 ---
check('log.level == warn', cfg1.log.level == 'warn', sprintf('%J', cfg1.log));
check('routing_mark == 23309 (0x5b0d)', cfg1.outbounds[0].routing_mark == 23309,
	sprintf('%J', cfg1.outbounds[0]));
check('route.final == direct', cfg1.route.final == 'direct', sprintf('%J', cfg1.route));
check('listen == 0.0.0.0', cfg1.inbounds[0].listen == '0.0.0.0',
	sprintf('%s', cfg1.inbounds[0].listen));
check('tls.reality.handshake.server_port == 443',
	cfg1.inbounds[0].tls.reality.handshake.server_port == 443,
	sprintf('%J', cfg1.inbounds[0].tls.reality.handshake));
check('users без flow (Vision задаётся клиентом)',
	!exists(cfg1.inbounds[0].users[0], 'flow'),
	sprintf('%J', cfg1.inbounds[0].users[0]));
check('short_id — массив с одним sid',
	type(cfg1.inbounds[0].tls.reality.short_id) == 'array' &&
	length(cfg1.inbounds[0].tls.reality.short_id) == 1,
	sprintf('%J', cfg1.inbounds[0].tls.reality.short_id));

// --- allocateVip: /24 стандартная ---
check('allocateVip 192.168.1.0/24', nb.allocateVip('192.168.1.0/24', []) == '192.168.1.240',
	nb.allocateVip('192.168.1.0/24', []));
// Review Focus #2: нестандартные подсети
check('allocateVip 10.5.0.0/24 → 10.5.0.240',
	nb.allocateVip('10.5.0.0/24', []) == '10.5.0.240',
	nb.allocateVip('10.5.0.0/24', []));
check('allocateVip 172.16.0.0/16 → 172.16.0.240',
	nb.allocateVip('172.16.0.0/16', []) == '172.16.0.240',
	nb.allocateVip('172.16.0.0/16', []));
// пропуск занятых
check('allocateVip skip taken .240',
	nb.allocateVip('192.168.1.0/24', [ '192.168.1.240' ]) == '192.168.1.241',
	nb.allocateVip('192.168.1.0/24', [ '192.168.1.240' ]));
check('allocateVip skip .240+.241',
	nb.allocateVip('192.168.1.0/24', [ '192.168.1.240', '192.168.1.241' ]) == '192.168.1.242',
	nb.allocateVip('192.168.1.0/24', [ '192.168.1.240', '192.168.1.241' ]));
// диапазон до .250 включительно
let takenFull = [];
for (let i = 240; i <= 250; i++)
		push(takenFull, sprintf('192.168.1.%d', i));
check('allocateVip диапазон исчерпан → null', nb.allocateVip('192.168.1.0/24', takenFull) == null,
	sprintf('%J', nb.allocateVip('192.168.1.0/24', takenFull)));
check('allocateVip .250 — последний валидный',
	nb.allocateVip('192.168.1.0/24', [ '192.168.1.240', '192.168.1.241', '192.168.1.242', '192.168.1.243', '192.168.1.244', '192.168.1.245', '192.168.1.246', '192.168.1.247', '192.168.1.248', '192.168.1.249' ]) == '192.168.1.250',
	'последний свободный в диапазоне');
// невалидный вход
check('allocateVip мусорный CIDR → null', nb.allocateVip('не-ip', []) == null, 'мусор');
check('allocateVip без /prefix → null', nb.allocateVip('192.168.1.1', []) == null, 'нет префикса');
// M-1 (review R1): /25-/30 отклоняются — .240 вышел бы за пределы подсети
check('allocateVip /25 → null (guard)', nb.allocateVip('192.168.1.0/25', []) == null,
	sprintf('%J', nb.allocateVip('192.168.1.0/25', [])));
check('allocateVip /30 → null (guard)', nb.allocateVip('192.168.1.0/30', []) == null,
	sprintf('%J', nb.allocateVip('192.168.1.0/30', [])));

// --- nextFreePort ---
check('nextFreePort пусто → 443', nb.nextFreePort([]) == 443, sprintf('%d', nb.nextFreePort([])));
check('nextFreePort 443 занят → 444', nb.nextFreePort([ 443 ]) == 444,
	sprintf('%d', nb.nextFreePort([ 443 ])));
check('nextFreePort 443+444 → 445', nb.nextFreePort([ 443, 444 ]) == 445, '445');
check('nextFreePort пропуск дыр', nb.nextFreePort([ 10000, 443 ]) == 444, 'дырка не мешает');
check('nextFreePort start=8443', nb.nextFreePort([ 443 ], 8443) == 8443, 'кастомный старт');
check('nextFreePort строки-порты', nb.nextFreePort([ '443' ]) == 444, 'строки как taken');

// --- loadState: только наличие и сигнатура (реальное чтение UCI — на роутере) ---
check('loadState — функция', type(nb.loadState) == 'function', 'typeof');
// На роутере с /etc/config/singbounds тест расширяется (см. run-local.sh):
// наличие секций global/inbound/client и defaults при отсутствии конфига.
// Ошибку loadState НЕ глотаем молча — фиксируем явный FAIL.
let ls = null;
let lsErr = null;
try { ls = nb.loadState(); } catch (e) { lsErr = e; }
if (lsErr != null) {
	check('loadState не бросает исключение', false, sprintf('%J', lsErr));
} else if (ls != null) {
	check('loadState возвращает object', type(ls) == 'object', type(ls));
	check('loadState.global есть', exists(ls, 'global'), sprintf('%J', keys(ls)));
	check('loadState.inbounds есть', exists(ls, 'inbounds'), sprintf('%J', keys(ls)));
}

// --- итог ---
printf('---\n%d checks, %d failures\n', checks, failures);
exit(failures > 0 ? 1 : 0);

// test-links.uc — тесты vless-ссылок (тест: urlencode + buildVlessLink).
//
// Запуск на роутере (правило: локально — см. tests/run-local.sh):
//   ucode test-links.uc   (из каталога tests/)
//
// Проверяет:
//   - buildVlessLink: точный формат ссылки (golden-файл, байт-в-байт)
//   - urlencode: encodeURIComponent-совместимость (RFC 3986 unreserved,
//     пробел → %20, кириллица/emoji → UTF-8 percent-encoding, верхний hex)

'use strict';

import { readfile } from 'fs';

// --- подключение netbounds.uc (тот же рецепт, что в test-config.uc) ---
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
		if (m && type(m.buildVlessLink) == 'function') {
			nb = m;
			break;
		}
	} catch (e) { /* пробуем следующий вариант */ }
}

if (!nb)
	die('FAIL: netbounds.uc не найден/не загружен (require)\n');

// --- мини-фреймворк (как в test-config.uc) ---
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

// --- состояние из golden (те же значения, что config-basic) ---
let inbound1 = {
	id: 'in1',
	name: 'in-1',
	port: 443,
	vip: '192.168.1.240',
	private_key: 'PRIVATE_KEY_1',
	public_key: 'PUBLIC_KEY_1',
	short_id: '0123456789abcdef',
	fw_rule: 'sing-bounds-in-in-1',
	clients: []
};

let client1 = {
	id: 'c1',
	inbound: 'in1',
	name: 'Для Сергея',
	uuid: '11111111-1111-1111-1111-111111111111'
};

let global1 = {
	webui_port: 7789,
	sni: 'www.microsoft.com'
};

// --- Step 1 спецификация: golden-сравнение полной ссылки ---
let link1 = nb.buildVlessLink(inbound1, client1, global1, '77.88.8.8');
// M1 (review R2): trim() срезает все whitespace и не байт-строг;
// rtrim с cutset срезает ровно завершающий '\n' (ucode 0.0.20250529
// поддерживает rtrim(str, cutset) — проверено прогоном).
let want1 = rtrim(readfile('golden/link-basic.txt') ?? '', '\n');
if (want1 == '')
	die('FAIL: golden-файл не найден: golden/link-basic.txt\n');

check('buildVlessLink basic (строковое равенство)', link1 == want1,
	sprintf('got: %s', link1));

// Случай «Жена 📺» (Review Focus #4): fragment — точный urlencode.
let clientWife = {
	id: 'c2',
	inbound: 'in1',
	name: 'Жена 📺',
	uuid: '22222222-2222-2222-2222-222222222222'
};
let linkWife = nb.buildVlessLink(inbound1, clientWife, global1, '77.88.8.8');
let wantFragment = '%D0%96%D0%B5%D0%BD%D0%B0%20%F0%9F%93%BA';
let gotFragment = split(linkWife, '#')?.[1] ?? '';
check('buildVlessLink «Жена 📺» fragment', gotFragment == wantFragment,
	sprintf('got: %s', gotFragment));

// --- urlencode: покрытие contract-а ---
// unreserved [A-Za-z0-9-_.!~*'()] не экранируются
check('urlencode ASCII unreserved', nb.urlencode("A-z09-_.!~*'()") == "A-z09-_.!~*'()",
	sprintf('got: %s', nb.urlencode("A-z09-_.!~*'()")));
// пробел → %20 (НЕ '+')
check('urlencode пробел → %20', nb.urlencode('a b') == 'a%20b',
	sprintf('got: %s', nb.urlencode('a b')));
// кириллица → UTF-8 percent-encoding, верхний hex
check('urlencode «Жена»', nb.urlencode('Жена') == '%D0%96%D0%B5%D0%BD%D0%B0',
	sprintf('got: %s', nb.urlencode('Жена')));
// emoji → 4-байтный UTF-8
check('urlencode 📺', nb.urlencode('📺') == '%F0%9F%93%BA',
	sprintf('got: %s', nb.urlencode('📺')));
// резервированные символы экранируются
check('urlencode reserved', nb.urlencode('a/b?c#d=e&f:g') == 'a%2Fb%3Fc%23d%3De%26f%3Ag',
	sprintf('got: %s', nb.urlencode('a/b?c#d=e&f:g')));
// пустая строка
check('urlencode пусто', nb.urlencode('') == '', 'пустая строка');

// --- формат ссылки: инварианты (port из inbound, все параметры на месте) ---
let link2 = nb.buildVlessLink(
	{ port: 8443, public_key: 'PBK2', short_id: 'sid2' },
	{ uuid: '33333333-3333-3333-3333-333333333333', name: 'YouTube-only' },
	{ sni: 'example.org' },
	'1.2.3.4'
);
check('buildVlessLink порт из inbound',
	match(link2, /:8443\?/) != null, sprintf('got: %s', link2));
// C1 (review R2): ucode не имеет оператора `=~` — прежняя запись
// `(link2 =~ /re/)` парсилась как присваивание, а `!= null` было всегда
// истинно (чек был вакуумным). Правильная форма — match(). Пиннинг
// ожидания `#YouTube-only`: дефис unreserved (чек #3), `urlencode` его
// не экранирует.
check('buildVlessLink все параметры на месте',
	match(link2, /^vless:\/\/33333333-3333-3333-3333-333333333333@1\.2\.3\.4:8443\?encryption=none&security=reality&pbk=PBK2&fp=chrome&sid=sid2&sni=example\.org&type=tcp&flow=xtls-rprx-vision#YouTube-only$/) != null,
	sprintf('got: %s', link2));

// --- итог ---
printf('---\n%d checks, %d failures\n', checks, failures);
exit(failures > 0 ? 1 : 0);

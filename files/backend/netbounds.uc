// netbounds.uc — ucode-модуль sing-bounds: состояние UCI + генератор конфига sing-box.
//
// Подключение (на роутере файл установлен в /usr/lib/sing-bounds/):
//   push(REQUIRE_SEARCH_PATH, '/usr/lib/sing-bounds/*.uc');
//   let nb = require('netbounds');
// Имя модуля — 'netbounds' (БЕЗ '.uc'): ucode при поиске заменяет '.' на '/'
// в имени модуля, поэтому require('netbounds.uc') не резолвится в этот файл
// («No module named»; ucode 0.0.20250529).
// Модуль возвращает эти функции через top-level return,
// поэтому require() (а не import) — единственный правильный способ загрузки.
//
// Экспортирует:
//   loadState()                      -> { global: {...}, inbounds: [{... clients: []}] }
//   renderConfig(state, global)      -> sing-box 1.12 JSON (object)
//   allocateVip(lanCidr, taken[])    -> string|null
//   nextFreePort(taken[], start=443) -> int
//   urlencode(str)                   -> string (encodeURIComponent-совместимый)
//   buildVlessLink(inbound, client, global, host) -> string
// stand_code в loadState: у инбаундов без опции — null.
// Семантика enabled/sni (обратная совместимость со старыми конфигами):
//   loadState читает inbound.enabled (default true), inbound.sni
//   (default null = брать global.sni), client.enabled (default true);
//   renderConfig пропускает disabled-инбаунды и их клиентов (данные
//   в UCI сохраняются — выключенное НЕ удаляется); sni инбаунда =
//   inbound.sni ?? global.sni. buildVlessLink: sni = inbound.sni ??
//   global.sni.
// Ключи Reality/UUID НЕ генерирует (для этого есть sing-box generate).

'use strict';

// Модуль грузится через require(), а require() компилирует файл в script-режиме,
// где статический import НЕ резолвится по поисковому пути (это ограничение ucode).
// Поэтому uci берём динамически require()-ом.
// На роутере uci.so лежит в /usr/lib/ucode/ (стандартный путь), локально тесты
// подкладывают заглушку tests/lib/uci.uc раньше — оба варианта работают.
const uci = require('uci');

// --- константы ---
const ROUTING_MARK = 23309;          // 0x5b0d — марка трафика sing-box
const VIP_RANGE_START = 240;         // последний октет: .240 ...
const VIP_RANGE_END = 250;           // ... до .250 включительно
const DEFAULT_WEBUI_PORT = 7789;
// Дефолтный SNI/хендшейк-таргет Reality. НЕ www.microsoft.com: Akamai
// шлёт в ServerHello расширение supported_groups, на котором Reality
// sing-box ломается — «processed invalid connection»
// (github.com/SagerNet/sing-box issue #4290).
// Cloudflare ServerHello чист.
const DEFAULT_SNI = 'www.cloudflare.com';
const UCI_CONFIG = 'singbounds';     // /etc/config/singbounds
const REALITY_HANDSHAKE_PORT = 443;

// Схема UCI (stand_code — код стенд-страницы):
//   config global 'global'
//       option webui_port '7789'
//       option sni 'www.cloudflare.com'
//   config inbound
//       option id, name, port, vip, private_key, public_key, short_id,
//              fw_rule, stand_code (12 [a-z0-9], код /stand/<code>/)
//       option enabled '1'  ('1'|'0', отсутствие = '1')
//       option sni '…'      (отсутствие = null → берётся global.sni;
//                            у созданных через WebUI — фиксируется на
//                            момент создания, global-смена не перетирает)
//   config client
//       option id, inbound, name, uuid
//       option enabled '1'  ('1'|'0', отсутствие = '1')

function loadState() {
	let ctx = uci.cursor();
	let state = {
		global: {
			webui_port: DEFAULT_WEBUI_PORT,
			sni: DEFAULT_SNI
		},
		inbounds: []
	};

	// foreach возвращает null/false при отсутствии конфига; результат не важен:
	// default state выше уже готов, а секции callback уже добавил.
	let clients = [];

	ctx.foreach(UCI_CONFIG, null, (s) => {
		let type = s['.type'];

		if (type == 'global') {
			state.global.webui_port = s.webui_port != null ? int(s.webui_port) : DEFAULT_WEBUI_PORT;
			state.global.sni = s.sni ?? DEFAULT_SNI;
		}
		else if (type == 'inbound') {
			push(state.inbounds, {
				id: s.id ?? s['.name'],
				name: s.name ?? '',
				port: s.port != null ? int(s.port) : null,
				vip: s.vip ?? '',
				private_key: s.private_key ?? '',
				public_key: s.public_key ?? '',
				short_id: s.short_id ?? '',
				// stand_code — код стенд-страницы подключений;
				// инбаунды без опции имеют null — get_stand
				// такой инбаунд по коду не найдёт (стенда у него нет).
				stand_code: s.stand_code ?? null,
				fw_rule: s.fw_rule ?? '',
				// Выключенный инбаунд НЕ удаляется — только не
				// попадает в конфиг sing-box (renderConfig). UCI-опция
				// enabled '1'|'0'; ОТСУТСТВИЕ опции = включён.
				enabled: s.enabled != '0',
				// per-inbound SNI. null = «своего нет, берём
				// global.sni» (обратная совместимость).
				// Созданный через WebUI фиксирует значение
				// на момент создания.
				sni: s.sni ?? null,
				clients: []
			});
		}
		else if (type == 'client') {
			push(clients, {
				id: s.id ?? s['.name'],
				inbound: s.inbound ?? '',
				name: s.name ?? '',
				uuid: s.uuid ?? '',
				// Выключенный клиент не попадает в users
				// инбаунда, но uuid и UCI-секция сохраняются.
				enabled: s.enabled != '0'
			});
		}

		return true;
	});

	// Прикрепляем клиентов к их инбаундам (client.inbound == inbound.id).
	for (let c in clients) {
		for (let inb in state.inbounds) {
			if (inb.id == c.inbound) {
				push(inb.clients, c);
				break;
			}
		}
	}

	return state;
}

// state — вывод loadState(); global — { webui_port, sni }.
// disabled-инбаунды и их клиенты НЕ попадают в конфиг (данные
// в UCI сохраняются — выключенное не удаляется); sni инбаунда =
// inb.sni ?? global.sni.
function renderConfig(state, global) {
	let globalSni = global?.sni ?? state?.global?.sni ?? DEFAULT_SNI;

	// enabled в loadState уже даёт bool, но структура может
	// прийти из другого источника (тесты передают литералы) —
	// трактуем отсутствующее/истинное как включённое.
	let inbounds = map(filter(state?.inbounds ?? [], (inb) => inb?.enabled != false && inb?.enabled != '0'), (inb) => {
		// per-inbound SNI: свой или global (обратная совместимость).
		let sni = inb?.sni ?? globalSni;

		let users = map(filter(inb.clients ?? [], (c) => c?.enabled != false && c?.enabled != '0'), (c) => {
			// flow ОБЯЗАТЕЛЕН в users сервера: клиент по ссылке
			// использует xtls-rprx-vision, и Reality отклоняет
			// соединение с Vision-флоу, не объявленным на сервере
			// («processed invalid connection»:
			// сервер должен объявлять ровно тот flow, что в ссылке).
			return {
				name: c.name,
				uuid: c.uuid,
				flow: 'xtls-rprx-vision'
			};
		});

		return {
			type: 'vless',
			tag: inb.name,
			listen: '0.0.0.0',
			listen_port: inb.port,
			users: users,
			tls: {
				enabled: true,
				server_name: sni,
				reality: {
					// enabled ОБЯЗАТЕЛЕН: без него sing-box 1.12 считает TLS
					// обычным и требует certificate («missing certificate»
					// на sing-box check; sing-box 1.12.12).
					enabled: true,
					handshake: {
						server: sni,
						server_port: REALITY_HANDSHAKE_PORT
					},
					private_key: inb.private_key,
					short_id: [ inb.short_id ]
				}
			}
		};
	});

	return {
		log: { level: 'warn' },
		inbounds: inbounds,
		outbounds: [
			{
				type: 'direct',
				tag: 'direct',
				routing_mark: ROUTING_MARK
			}
		],
		route: { final: 'direct' }
	};
}

// LAN CIDR вида '192.168.1.0/24' -> VIP в той же подсети: .240 вверх до .250,
// пропуская занятые (taken — массив строк-IP). null — диапазон исчерпан/мусор.
// Поддерживает не-192.168.1.0/24 (10.5.0.0/24 → 10.5.0.240) и /16
// (172.16.0.0/16 → 172.16.0.240): prefixlen задаёт, сколько октетов «подсети».
function allocateVip(lanCidr, taken) {
	if (type(lanCidr) != 'string')
		return null;

	let parts = split(lanCidr, '/');
	if (length(parts) != 2)
		return null;

	let ip = iptoarr(parts[0]);
	let prefix = int(parts[1]);

	// `prefix != prefix` — идиома проверки на NaN в ucode: int('abc') даёт NaN,
	// а NaN не равен ничем, включая самого себя. iptoarr возвращает null на мусоре.
	if (ip == null || length(ip) != 4 || prefix != prefix)
		return null;
	// Префиксы /25-/30 отклоняем: VIP меняет только последний октет (.240-.250),
	// и в подсети короче /24 результат выйдет за её пределы (например,
	// 192.168.1.0/25 → 192.168.1.240 лежит во второй половине /25).
	// Префиксы /1-/7 тоже отклоняем (слишком широкая сеть, вне сценария).
	// Подсети /8-/23 (шире /24) корректны: базовые октеты копируются как есть.
	if (prefix < 8 || prefix > 24)
		return null;

	// Число октетов подсети: /1..8 -> 1, /9..16 -> 2, /17..24 -> 3.
	// VIP меняет только последний октет, поэтому входные октеты, входящие в
	// подсеть, копируем как есть: 172.16.0.0/16 -> 172.16.0.240.
	let base = [ ip[0], ip[1], ip[2] ];

	for (let last = VIP_RANGE_START; last <= VIP_RANGE_END; last++) {
		let candidate = sprintf('%d.%d.%d.%d', base[0], base[1], base[2], last);

		let busy = false;
		for (let t in (taken ?? []))
			if (t == candidate) { busy = true; break; }

		if (!busy)
			return candidate;
	}

	return null;
}

// Первый свободный порт, начиная со start (по умолчанию 443).
// taken — числа или строки-числа; поиск без верхнего предела.
function nextFreePort(taken, start) {
	let from = start ?? 443;
	let occupied = {};

	for (let t in (taken ?? []))
		occupied[int(t)] = true;

	let port = from;
	while (exists(occupied, port))
		port++;

	return port;
}

// --- клиенты и vless-ссылки ---

// encodeURIComponent-совместимое URL-кодирование (RFC 3986, unreserved-
// множество). Строки ucode — байтовые, поэтому не-ASCII (кириллица, emoji)
// автоматически кодируются как UTF-8 percent-последовательности.
// Непроверяемые символы: [A-Za-z0-9-_.!~*'()] — «-» в конце класса,
// чтобы не образовывать range.
function urlencode(str) {
	// type-guard — числа/объекты не должны молча
	// превращаться в '' (length() от не-строки падает по-разному);
	// null → '', не-string → строковое представление через sprintf.
	str = (str ?? '');
	if (type(str) != 'string')
		str = sprintf('%s', str);

	let out = '';

	for (let i = 0; i < length(str); i++) {
		let ch = substr(str, i, 1);

		if (match(ch, /[A-Za-z0-9_.!~*'()-]/) != null)
			out += ch;
		else
			out += '%' + uc(hexenc(ch));
	}

	return out;
}

// Ссылка клиента vless:// для Reality+Vision. Точный формат:
//   vless://<uuid>@<host>:<port>?encryption=none&security=reality
//          &pbk=<public_key>&fp=chrome&sid=<short_id>&sni=<sni>
//          &type=tcp&flow=xtls-rprx-vision#<имя-urlencoded>
// inbound/client/global — структуры loadState; host — IP/имя сервера.
// sni ссылки = inbound.sni ?? global.sni (per-inbound SNI).
function buildVlessLink(inbound, client, global, host) {
	let query = sprintf(
		'encryption=none&security=reality&pbk=%s&fp=chrome&sid=%s&sni=%s&type=tcp&flow=xtls-rprx-vision',
		urlencode(inbound?.public_key ?? ''),
		urlencode(inbound?.short_id ?? ''),
		urlencode(inbound?.sni ?? global?.sni ?? DEFAULT_SNI)
	);

	return sprintf(
		'vless://%s@%s:%d?%s#%s',
		urlencode(client?.uuid ?? ''),
		urlencode(host ?? ''),
		inbound?.port ?? 0,
		query,
		urlencode(client?.name ?? '')
	);
}

return {
	loadState: loadState,
	renderConfig: renderConfig,
	allocateVip: allocateVip,
	nextFreePort: nextFreePort,
	urlencode: urlencode,
	buildVlessLink: buildVlessLink
};

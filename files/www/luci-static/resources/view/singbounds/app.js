// app.js — единая LuCI-страница sing-bounds v1.1.
//
// Одна страница, 4 таба (Обзор / Инбаунды / Настройки / Система).
//
// Структура файла:
//   - rpc.declare на ВСЕ ubus-методы singbounds;
//   - inline-CSS (style.textContent): CSS-переменные и стили
//     (без .luci-* хрома — обвязку LuCI делает сам);
//     блоки статов/быстрого подключения/тостов/спиннера и
//     ip-row/ip-result (Настройки);
//   - шапка: заголовок + подзаголовок + живой бейдж статуса (status.running);
//   - табы: кнопки + display-toggle контейнеров, активная — заливка
//     accent; выбор сохраняется в location.hash (#overview/…);
//   - таб «Обзор» (4 стата + карточка «Быстрое подключение» с большим
//     QR, ссылкой и копированием) и таб «Инбаунды» (карточки-аккордеоны
//     с бейджами вкл/выкл, kv-ключами, клиентами с мини-QR, toggle/
//     add/del, модалка создания);
//   - таб «Настройки» (карточка «Общие»: SNI по умолчанию, WAN-адрес +
//     «Проверить» → check_wan со строкой «<ip> — ответ за <ms> мс»,
//     сохранение через LuCI uci-токен) и таб «Система» (kv Версия/
//     Конфигурация/Uptime из ubus system info, «Перезапустить сервис»
//     → rpc restart, «Удалить sing-bounds» → uninstall с confirm);
//   - v1.2: «Скачать QR» (PNG 1080×1080, отдельный hi-res рендер).
//
// QR (qrcode.js, вендорный kazuhikoarase, лежит рядом в view-каталоге):
// LuCI-загрузчик НЕ может require-нуть его как модуль (compileClass требует
// Class-фабрику, а qrcode.js — IIFE с глобальной var qrcode и AMD-веткой
// без define.amd в LuCI). Поэтому грузим его обычным <script>-тегом:
// после onload глобальная
// window.qrcode доступна, канвас рисуем вручную из isDark (QR-модули).
//
// Все ubus-вызовы идут через withBusy() (спиннер-оверлей, закрывается по
// завершению), ошибки — красным тостом с текстом бэкенда.

'use strict';
'require view';
'require rpc';
'require ui';
'require uci';

// --- ubus-методы singbounds (объект объявлен в rpcd-плагине, гранты —
// files/acl.d/luci-app-singbounds.json). expect-дефолты дают полям
// значения на случай отсутствующих ключей в ответе ubus.

var callStatus = rpc.declare({
	object: 'singbounds',
	method: 'status',
	expect: { '': { running: false, version: '', inbounds: 0, next_port: 0, next_vip: '' } }
});

var callList = rpc.declare({
	object: 'singbounds',
	method: 'list',
	expect: { inbounds: [] }
});

var callAddInbound = rpc.declare({
	object: 'singbounds',
	method: 'add_inbound',
	params: [ 'name', 'port', 'sni', 'vip' ],
	expect: { '': {} }
});

var callDelInbound = rpc.declare({
	object: 'singbounds',
	method: 'del_inbound',
	params: [ 'id' ],
	expect: { deleted: false }
});

var callAddClient = rpc.declare({
	object: 'singbounds',
	method: 'add_client',
	params: [ 'inbound', 'name' ],
	expect: { '': {} }
});

var callDelClient = rpc.declare({
	object: 'singbounds',
	method: 'del_client',
	params: [ 'inbound', 'id' ],
	expect: { deleted: false }
});

var callGetLinks = rpc.declare({
	object: 'singbounds',
	method: 'get_links',
	params: [ 'inbound' ],
	// ВАЖНО: expect в LuCI rpc идёт по ПЕРВОМУ ключу, достаёт ret['links'] и
	// резолвит ТОЛЬКО массивом links — остальной объект теряется, а
	// fetchLinks потом искал (r||{}).links у МАССИВА => undefined => []
	// => карточки без pbk/sid и «ссылка недоступна». Убрали expect:
	// резолвится весь объект {links} целиком.
});

var callToggleInbound = rpc.declare({
	object: 'singbounds',
	method: 'toggle_inbound',
	params: [ 'id', 'enabled' ],
	expect: { toggled: false }
});

var callToggleClient = rpc.declare({
	object: 'singbounds',
	method: 'toggle_client',
	params: [ 'id', 'enabled' ],
	expect: { toggled: false }
});

var callEditInbound = rpc.declare({
	object: 'singbounds',
	method: 'edit_inbound',
	params: [ 'id', 'name', 'port', 'sni' ],
	expect: { edited: false }
});

var callCheckWan = rpc.declare({
	object: 'singbounds',
	method: 'check_wan',
	expect: { '': { ip: '', ms: 0 } }
});

// uninstall нужен только табу «Система», но объявляем сразу —
// rpc-слой каркаса полный.
var callUninstall = rpc.declare({
	object: 'singbounds',
	method: 'uninstall',
	expect: { '': {} }
});

// restart (таб «Система»): ubus-метода рестарта НЕТ (объект rc
// недоступен LuCI через ACL-стандартный путь, а luci.rc
// «Method not found») — сделали свой rpcd-метод, который
// выполняет /etc/init.d/singbounds restart из backend.sh.
var callRestart = rpc.declare({
	object: 'singbounds',
	method: 'restart',
	expect: { restarted: false }
});

// --- Tailscale (модала «Новый туннель»): status/server/login/logout/remove.
// tsc_status и tsc_login: без expect — pass-through объекта
// (state/authurl приходят разными наборами полей).
var callTscStatus = rpc.declare({
	object: 'singbounds',
	method: 'tsc_status'
});

// install_info: {installed, space_ok, free_kb, need_kb, usb:[{dev,mnt}]}
var callTscInstallInfo = rpc.declare({
	object: 'singbounds',
	method: 'tsc_install_info'
});

// install: where = 'overlay' | 'usb:/mnt/...'. Может идти минуты
// (скачивание пакета) — timeout побольше стандартного.
var callTscInstall = rpc.declare({
	object: 'singbounds',
	method: 'tsc_install',
	params: [ 'where' ],
	expect: { installed: false },
	timeout: 300000
});

var callTscServer = rpc.declare({
	object: 'singbounds',
	method: 'tsc_server',
	params: [ 'server', 'authkey', 'routes' ],
	expect: { configured: false }
});

var callTscLogin = rpc.declare({
	object: 'singbounds',
	method: 'tsc_login'
});

var callTscLogout = rpc.declare({
	object: 'singbounds',
	method: 'tsc_logout',
	expect: { logged_out: false }
});

var callTscRemove = rpc.declare({
	object: 'singbounds',
	method: 'tsc_remove',
	expect: { removed: false }
});

// uptime для таба «Система»: стандартный ubus system info (поле
// uptime есть, в секундах). expect-дефолт защищает от
// отсутствующего поля.
var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info',
	expect: { '': { uptime: 0 } }
});

// --- inline-CSS: светлая тема с чёткой иерархией: явные бордеры
// #D4D9E6, кнопки с различимыми фонами, табы — сегментированный
// контрол, синий #1D4ED8 (контраст 6.3:1), серый текст не светлее
// #5B6472 (4.6:1 на белом). QR — на белом. ---
var CSS = [
	':host{',
	'  --font:"Inter","Segoe UI",system-ui,sans-serif;',
	'  --mono:ui-monospace,"JetBrains Mono",Consolas,monospace;',
	'  --radius:16px; --radius-sm:11px;',
	'  --surface:#ffffff; --surface-2:#F5F6FA; --surface-3:#ECEEF4;',
	'  --border:#D4D9E6; --border-2:#B9C0D0;',
	'  --text:#1A2030; --text-2:#3D4657; --muted:#5B6472;',
	'  --accent:#1D4ED8; --accent-hi:#2563EB; --accent-ring:rgba(37,99,235,.22);',
	'  --ok:#15803D; --ok-bg:#E7F6EC; --ok-dot:#16A34A;',
	'  --off:#6B7484; --off-bg:#EFF1F5;',
	'  --bad:#B4232A; --bad-bg:#FBEAEA;',
	'}',
	'h1{font-size:20px;font-weight:700;letter-spacing:-.015em;margin:0;color:var(--text)}',
	'.sub{color:var(--muted);font-size:13px;margin-top:3px}',
	'.bar{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:18px;flex-wrap:wrap}',
	'.spacer{display:flex;gap:10px;align-items:center;flex-wrap:wrap}',
	'',
	'/* Табы: сегментированный контрол (капсула, активная пилюля) */',
	'.tabs{display:flex;gap:4px;background:var(--surface-2);border:1px solid var(--border);border-radius:13px;padding:4px;width:-moz-fit-content;width:fit-content;max-width:100%;margin-bottom:20px;flex-wrap:wrap}',
	'.tab{display:inline-flex;align-items:center;padding:8px 16px;border-radius:9px;border:0;background:transparent;color:var(--muted);font:600 13px/1 var(--font);cursor:pointer;transition:background .15s,color .15s;white-space:nowrap}',
	'.tab:hover:not(.active){background:var(--surface-3);color:var(--text)}',
	'.tab:active{transform:scale(.97)}',
	'.tab.active{background:#fff;color:var(--accent);box-shadow:0 1px 3px rgba(26,32,48,.12),0 0 0 1px var(--border)}',
	'.tab:focus-visible{outline:2px solid var(--accent-hi);outline-offset:1px}',
	'',
	'.st-badge{display:inline-flex;align-items:center;gap:8px;padding:6px 13px;border-radius:999px;font-size:12px;font-weight:650;border:1px solid transparent}',
	'.st-badge.on{background:var(--ok-bg);color:var(--ok);border-color:#B5E0C3}',
	'.st-badge.off{background:var(--off-bg);color:var(--off);border-color:var(--border)}',
	'.dot{width:8px;height:8px;border-radius:50%;flex:none}',
	'.on .dot{background:var(--ok-dot);animation:ring 2s infinite}',
	'.off .dot{background:var(--off)}',
	'@keyframes ring{0%{box-shadow:0 0 0 0 rgba(22,163,74,.4)}70%{box-shadow:0 0 0 7px rgba(22,163,74,0)}100%{box-shadow:0 0 0 0 rgba(22,163,74,0)}}',
	'',
	'/* Кнопки: различимые фоны, явные бордеры и disabled */',
	'.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:38px;padding:9px 16px;border-radius:var(--radius-sm);background:var(--surface-3);color:var(--text);border:1px solid var(--border-2);font:600 13px/1 var(--font);cursor:pointer;transition:background .15s,border-color .15s,transform .1s;box-shadow:0 1px 2px rgba(26,32,48,.07)}',
	'.btn:hover:not([disabled]){background:#E2E5EC;border-color:var(--border-2)}',
	'.btn:active:not([disabled]){transform:scale(.97);box-shadow:none}',
	'.btn:focus-visible{outline:2px solid var(--accent-hi);outline-offset:2px}',
	'.btn[disabled]{opacity:.45;cursor:not-allowed;box-shadow:none}',
	'.btn-primary{background:var(--accent);color:#fff;border:1px solid var(--accent)}',
	'.btn-primary:hover:not([disabled]){background:var(--accent-hi);border-color:var(--accent-hi);box-shadow:0 4px 12px -6px rgba(29,78,216,.55)}',
	'.btn-remove{background:var(--bad-bg);color:var(--bad);border:1px solid #E8C2C4}',
	'.btn-remove:hover:not([disabled]){background:#F6DCDC}',
	'.btn-sm{min-height:32px;padding:6px 12px;font-size:12px}',
	'a.btn{text-decoration:none}',
	'',
	'/* Карточки: белые, но с ВИДИМЫМ бордером — не сливаются с фоном LuCI */',
	'.card{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius);margin-bottom:14px;overflow:hidden;transition:opacity .25s,border-color .2s;box-shadow:0 1px 3px rgba(26,32,48,.06)}',
	'.card:hover{border-color:var(--border-2)}',
	'.card.disabled{opacity:.6}',
	'.card-head{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:16px 18px;cursor:pointer;transition:background .15s}',
	'.card-head:hover{background:var(--surface-2)}',
	'.card.disabled .card-head:hover{background:transparent}',
	'.card-head .name{font-size:15px;font-weight:650;letter-spacing:-.01em;display:flex;align-items:center;gap:10px;color:var(--text)}',
	'.meta{display:flex;gap:16px;color:var(--muted);font-size:12px;margin-top:4px;flex-wrap:wrap}',
	'.meta b{color:var(--text-2);font-weight:600;font-family:var(--mono);font-size:11.5px}',
	'.card-body{border-top:1px solid var(--border);padding:18px;display:none}',
	'.card.open .card-body{display:block}',
	'.chev{transition:transform .2s;color:var(--muted)}',
	'.card.open .chev{transform:rotate(180deg)}',
	'',
	'.kv{display:grid;grid-template-columns:140px 1fr;gap:10px 16px;font-size:13px;margin-bottom:16px}',
	'.kv dt{color:var(--muted)}',
	'.kv dd{font-family:var(--mono);font-size:12px;word-break:break-all;margin:0;color:var(--text-2)}',
	'',
	'/* Tailscale: карточка туннеля + radio-опции в модале */',
	'.tsc-card .card-head{padding:16px 18px}',
	'.tsc-card .card-body{display:block;padding:0 18px 18px}',
	'.tsc-card .card-title{display:flex;align-items:center;gap:10px;flex-wrap:wrap}',
	'.tsc-card .muted{color:var(--muted);font-size:12px}',
	'.badge{display:inline-flex;align-items:center;padding:4px 10px;border-radius:999px;font-size:11px;font-weight:650;border:1px solid transparent}',
	'.badge.ok{background:var(--ok-bg);color:var(--ok);border-color:#B5E0C3}',
	'.badge.warn{background:#FFF6E0;color:#8A6116;border-color:#EBD9A8}',
	'.tsc-opt{display:block;border:1px solid var(--border);border-radius:12px;padding:12px 14px;background:var(--surface-2);margin-bottom:8px;cursor:pointer}',
	'.tsc-opt:hover{border-color:var(--border-2)}',
	'.tsc-opt.sel{border-color:var(--accent-hi);box-shadow:0 0 0 3px var(--accent-ring);background:var(--surface)}',
	'.tsc-opt label{display:flex;align-items:center;gap:9px;cursor:pointer;font-size:13.5px;font-weight:650;color:var(--text)}',
	'.tsc-opt input[type=radio]{accent-color:var(--accent);width:15px;height:15px;flex:none;cursor:pointer}',
	'.tsc-opt .hint{margin-top:6px;font-size:11.5px;color:var(--muted);line-height:1.45}',
	'',
	'.cl-row{display:flex;justify-content:space-between;gap:14px;padding:14px 0;border-top:1px solid var(--border)}',
	'.cl-row:first-child{border-top:none;padding-top:4px}',
	'.cl-row.off{opacity:.55}',
	'.cl-name{font-weight:650;font-size:14px;display:flex;align-items:center;gap:10px;color:var(--text)}',
	'.cl-uuid{color:var(--muted);font-family:var(--mono);font-size:11px;margin-top:2px}',
	'.link-line{display:flex;gap:8px;margin-top:10px;align-items:stretch;flex-wrap:wrap}',
	'.link-txt{flex:1;min-width:220px;background:var(--surface-2);border:1px solid var(--border);border-radius:9px;padding:9px 12px;font-family:var(--mono);font-size:10.5px;color:var(--text-2);user-select:all;word-break:break-all;white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.5}',
	'.qr-click{cursor:zoom-in;position:relative;transition:border-color .15s,box-shadow .15s}',
	'.qr-click:hover{border-color:var(--accent-hi);box-shadow:0 0 0 3px var(--accent-ring)}',
	'.qr-big-modal{display:flex;flex-direction:column;align-items:center;gap:14px}',
	'.qr-big-modal .qr-view{width:340px;height:340px;border-radius:14px;background:#fff;border:1px solid var(--border-2);display:grid;place-items:center;overflow:hidden}',
	'.qr-big-modal .qr-view canvas{display:block;width:320px;height:320px}',
	'.qr-big-modal .qr-caption{font:600 12px var(--font);color:var(--muted);text-align:center;max-width:340px;word-break:break-all}',
	'',
	'/* QR — всегда на белом (сканируемость) */',
	'.qr-box{width:76px;height:76px;border-radius:10px;background:#fff;border:1px solid var(--border-2);display:grid;place-items:center;color:var(--muted);font-size:10px;text-align:center;overflow:hidden;flex:none}',
	'.qr-box canvas{display:block;width:76px;height:76px;border-radius:9px}',
	'',
	'/* Модалки: фон-затемнение плотнее (фон страницы не просвечивает) */',
	'.modal-back{position:fixed;inset:0;background:rgba(26,32,48,.55);backdrop-filter:blur(5px);display:grid;place-items:center;padding:20px;z-index:50;opacity:0;pointer-events:none;transition:opacity .2s}',
	'.modal-back.show{opacity:1;pointer-events:auto}',
	'.modal{background:var(--surface);border:1px solid var(--border);border-radius:18px;box-shadow:0 30px 80px -20px rgba(26,32,48,.35);width:100%;max-width:560px;transform:translateY(12px) scale(.98);transition:transform .2s}',
	'.modal-back.show .modal{transform:none}',
	'.form{padding:24px}',
	'.form h3{font-size:17px;font-weight:700;margin:0 0 4px;color:var(--text)}',
	'.form .lead{color:var(--muted);font-size:12.5px;margin-bottom:18px}',
	'.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}',
	'.field label{display:block;font-size:12px;font-weight:600;margin-bottom:6px;color:var(--text-2)}',
	'.field .hint{color:var(--muted);font-size:11.5px;margin-top:5px}',
	'.field input{width:100%;background:var(--surface-2);border:1px solid var(--border-2);border-radius:10px;padding:10px 12px;color:var(--text);font-size:13.5px;font-family:var(--mono);transition:border-color .15s,box-shadow .15s;box-sizing:border-box}',
	'.field input::placeholder{color:var(--muted)}',
	'.field input:focus{outline:none;border-color:var(--accent-hi);box-shadow:0 0 0 3px var(--accent-ring)}',
	'.field input[readonly]{background:var(--surface-3);color:var(--muted)}',
	'.actions{display:flex;justify-content:flex-end;gap:10px;margin-top:18px;padding-top:16px;border-top:1px solid var(--border)}',
	'.modal .actions{justify-content:flex-end}',
	'.add-client{justify-content:flex-start}',
	'',
	'/* Модалка «Новый туннель»: сегмент типа + поля Tailscale */',
	'.modal .form h3{margin-bottom:6px}',
	'.type-bar{display:flex;gap:6px;background:var(--surface-2);border:1px solid var(--border);border-radius:12px;padding:5px;margin-bottom:16px}',
	'.type-bar .type-sel{flex:1;justify-content:center;box-shadow:none;background:transparent;border-color:transparent;color:var(--muted)}',
	'.type-bar .type-sel:hover:not(.disabled){background:var(--surface-3);color:var(--text)}',
	'.type-bar .type-sel.sel{background:var(--accent);color:#fff;border-color:var(--accent);box-shadow:none}',
	'.type-sel.disabled{opacity:.45;cursor:not-allowed}',
	'.modal .tsc-block{display:grid;grid-template-columns:1fr;gap:0}',
	'.modal .tsc-block .field{margin-top:14px}',
	'.modal .tsc-note{margin-top:10px;font-size:12px;color:var(--muted);line-height:1.5}',
	'.modal .tsc-note a{color:var(--accent)}',
	'',
	'/* Обзор: статы */',
	'.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:16px}',
	'.stat{background:var(--surface);border:1px solid var(--border);border-radius:var(--radius-sm);padding:16px 18px;box-shadow:0 1px 3px rgba(26,32,48,.06)}',
	'.stat-num{font-size:26px;font-weight:700;letter-spacing:-.02em;color:var(--text);font-family:var(--mono)}',
	'.stat-label{color:var(--text-2);font-size:12.5px;font-weight:600;margin-top:2px}',
	'.stat-sub{color:var(--muted);font-size:11.5px;margin-top:3px}',
	'.stat-sub.ok{color:var(--ok)}',
	'',
	'/* Обзор: быстрое подключение */',
	'.qc{display:flex;gap:20px;align-items:flex-start;flex-wrap:wrap}',
	'.qc-left{flex:0 0 auto}',
	'.qc-right{flex:1;min-width:260px}',
	'.qc-title{font-size:15px;font-weight:650;color:var(--text)}',
	'.qc-sub{color:var(--muted);font-size:12.5px;margin:2px 0 10px}',
	'.qr-big{width:180px;height:180px;border-radius:14px;background:#fff;border:1px solid var(--border-2);display:grid;place-items:center;overflow:hidden}',
	'.qr-big canvas{display:block;width:180px;height:180px}',
	'.qr-big .qr-stub{color:var(--muted);font-size:11px;text-align:center}',
	'.hint-empty{color:var(--muted);font-size:13px}',
	'',
	'/* Тосты */',
	'.sb-toasts{position:fixed;left:50%;transform:translateX(-50%);bottom:22px;display:flex;flex-direction:column;align-items:center;gap:8px;z-index:70;pointer-events:none}',
	'.sb-toast{padding:11px 18px;border-radius:12px;font:600 13px/1.3 var(--font);color:#fff;box-shadow:0 12px 34px -12px rgba(26,32,48,.4);opacity:0;transform:translateY(6px);transition:opacity .2s,transform .2s;max-width:460px}',
	'.sb-toast.show{opacity:1;transform:none}',
	'.sb-toast.ok{background:#0C8A5F}',
	'.sb-toast.err{background:#B4232A}',
	'',
	'/* Спиннер ubus-вызовов */',
	'.sb-busy{position:fixed;inset:0;background:rgba(26,32,48,.35);backdrop-filter:blur(2px);display:grid;place-items:center;z-index:60}',
	'.sb-busy-box{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:16px 22px;display:flex;align-items:center;gap:12px;font:600 13.5px var(--font);color:var(--text);box-shadow:0 20px 50px -20px rgba(26,32,48,.35)}',
	'.sb-spin{width:18px;height:18px;border-radius:50%;border:2.5px solid var(--surface-3);border-top-color:var(--accent-hi);animation:spin .8s linear infinite}',
	'@keyframes spin{to{transform:rotate(360deg)}}',
	'',
	'/* Настройки: WAN-проверка */',
	'.ip-row{display:flex;gap:10px;align-items:flex-start}',
	'.ip-row .field{flex:1;min-width:0}',
	'.ip-check{white-space:nowrap;margin-top:0}',
	'.ip-result{margin-top:8px;font-size:12.5px;font-weight:600;display:flex;align-items:center;gap:7px}',
	'.ip-result.ok{color:var(--ok)}',
	'.ip-result.ok .dot{width:8px;height:8px;border-radius:50%;background:var(--ok-dot)}',
	'.ip-result.err{color:var(--bad)}',
	'.ip-result.err .dot{width:8px;height:8px;border-radius:50%;background:var(--bad)}',
	'',
	'/* Скрыть стандартные LuCI-кнопки «Применить/Сохранить/Очистить»:',
	'   наш view управляет всем сам (ubus-мутации без UCI-apply).',
	'   Селектор скопирован на нашу страницу через body[data-page] —',
	'   чужие страницы LuCI не затрагиваются. */',
	'.sb-page-actions-none { display:none }',
	'',
	'/* Кнопки в карточках: wrap + min-width, чтобы не обрезались на мобиле */',
	'.actions{flex-wrap:wrap}',
	'.actions .btn{min-width:0;max-width:100%}',
	'',
	'@media(max-width:560px){.kv{grid-template-columns:105px 1fr}.cl-row{flex-direction:column}.cl-row .spacer{flex-direction:row !important;align-items:flex-start}.tabs{width:100%}.tab{flex:1;justify-content:center}.sb-page{padding:14px}.actions{gap:8px}}'
].join('\n');

// Табы: id ↔ hash ↔ заголовок. Активная вкладка пишется в
// location.hash, при открытии страницы читается оттуда (дефолт — обзор).
var TABS = [
	{ id: 'overview',  title: 'Обзор' },
	{ id: 'inbounds',  title: 'Инбаунды' },
	{ id: 'settings',  title: 'Настройки' },
	{ id: 'system',    title: 'Система' }
];

// --- загрузка вендорного qrcode.js (см. шапку): обычный <script>-тег.
// Глобальная window.qrcode после onload. Суффикс ?v= сбивает кэш браузера
// при обновлениях (uhttpd отдаёт luci-static без Cache-Control, браузер
// кэширует эвристически и юзер видит старую версию после апгрейда). ---
var SB_ASSET_VER = '1.2.1';
var qrReady = new Promise(function (resolve) {
	if (typeof window.qrcode === 'function') {
		resolve(window.qrcode);
		return;
	}
	var s = document.createElement('script');
	s.src = (typeof L !== 'undefined' && L.resource)
		? L.resource('view/singbounds/qrcode.js') + '?v=' + SB_ASSET_VER
		: '/luci-static/resources/view/singbounds/qrcode.js' + '?v=' + SB_ASSET_VER;
	s.onload = function () { resolve(window.qrcode || null); };
	s.onerror = function () { resolve(null); };
	(document.head || document.documentElement).appendChild(s);
});

// --- маленькие компоненты: тосты и спиннер ---

var toastBox = null;

// toast(text, ok): зелёный/красный, автоскрытие 3 с.
function toast(text, ok) {
	if (!toastBox) {
		toastBox = E('div', { 'class': 'sb-toasts', 'aria-live': 'polite' });
		document.body.appendChild(toastBox);
	}
	var t = E('div', { 'class': 'sb-toast ' + (ok ? 'ok' : 'err') }, String(text));
	toastBox.appendChild(t);
	/* появление — на следующем тике, чтобы transition сыграл */
	window.setTimeout(function () { t.classList.add('show'); }, 10);
	window.setTimeout(function () {
		t.classList.remove('show');
		window.setTimeout(function () { t.remove(); }, 250);
	}, 3000);
}

var busyCount = 0;
var busyEl = null;

function showBusy(text) {
	busyCount = busyCount + 1;
	if (busyCount === 1) {
		busyEl = E('div', {
			'class': 'sb-busy',
			/* В body — вне .sb-page: несём копию CSS-переменных темы
			   (как .modal-back), иначе карточка спиннера прозрачная. */
			'style': [
				'--font:"Inter","Segoe UI",system-ui,sans-serif',
				'--surface:#ffffff;--surface-2:#F5F6FA;--surface-3:#ECEEF4',
				'--border:#D4D9E6;--border-2:#B9C0D0',
				'--text:#1A2030;--text-2:#3D4657;--muted:#5B6472',
				'--accent:#1D4ED8'
			].join(';')
		}, [
			E('div', { 'class': 'sb-busy-box' }, [
				E('span', { 'class': 'sb-spin' }),
				text || 'Работаю…'
			])
		]);
		document.body.appendChild(busyEl);
	}
}

function hideBusy() {
	if (busyCount > 0)
		busyCount = busyCount - 1;
	if (busyCount === 0 && busyEl) {
		busyEl.remove();
		busyEl = null;
	}
}

// withBusy(p, text): спиннер на время промиса, снятие — по завершению.
function withBusy(p, text) {
	showBusy(text);
	return p.finally(hideBusy);
}

// --- буфер обмена ---

// copyText(text) -> Promise<boolean>: navigator.clipboard в secure
// context, иначе скрытая textarea + execCommand
// (LuCI на http:// не даёт secure context).
function copyText(text) {
	return new Promise(function (resolve) {
		if (navigator.clipboard && window.isSecureContext) {
			navigator.clipboard.writeText(text).then(function () {
				resolve(true);
			}, function () {
				resolve(legacyCopy(text));
			});
		} else {
			resolve(legacyCopy(text));
		}
	});
}

function legacyCopy(text) {
	var ta = document.createElement('textarea');
	ta.value = text;
	ta.setAttribute('readonly', '');
	ta.style.position = 'fixed';
	ta.style.top = '-1000px';
	document.body.appendChild(ta);
	ta.select();
	var ok = false;
	try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
	document.body.removeChild(ta);
	return ok;
}

// copyCanvasPng(canvas): ClipboardItem в secure context; фолбэк —
// скачивание PNG (toast «QR сохранён» — вызывающий).
function copyCanvasPng(canvas) {
	if (navigator.clipboard && window.isSecureContext && window.ClipboardItem && canvas.toBlob) {
		return new Promise(function (resolve) {
			canvas.toBlob(function (blob) {
				if (!blob) {
					resolve(false);
					return;
				}
				navigator.clipboard.write([ new ClipboardItem({ 'image/png': blob }) ])
					.then(function () { resolve(true); },
					      function () { resolve(false); });
			}, 'image/png');
		});
	}
	return Promise.resolve(false);
}

// downloadCanvasPng(canvas, filename): <a download> + data URL.
function downloadCanvasPng(canvas, filename) {
	try {
		var a = document.createElement('a');
		a.href = canvas.toDataURL('image/png');
		a.download = filename;
		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
		return true;
	} catch (e) {
		return false;
	}
}

// downloadQrHiRes(link, filename): рендер QR в НОРМАЛЬНОМ разрешении
// (1080×1080 — печатается/вставляется в чат без «мыла») и скачивание.
// Отдельный canvas, экранный QR не трогаем. false — не построился.
function downloadQrHiRes(link, filename) {
	var hi = document.createElement('canvas');
	hi.width = 1080;
	hi.height = 1080;
	if (!drawQr(hi, link))
		return false;
	return downloadCanvasPng(hi, filename || 'sing-bounds-qr.png');
}

// --- QR-рендер (qrcode.js kazuhikoarase) на <canvas> ---

// drawQr(canvas, link): QR из ровно ссылки (уровень M, автотип,
// UTF-8-энкодер, тихая зона 2 модуля). false — не построился.
function drawQr(canvas, link) {
	var QR = window.qrcode;
	if (typeof QR !== 'function' || !link)
		return false;
	try {
		QR.stringToBytes = QR.stringToBytesFuncs['UTF-8'];
		var qr = QR(0, 'M');
		qr.addData(link);
		qr.make();
		var n = qr.getModuleCount();
		var quiet = 2;
		var total = n + quiet * 2;
		var size = canvas.width; /* атрибут в px (2× CSS для чёткости) */
		var cell = size / total;
		var ctx = canvas.getContext('2d');
		ctx.fillStyle = '#ffffff';
		ctx.fillRect(0, 0, size, size);
		ctx.fillStyle = '#151a26';
		for (var r = 0; r < n; r++)
			for (var c = 0; c < n; c++)
				if (qr.isDark(r, c))
					ctx.fillRect(
						Math.floor((c + quiet) * cell),
						Math.floor((r + quiet) * cell),
						Math.ceil(cell), Math.ceil(cell));
		return true;
	} catch (e) {
		return false;
	}
}

// paintQr(canvas, link): рисует QR и помечает canvas (data-qr-done),
// чтобы не перерисовывать при повторных проходах.
function paintQr(canvas, link) {
	if (!canvas || canvas.getAttribute('data-qr-done'))
		return;
	if (drawQr(canvas, link))
		canvas.setAttribute('data-qr-done', '1');
	else
		canvas.setAttribute('data-qr-done', '0');
}

// qrReady.then: дорисовать всё, что ждало библиотеку.
qrReady.then(function () {
	var all = document.querySelectorAll('canvas[data-qr-link]');
	for (var i = 0; i < all.length; i++)
		paintQr(all[i], all[i].getAttribute('data-qr-link'));
});

// --- разбор vless-ссылки (kv-ключи и uuid не приходят в list —
// берём их из ссылки: pbk/sid/sni общие для всего инбаунда) ---

function parseVless(link) {
	if (typeof link != 'string' || link.indexOf('vless://') !== 0)
		return null;
	var out = {};
	var rest = link.slice(8);
	var hash = rest.indexOf('#');
	if (hash >= 0)
		rest = rest.slice(0, hash);
	var q = rest.indexOf('?');
	var main = q >= 0 ? rest.slice(0, q) : rest;
	var query = q >= 0 ? rest.slice(q + 1) : '';
	var at = main.lastIndexOf('@');
	if (at >= 0)
		out.uuid = main.slice(0, at);
	var hostport = at >= 0 ? main.slice(at + 1) : main;
	var ci = hostport.lastIndexOf(':');
	if (ci >= 0) {
		out.host = hostport.slice(0, ci);
		out.port = hostport.slice(ci + 1);
	} else {
		out.host = hostport;
	}
	var pairs = query.split('&');
	for (var i = 0; i < pairs.length; i++) {
		var e = pairs[i].indexOf('=');
		if (e < 0)
			continue;
		try {
			out[pairs[i].slice(0, e)] = decodeURIComponent(pairs[i].slice(e + 1));
		} catch (err) {
			out[pairs[i].slice(0, e)] = pairs[i].slice(e + 1);
		}
	}
	return out;
}

// --- своя модалка (blur-фон + анимация) ---

// openModal(contentNode) -> функция close(). Клик по фону закрывает.
// ВАЖНО: модалка вешается в document.body — ВНЕ .sb-page, где определены
// CSS-переменные темы. Поэтому .modal-back несёт их копию сам.
function openModal(contentNode) {
	var back = E('div', {
		'class': 'modal-back',
		'style': [
			'--font:"Inter","Segoe UI",system-ui,sans-serif',
			'--mono:ui-monospace,"JetBrains Mono",Consolas,monospace',
			'--radius:16px;--radius-sm:11px',
			'--surface:#ffffff;--surface-2:#F5F6FA;--surface-3:#ECEEF4',
			'--border:#D4D9E6;--border-2:#B9C0D0',
			'--text:#1A2030;--text-2:#3D4657;--muted:#5B6472',
			'--accent:#1D4ED8;--accent-hi:#2563EB;--accent-ring:rgba(37,99,235,.22)',
			'--ok:#15803D;--ok-bg:#E7F6EC;--ok-dot:#16A34A',
			'--off:#6B7484;--off-bg:#EFF1F5',
			'--bad:#B4232A;--bad-bg:#FBEAEA'
		].join(';') + ';font-family:var(--font)'
	}, [
		E('div', { 'class': 'modal' }, [ contentNode ])
	]);
	function close() {
		back.classList.remove('show');
		window.setTimeout(function () { back.remove(); }, 200);
	}
	back.addEventListener('click', function (ev) {
		if (ev.target === back)
			close();
	});
	document.body.appendChild(back);
	/* появление — следующим тиком, чтобы transition успел сыграть */
	window.setTimeout(function () { back.classList.add('show'); }, 10);
	return close;
}

// textField(label, value, hint, readonly) -> узел .field с input внутри.
function textField(label, value, hint, readonly) {
	var attrs = { 'type': 'text' };
	if (readonly)
		attrs['readonly'] = 'readonly';
	var input = E('input', attrs);
	input.value = value || '';
	var field = E('div', { 'class': 'field' }, [
		E('label', {}, label),
		input
	]);
	if (hint)
		field.appendChild(E('div', { 'class': 'hint' }, hint));
	field._input = input;
	return field;
}

return view.extend({
	load: function () {
		// uci нужен для дефолта SNI модалки создания (global.sni);
		// паттерн: uci.load + catch на «конфига нет».
		return Promise.all([
			callStatus().catch(function () {
				return { running: false, version: '', inbounds: 0, next_port: 0, next_vip: '' };
			}),
			// ВАЖНО: callList объявлен с
			// expect {inbounds: []} — rpc.declare сам распаковывает
			// поле inbounds и резолвит МАССИВОМ. Прежний код искал
			// (data[1]||{}).inbounds — .inbounds у массива => undefined
			// => вечно пустой список. Фикс: data[1] УЖЕ список, catch-стаб
			// тоже массив.
			callList().catch(function () {
				return [];
			}),
			uci.load('singbounds').catch(function () { return null; })
		]).then(function (data) {
			return { status: data[0] || {}, list: Array.isArray(data[1]) ? data[1] : [] };
		});
	},

	render: function (data) {
		var status = data.status || {};
		var inbounds = data.list || [];

		// Дефолт SNI модалки: global.sni из uci (пример: vk.com),
		// отсутствие — DEFAULT_SNI.
		var sniDefault = uci.get('singbounds', 'global', 'sni') || 'www.cloudflare.com';

		// Самодостаточные стили: один <style> в корне нашей страницы.
		// :host не сработает (мы не в shadow-DOM), поэтому переменные
		// дублируем на корневом контейнере классом .sb-page.
		var style = E('style', { 'type': 'text/css' });
		style.textContent = CSS;

		var root = E('div', { 'class': 'sb-page', 'style': [
			'font-family:var(--font)',
			'--font:"Inter","Segoe UI",system-ui,sans-serif',
			'--mono:ui-monospace,"JetBrains Mono",Consolas,monospace',
			'--radius:16px;--radius-sm:11px',
			'--surface:#ffffff;--surface-2:#F5F6FA;--surface-3:#ECEEF4',
			'--border:#D4D9E6;--border-2:#B9C0D0',
			'--text:#1A2030;--text-2:#3D4657;--muted:#5B6472',
			'--accent:#1D4ED8;--accent-hi:#2563EB;--accent-ring:rgba(37,99,235,.22)',
			'--ok:#15803D;--ok-bg:#E7F6EC;--ok-dot:#16A34A',
			'--off:#6B7484;--off-bg:#EFF1F5',
			'--bad:#B4232A;--bad-bg:#FBEAEA'
		].join(';') });

		root.appendChild(style);

		// --- шапка: заголовок, подзаголовок, живой бейдж статуса ---
		var badge = E('span', { 'class': 'st-badge' });

		function renderBadge(st) {
			st = st || {};
			badge.className = 'st-badge ' + (st.running ? 'on' : 'off');
			while (badge.firstChild)
				badge.removeChild(badge.firstChild);
			badge.appendChild(E('span', { 'class': 'dot' }));
			badge.appendChild(document.createTextNode(st.running
				? 'sing-box %s · работает'.format(st.version || '?')
				: 'остановлен'));
		}

		renderBadge(status);

		root.appendChild(E('div', { 'class': 'bar' }, [
			E('div', {}, [
				E('h1', {}, 'sing-bounds'),
				E('div', { 'class': 'sub' }, 'VPN-сервер на вашем роутере')
			]),
			badge
		]));

		// --- табы + контент-контейнеры ---
		var tabButtons = {};
		var tabPanes = {};

		var tabsBar = E('div', { 'class': 'tabs' });
		var content = E('div', {});

		function activateTab(id, updateHash) {
			for (var i = 0; i < TABS.length; i++) {
				var t = TABS[i];
				if (t.id == id) {
					tabButtons[t.id].classList.add('active');
					tabPanes[t.id].style.display = 'block';
				} else {
					tabButtons[t.id].classList.remove('active');
					tabPanes[t.id].style.display = 'none';
				}
			}
			if (updateHash !== false) {
				try { document.location.hash = '#' + id; } catch (e) { /* нет hash — не страшно */ }
			}
		}

		for (var i = 0; i < TABS.length; i++) {
			(function (tab) {
				tabButtons[tab.id] = E('button', {
					'class': 'tab',
					'type': 'button',
					'click': function () { activateTab(tab.id); }
				}, tab.title);

				// «Настройки»/«Система» рендерятся в render().
				tabPanes[tab.id] = E('div', {
					'class': 'sb-pane sb-pane-%s'.format(tab.id),
					'style': 'display:none'
				});

				tabsBar.appendChild(tabButtons[tab.id]);
				content.appendChild(tabPanes[tab.id]);
			}).call(this, TABS[i]);
		}

		root.appendChild(tabsBar);
		root.appendChild(content);

		var overviewPane = tabPanes['overview'];
		var inboundsPane = tabPanes['inbounds'];

		// ------------------------------------------------------------------
		// Данные и перезагрузка.
		//
		// Состояние: status + list + links-пакеты по инбаундам. get_links
		// зовём ЕДИНожды на инбаунд за перезагрузку: список отдаёт только
		// id/имена/порты, а uuid/pbk/sid/sni фронту нужны для kv, строк
		// клиентов и QR — всё это есть в vless-ссылке (парсим на месте,
		// лишних методов не добавляем). host в get_links кэширован в UCI,
		// так что вызов дешёвый. После КАЖДОЙ мутации — полный refresh
		// (бэкенд пересобирает конфиг; «оптимистичный» список врал бы).
		// ------------------------------------------------------------------

		var linksByInbound = {}; /* id -> { links: [...] } | null */
		var openInboundIds = {}; /* раскрытые аккордеоны переживают refresh */
		var tscState = null; /* статус Tailscale-туннеля (null = не настроен) */

		function fetchLinks(list) {
			var tasks = [];
			for (var i = 0; i < list.length; i++)
				(function (inb) {
					tasks.push(
						callGetLinks(inb.id).then(function (r) {
							return { links: (r || {}).links || [] };
						}, function () {
							return null; /* ошибка get_links не валит страницу */
						})
					);
				})(list[i]);
			return Promise.all(tasks);
		}

		function refresh() {
			return withBusy(
				Promise.all([
					callStatus().catch(function () { return {}; }),
					// см. фикс load(): callList резолвит МАССИВОМ
					// (expect {inbounds: []} распакован rpc-слоем).
					callList().catch(function () { return []; })
				]).then(function (res) {
					var st = res[0] || {};
					var list = Array.isArray(res[1]) ? res[1] : [];
					// Tailscale-статус подгружаем параллельно со ссылками;
					// ошибка не валит страницу (tscState остаётся прежним).
					return Promise.all([
						fetchLinks(list),
						callTscStatus().catch(function () { return null; })
					]).then(function (r2) {
						var linksArr = r2[0];
						tscState = r2[1];
						linksByInbound = {};
						for (var k = 0; k < list.length; k++)
							linksByInbound[list[k].id] = linksArr[k];
						renderBadge(st);
						renderOverview(st, list);
						renderInboundsPane(st, list);
					});
				}),
				'Обновляю…');
		}

		// ------------------------------------------------------------------
		// ТАБ «ОБЗОР»: 4 стата + карточка «Быстрое подключение».
		// ------------------------------------------------------------------

		function renderOverview(st, list) {
			while (overviewPane.firstChild)
				overviewPane.removeChild(overviewPane.firstChild);

			var inbTotal = list.length;
			var inbOn = 0;
			var clTotal = 0;
			var clOn = 0;
			for (var i = 0; i < list.length; i++) {
				if (list[i].enabled)
					inbOn = inbOn + 1;
				var cls = list[i].clients || [];
				for (var j = 0; j < cls.length; j++) {
					clTotal = clTotal + 1;
					if (cls[j].enabled)
						clOn = clOn + 1;
				}
			}

			overviewPane.appendChild(E('div', { 'class': 'stats' }, [
				E('div', { 'class': 'stat' }, [
					E('div', { 'class': 'stat-num' }, String(inbOn)),
					E('div', { 'class': 'stat-label' }, 'Инбаунды'),
					E('div', { 'class': 'stat-sub' }, 'включено из %d'.format(inbTotal))
				]),
				E('div', { 'class': 'stat' }, [
					E('div', { 'class': 'stat-num' }, String(clOn)),
					E('div', { 'class': 'stat-label' }, 'Клиенты'),
					E('div', { 'class': 'stat-sub' }, 'включено из %d'.format(clTotal))
				]),
				E('div', { 'class': 'stat' }, [
					E('div', { 'class': 'stat-num' }, st.version || '—'),
					E('div', { 'class': 'stat-label' }, 'sing-box'),
					E('div', { 'class': 'stat-sub' + (st.running ? ' ok' : '') },
						st.running ? 'работает' : 'остановлен')
				]),
				E('div', { 'class': 'stat' }, [
					E('div', { 'class': 'stat-num' }, String(inbTotal)),
					E('div', { 'class': 'stat-label' }, 'VIP-адреса'),
					E('div', { 'class': 'stat-sub' }, '.240–.250 · br-lan')
				])
			]));

			overviewPane.appendChild(renderQuickConnect(list));
		}

		// «Быстрое подключение»: первый ВКЛЮЧЁННЫЙ инбаунд + первый
		// ВКЛЮЧЁННЫЙ клиент его ссылки: большой QR (180px), vless-ссылка,
		// «Копировать ссылку» / «Копировать QR».
		function renderQuickConnect(list) {
			var card = E('div', { 'class': 'card' });
			var body = E('div', { 'class': 'card-body', 'style': 'display:block;border-top:none' });
			card.appendChild(body);

			var chosen = null;
			for (var i = 0; i < list.length && !chosen; i++) {
				if (!list[i].enabled)
					continue;
				var pkg = linksByInbound[list[i].id];
				if (!pkg || !pkg.links || !pkg.links.length)
					continue;
				var cls = list[i].clients || [];
				for (var j = 0; j < cls.length; j++) {
					if (cls[j].enabled && pkg.links[j]) {
						chosen = {
							inbound: list[i],
							client: cls[j],
							link: pkg.links[j].link
						};
						break;
					}
				}
			}

			if (!chosen) {
				body.appendChild(E('div', { 'class': 'qc-title' }, 'Быстрое подключение'));
				body.appendChild(E('p', { 'class': 'hint-empty' },
					'Нет включённого инбаунда с включённым клиентом — включите что-нибудь на вкладке «Инбаунды», и здесь появится QR для подключения.'));
				return card;
			}

			var canvas = E('canvas', { 'width': '360', 'height': '360', 'data-qr-link': chosen.link });
			paintQr(canvas, chosen.link);

			var linkTxt = E('div', { 'class': 'link-txt', 'title': chosen.link }, chosen.link);

			var copyLinkBtn = E('button', {
				'class': 'btn btn-sm',
				'type': 'button',
				'click': function () {
					copyText(chosen.link).then(function (ok) {
						if (ok)
							toast('Ссылка скопирована — отправьте её в мессенджере', true);
						else
							toast('Не удалось скопировать — выделите ссылку вручную', false);
					});
				}
			}, 'Копировать ссылку');

			var copyQrBtn = E('button', {
				'class': 'btn btn-sm',
				'type': 'button',
				'click': function () {
					if (canvas.getAttribute('data-qr-done') != '1') {
						toast('QR ещё не построился — попробуйте через секунду', false);
						return;
					}
					copyCanvasPng(canvas).then(function (ok) {
						if (ok) {
							toast('QR-код скопирован в буфер', true);
						} else if (downloadCanvasPng(canvas, 'sing-bounds-qr.png')) {
							toast('QR сохранён', true);
						} else {
							toast('Не удалось сохранить QR', false);
						}
					});
				}
			}, 'Копировать QR');

			var saveQrBtn = E('button', {
				'class': 'btn btn-sm',
				'type': 'button',
				'click': function () {
					if (downloadQrHiRes(chosen.link, 'sing-bounds-qr.png'))
						toast('QR сохранён: PNG 1080×1080', true);
					else
						toast('Не удалось сохранить QR', false);
				}
			}, 'Скачать QR');

			var actions = E('div', { 'class': 'spacer', 'style': 'margin-top:10px' }, [
				copyLinkBtn, copyQrBtn, saveQrBtn
			]);

			body.appendChild(E('div', { 'class': 'qc' }, [
				E('div', { 'class': 'qc-left' }, [
					E('div', { 'class': 'qr-big' }, [ canvas ])
				]),
				E('div', { 'class': 'qc-right' }, [
					E('div', { 'class': 'qc-title' }, 'Быстрое подключение'),
					E('div', { 'class': 'qc-sub' },
						'«%s» · клиент «%s»'.format(chosen.inbound.name, chosen.client.name)),
					linkTxt,
					actions,
					E('div', { 'class': 'qc-sub', 'style': 'margin-top:12px' },
						'Отсканируйте QR камерой телефона или скопируйте ссылку — v2rayN, Happ и другие приложения распознают её сразу.')
				])
			]));

			return card;
		}

		// ------------------------------------------------------------------
		// ТАБ «ИНБАУНДЫ»: шапка с кнопкой создания + карточки-аккордеоны.
		// ------------------------------------------------------------------

		function renderInboundsPane(st, list) {
			while (inboundsPane.firstChild)
				inboundsPane.removeChild(inboundsPane.firstChild);

			// Шапка таба: подзаголовок слева, btn-primary справа.
			inboundsPane.appendChild(E('div', { 'class': 'bar', 'style': 'margin-bottom:14px' }, [
				E('div', { 'class': 'sub', 'style': 'margin:0' },
					'Подключения к вашему VPN-серверу'),
				E('button', {
					'class': 'btn btn-primary',
					'type': 'button',
					'click': function () { openCreateModal(st); }
				}, 'Создать туннель')
			]));

			// Tailscale-карточка: над VLESS-списком (если настроен).
			if (tscState && tscState.configured)
				inboundsPane.appendChild(renderTscCard());

			if (!list.length) {
				if (!(tscState && tscState.configured))
					inboundsPane.appendChild(E('p', { 'class': 'hint-empty' },
						'Пока ничего нет. Создайте первый туннель — ссылку для близкого человека получите сразу.'));
				return;
			}

			for (var i = 0; i < list.length; i++)
				inboundsPane.appendChild(renderInboundCard(list[i], st));
		}

		// Карточка Tailscale-туннеля: статус, сервер, IP, кнопки
		// «Настроить заново» (открывает ту же модалу типа) / «Выйти» /
		// «Удалить».
		function renderTscCard() {
			var t = tscState || {};
			var running = t.state === 'Running';
			var kindLabel = t.server_kind === 'routerich' ? 'Routerich'
				: t.server_kind === 'custom' ? 'свой сервер'
				: 'Аккаунт Tailscale';

			var card = E('div', { 'class': 'card tsc-card' }, [
				E('div', { 'class': 'card-head', 'style': 'cursor:default' }, [
					E('div', { 'class': 'card-title' }, [
						E('span', { 'class': 'badge ' + (running ? 'ok' : 'warn') },
							running ? 'в сети' : (t.state === 'NeedsLogin' ? 'нужен вход' : (t.state || '—'))),
						E('b', {}, 'Tailscale'),
						E('span', { 'class': 'muted' }, '· mesh-сеть')
					])
				]),
				E('div', { 'class': 'card-body' }, [
					E('div', { 'class': 'kv' }, [
						E('span', {}, 'Сеть'),
						E('b', {}, kindLabel),
						E('span', {}, 'IP в сети'),
						E('b', {}, t.self_ip || '—'),
						E('span', {}, 'Версия'),
						E('b', {}, t.version || '—')
					]),
					running && t.authurl ? E('div', { 'class': 'hint' }, [
						'Вход не завершён: ',
						E('a', { 'href': t.authurl, 'target': '_blank', 'rel': 'noopener' }, 'открыть ссылку входа')
					]) : null,
					E('div', { 'class': 'actions', 'style': 'margin-top:12px' }, [
						E('button', {
							'class': 'btn',
							'type': 'button',
							'click': function () {
								callTscLogin().then(function (r) {
									r = r || {};
									if (r.state === 'Running')
										toast('Tailscale в сети', true);
									else if (r.authurl)
										showTscAuthUrl(r.authurl);
								}).catch(function (e) {
									toast('Не получилось: %s'.format(e && e.message || e), false);
								}).finally(refresh);
							}
						}, 'Переподключить'),
						E('button', {
							'class': 'btn',
							'type': 'button',
							'click': function () {
								withBusy(callTscLogout(), 'Выхожу из сети…')
									.then(function () { toast('Вышел из сети', true); })
									.catch(function (e) { toast('%s'.format(e && e.message || e), false); })
									.finally(refresh);
							}
						}, 'Выйти из сети'),
						E('button', {
							'class': 'btn btn-remove',
							'type': 'button',
							'click': function () {
								openConfirmModal('Удалить Tailscale-туннель',
									'Роутер выйдет из mesh-сети; сервер и ключ будут забыты. Пакет tailscale останется в системе.',
									'Удалить туннель',
									function () {
										callTscRemove().then(function () {
											toast('Tailscale-туннель удалён', true);
										}).catch(function (e) {
											toast('%s'.format(e && e.message || e), false);
										}).finally(refresh);
									});
							}
						}, 'Удалить туннель')
					])
				])
			]);
			return card;
		}

		// Карточка-аккордеон инбаунда.
		function renderInboundCard(inb, st) {
			var on = !!inb.enabled;
			var clients = inb.clients || [];
			var pkg = linksByInbound[inb.id];

			// pbk/sid/sni — из первой ссылки (общие для инбаунда).
			var first = pkg && pkg.links && pkg.links.length ? parseVless(pkg.links[0].link) : null;

			var card = E('div', {
				'class': 'card' + (on ? '' : ' disabled') + (openInboundIds[inb.id] ? ' open' : '')
			});

			var toggleBtn = E('button', {
				'class': 'btn btn-sm',
				'type': 'button',
				'click': function (ev) {
					ev.stopPropagation();
					var next = on ? '0' : '1';
					withBusy(callToggleInbound(inb.id, next), on ? 'Отключаю…' : 'Включаю…')
						.then(function () {
							toast(on
								? 'Инбаунд «%s» отключён (данные сохранены)'.format(inb.name)
								: 'Инбаунд «%s» включён'.format(inb.name), true);
						})
						.catch(function (e) {
							toast('Не получилось: %s'.format(e && e.message || e), false);
						})
						.finally(refresh);
				}
			}, on ? 'Отключить' : 'Включить');

			var head = E('div', { 'class': 'card-head' }, [
				E('div', {}, [
					E('div', { 'class': 'name' }, [
						inb.name || inb.id,
						E('span', { 'class': 'st-badge ' + (on ? 'on' : 'off') }, [
							E('span', { 'class': 'dot' }),
							on ? 'включён' : 'выключен'
						])
					]),
					E('div', { 'class': 'meta' }, [
						E('span', {}, [ 'Порт ', E('b', {}, String(inb.port)) ]),
						E('span', {}, [ 'VIP ', E('b', {}, inb.vip || '—') ]),
						E('span', {}, [ 'SNI ', E('b', {}, first && first.sni ? first.sni : '—') ]),
						E('span', {}, [ 'Клиентов ', E('b', {}, String(clients.length)) ])
					])
				]),
				E('div', { 'class': 'spacer' }, [
					toggleBtn,
					E('span', { 'class': 'chev' }, '▾')
				])
			]);

			head.addEventListener('click', function () {
				card.classList.toggle('open');
				openInboundIds[inb.id] = card.classList.contains('open');
			});

			card.appendChild(head);

			// --- тело: kv-ключи + клиенты + действия ---
			var body = E('div', { 'class': 'card-body' });

			body.appendChild(E('dl', { 'class': 'kv' }, [
				E('dt', {}, 'Public key'),
				E('dd', {}, first && first.pbk ? first.pbk : '—'),
				E('dt', {}, 'Short ID'),
				E('dd', {}, first && first.sid ? first.sid : '—'),
				E('dt', {}, 'Шифрование'),
				E('dd', {}, 'VLESS + Reality · chrome · xtls-rprx-vision')
			]));

			if (!clients.length)
				body.appendChild(E('p', { 'class': 'hint-empty' },
					'Клиентов нет — ссылку не выдать. Добавьте клиента ниже.'));

			for (var c = 0; c < clients.length; c++)
				body.appendChild(renderClientRow(inb, clients[c], c, pkg));

			// «Добавить клиента» + «Удалить инбаунд».
			body.appendChild(E('div', { 'class': 'actions add-client' }, [
				E('button', {
					'class': 'btn',
					'type': 'button',
					'click': function () { openAddClientModal(inb); }
				}, 'Добавить клиента'),
				E('button', {
					'class': 'btn btn-remove',
					'type': 'button',
					'click': function () {
						openConfirmModal(
							'Удалить инбаунд «%s»?'.format(inb.name || inb.id),
							'Будут удалены порт %s, виртуальный адрес %s, все клиенты и firewall-правило. Действие необратимо.'.format(inb.port, inb.vip),
							'Удалить',
							function () {
								return withBusy(callDelInbound(inb.id), 'Удаляю…')
									.then(function () {
										toast('Инбаунд «%s» удалён'.format(inb.name || inb.id), true);
									})
									.catch(function (e) {
										toast('Не удалось удалить: %s'.format(e && e.message || e), false);
									})
									.finally(refresh);
							});
					}
				}, 'Удалить инбаунд')
			]));

			card.appendChild(body);
			return card;
		}

		// Строка клиента: имя+бейдж, uuid, ссылка (переносится по
		// строкам), мини-QR 76px (клик = большой QR в модалке), кнопки.
		// links[j] ↔ clients[j] (get_links маппит по порядку клиентов).
		function renderClientRow(inb, client, idx, pkg) {
			var on = !!client.enabled;
			var link = pkg && pkg.links && pkg.links[idx] ? pkg.links[idx].link : null;
			var v = link ? parseVless(link) : null;

			var row = E('div', { 'class': 'cl-row' + (on ? '' : ' off') });

			var canvas = E('canvas', { 'width': '152', 'height': '152', 'data-qr-link': link || '' });
			if (link)
				paintQr(canvas, link);

			var left = E('div', { 'style': 'flex:1;min-width:0' }, [
				E('div', { 'class': 'cl-name' }, [
					client.name || client.id,
					E('span', { 'class': 'st-badge ' + (on ? 'on' : 'off') }, [
						E('span', { 'class': 'dot' }),
						on ? 'активен' : 'выключен'
					])
				]),
				E('div', { 'class': 'cl-uuid' }, v && v.uuid ? v.uuid : 'uuid недоступен'),
				E('div', { 'class': 'link-line' }, [
					link
						? E('div', { 'class': 'link-txt', 'title': link }, link)
						: E('div', { 'class': 'link-txt' }, 'ссылка недоступна'),
					link
						? E('div', {
							'class': 'qr-box qr-click',
							'title': 'Нажмите — QR откроется крупно',
							'click': function () { showQrModal(link, client.name || client.id); }
						}, [ canvas ])
						: E('div', { 'class': 'qr-box' }, [ document.createTextNode('QR') ])
				])
			]);
			row.appendChild(left);

			var buttons = E('div', { 'class': 'spacer', 'style': 'flex-direction:column;align-items:flex-end' });

			if (link) {
				buttons.appendChild(E('button', {
					'class': 'btn btn-sm',
					'type': 'button',
					'click': function () {
						copyText(link).then(function (ok) {
							if (ok)
								toast('Ссылка «%s» скопирована'.format(client.name || client.id), true);
							else
								toast('Не удалось скопировать — выделите ссылку вручную', false);
						});
					}
				}, 'Копировать ссылку'));

				buttons.appendChild(E('button', {
					'class': 'btn btn-sm',
					'type': 'button',
					'click': function () {
						if (canvas.getAttribute('data-qr-done') != '1') {
							toast('QR ещё не построился — попробуйте через секунду', false);
							return;
						}
						copyCanvasPng(canvas).then(function (ok) {
							if (ok) {
								toast('QR-код скопирован в буфер', true);
							} else if (downloadCanvasPng(canvas, 'sing-bounds-%s.png'.format(client.name || client.id))) {
								toast('QR сохранён', true);
							} else {
								toast('Не удалось сохранить QR', false);
							}
						});
					}
				}, 'Копировать QR'));
			}

			buttons.appendChild(E('button', {
				'class': 'btn btn-sm',
				'type': 'button',
				'click': function () {
					var next = on ? '0' : '1';
					withBusy(callToggleClient(client.id, next), on ? 'Отключаю…' : 'Включаю…')
						.then(function () {
							toast(on
								? 'Клиент «%s» отключён (uuid сохранён)'.format(client.name || client.id)
								: 'Клиент «%s» включён'.format(client.name || client.id), true);
						})
						.catch(function (e) {
							toast('Не получилось: %s'.format(e && e.message || e), false);
						})
						.finally(refresh);
				}
			}, on ? 'Отключить' : 'Включить'));

			buttons.appendChild(E('button', {
				'class': 'btn btn-sm btn-remove',
				'type': 'button',
				'click': function () {
					openConfirmModal(
						'Удалить клиента «%s»?'.format(client.name || client.id),
						'Его ссылка перестанет работать. Конфиг инбаунда будет пересобран.',
						'Удалить',
						function () {
							return withBusy(callDelClient(inb.id, client.id), 'Удаляю…')
								.then(function () {
									toast('Клиент «%s» удалён'.format(client.name || client.id), true);
								})
								.catch(function (e) {
									toast('Не удалось: %s'.format(e && e.message || e), false);
								})
								.finally(refresh);
						});
				}
			}, 'Удалить'));

			row.appendChild(buttons);
			return row;
		}

		// ------------------------------------------------------------------
		// Модалки.
		// ------------------------------------------------------------------

		// confirm-модалка: заголовок, текст,
		// Отмена + красная кнопка; onConfirm возвращает промис — busy.
		function openConfirmModal(title, text, confirmLabel, onConfirm) {
			var confirmBtn = E('button', { 'class': 'btn btn-remove', 'type': 'button' }, confirmLabel);
			var cancelBtn = E('button', { 'class': 'btn', 'type': 'button' }, 'Отмена');
			var close = openModal(E('div', { 'class': 'form' }, [
				E('h3', {}, title),
				E('p', { 'class': 'lead' }, text),
				E('div', { 'class': 'actions' }, [
					cancelBtn,
					confirmBtn
				])
			]));
			cancelBtn.addEventListener('click', close);
			confirmBtn.addEventListener('click', function () {
				close();
				withBusy(Promise.resolve().then(onConfirm), 'Работаю…');
			});
		}

		// Модалка «Новый туннель»: сначала ТИП (VLESS / Tailscale).
		// VLESS: Название, Порт, SNI, VIP, Шифрование -> add_inbound.
		// Tailscale: «Где ваша сеть» (Routerich / Аккаунт Tailscale /
		// Свой сервер) + поля по выбору -> tsc_server + tsc_login.
		// Если Tailscale-туннель уже настроен (UCI-секция есть) — опция
		// типа недоступна: изменить можно в карточке туннеля.
		function openCreateModal(st) {
			st = st || {};
			// Tailscale-туннель уже настроен (UCI-секция) => опция
			// недоступна: один tailscaled = одна сеть; менять — в карточке.
			var tscBusy = !!(tscState && tscState.configured);
			// Пакет ставится вручную в Настройках (флеш может быть мал).
			var tscInstalled = !!(tscState && tscState.installed);

			var vlessFields = E('div', { 'class': 'grid' });
			var tscFields = E('div', { 'class': 'tsc-block', 'style': 'display:none' });

			var fName = textField('Название', '', 'Как в списке');
			var fPort = textField('Порт', st.next_port ? String(st.next_port) : '', 'Свободный порт подобран автоматически');
			var fSni = textField('SNI (маскировка)', sniDefault, 'Обычно менять не нужно');
			var fVip = textField('Виртуальный IP', st.next_vip || '', 'Свободный адрес из .240–.250');
			var fEnc = textField('Шифрование', 'VLESS + Reality', 'Ключи сгенерируются сами', true);
			vlessFields.appendChild(fName);
			vlessFields.appendChild(fPort);
			vlessFields.appendChild(fSni);
			vlessFields.appendChild(fVip);
			vlessFields.appendChild(fEnc);

			// --- Tailscale-часть ---
			// Выбор сети: radio-строки. kind: routerich|official|custom.
			var tscKind = 'routerich';
			var radioRows = E('div', { 'class': 'grid' });

			var fKey = textField('Device Auth Key', '', 'Ключ устройства из панели Routerich');
			var fSrv = textField('Адрес сервера', '', 'Например: https://headscale.example.com');
			var fRoutes = textField('Маршруты LAN (необязательно)', '',
				'CIDR через запятую, например: 192.168.1.0/24');
			fSrv._input.placeholder = 'https://rc.routerich.ru';

			function buildRadioRows() {
				while (radioRows.firstChild)
					radioRows.removeChild(radioRows.firstChild);
				var kinds = [
					{ id: 'routerich', label: 'Routerich', hint: 'Вход по ключу, без аккаунта. Сеть создаётся на remote.routerich.ru — работает из России' },
					{ id: 'official', label: 'Аккаунт Tailscale', hint: 'Вход через Google, Apple, Microsoft или GitHub по ссылке' },
					{ id: 'custom', label: 'Свой сервер', hint: 'Headscale, ionscale или другой совместимый сервер' }
				];
				for (var i = 0; i < kinds.length; i++) {
					(function (k) {
						var row = E('div', {
							'class': 'tsc-opt' + (tscKind === k.id ? ' sel' : ''),
							'click': function () {
								tscKind = k.id;
								syncTscFields();
								buildRadioRows();
							}
						}, [
							E('label', {}, [
								E('input', { 'type': 'radio', 'name': 'tsc-kind', 'checked': tscKind === k.id ? 'checked' : null }),
								E('span', {}, k.label)
							]),
							E('div', { 'class': 'hint' }, k.hint)
						]);
						radioRows.appendChild(row);
					})(kinds[i]);
				}
			}

		function syncTscFields() {
				while (tscFields.firstChild)
					tscFields.removeChild(tscFields.firstChild);				tscFields.appendChild(radioRows);
				if (tscKind === 'routerich') {
					tscFields.appendChild(E('div', { 'class': 'tsc-note' }, [
						'Нет сети? Создайте на ',
						E('a', { 'href': 'https://remote.routerich.ru/create-tailnet', 'target': '_blank', 'rel': 'noopener' }, 'remote.routerich.ru'),
						' и сохраните Device Auth Key.'
					]));
					tscFields.appendChild(fKey);
				} else if (tscKind === 'official') {
					tscFields.appendChild(E('div', { 'class': 'tsc-note' },
						'После подключения панель покажет ссылку — откройте её в браузере и войдите через Google/GitHub.'));
				} else {
					tscFields.appendChild(fSrv);
					tscFields.appendChild(fKey);
				}
				tscFields.appendChild(fRoutes);
				syncCreateBtn();
			}

			var createBtn = E('button', { 'class': 'btn btn-primary', 'type': 'button' }, 'Создать');

			// Переключатель типа: сегментированный контрол из двух кнопок.
			var typeVless = E('button', { 'class': 'btn btn-sm type-sel sel', 'type': 'button' }, 'VLESS + Reality');
			var typeTsc = E('button', {
				'class': 'btn btn-sm type-sel' + (tscBusy || !tscInstalled ? ' disabled' : ''),
				'type': 'button',
				'title': tscBusy
					? 'Tailscale уже настроен — измените его в карточке туннеля'
					: (!tscInstalled ? 'Пакет tailscale не установлен — установите его в Настройках' : ''),
				'click': function () {
					if (tscBusy) {
						toast('Tailscale уже настроен — изменить можно в карточке туннеля на этой вкладке', false);
						return;
					}
					if (!tscInstalled) {
						toast('Пакет tailscale не установлен — сначала установите его в «Настройках» (выбор: память роутера или USB)', false);
						return;
					}
					setType('tsc');
				}
			}, 'Tailscale');

			var currentType = 'vless';
			function setType(t) {
				if (t === 'tsc' && tscBusy)
					return;
				currentType = t;
				typeVless.classList.toggle('sel', t === 'vless');
				typeTsc.classList.toggle('sel', t === 'tsc');
				vlessFields.style.display = t === 'vless' ? '' : 'none';
				tscFields.style.display = t === 'tsc' ? '' : 'none';
				syncCreateBtn();
			}
			typeVless.addEventListener('click', function () { setType('vless'); });

			// Живой disabled: VLESS — пока «Название» пусто; Tailscale —
			// пока не заполнено нужное (ключ Routerich / адрес своего).
			function syncCreateBtn() {
				if (currentType === 'vless') {
					createBtn.disabled = !fName._input.value.trim();
					createBtn.textContent = 'Создать';
				} else {
					createBtn.textContent = 'Подключить';
					if (tscKind === 'routerich')
						createBtn.disabled = fKey._input.value.trim().length < 8;
					else if (tscKind === 'official')
						createBtn.disabled = false;
					else
						createBtn.disabled = !/^https?:\/\/\S+$/.test(fSrv._input.value.trim());
				}
			}
			fName._input.addEventListener('input', syncCreateBtn);
			fKey._input.addEventListener('input', syncCreateBtn);
			fSrv._input.addEventListener('input', syncCreateBtn);
			buildRadioRows();
			syncTscFields();
			syncCreateBtn();

			var cancelBtn = E('button', { 'class': 'btn', 'type': 'button' }, 'Отмена');
			var close = openModal(E('div', { 'class': 'form' }, [
				E('h3', {}, 'Новый туннель'),
				E('div', { 'class': 'lead' },
					'VLESS — инбаунд со ссылкой и QR. Tailscale — mesh-сеть: телефон и роутер находят друг друга через сервер координации.'),
				E('div', { 'class': 'type-bar' }, [ typeVless, typeTsc ]),
				vlessFields,
				tscFields,
				E('div', { 'class': 'actions' }, [
					cancelBtn,
					createBtn
				])
			]));
			cancelBtn.addEventListener('click', close);

			createBtn.addEventListener('click', function () {
				if (currentType === 'vless') {
					var name = fName._input.value.trim();
					if (!name) {
						toast('Введите название — по нему вы узнаете подключение в списке', false);
						return;
					}
					close();
					withBusy(callAddInbound(name, fPort._input.value.trim(), fSni._input.value.trim(), fVip._input.value.trim()), 'Создаю инбаунд…')
						.then(function () {
							toast('Инбаунд «%s» создан: порт открыт, конфиг применён'.format(name), true);
						})
						.catch(function (e) {
							toast('Не получилось: %s'.format(e && e.message || e), false);
						})
						.finally(refresh);
					return;
				}

				// Tailscale: tsc_server (записать сервер+ключ+маршруты,
				// при необходимости пакет доустановится) затем tsc_login.
				var srv = '';
				var key = '';
				if (tscKind === 'routerich') {
					key = fKey._input.value.trim();
				} else if (tscKind === 'custom') {
					srv = fSrv._input.value.trim();
					key = fKey._input.value.trim();
				}
				var routes = fRoutes._input.value.trim();

				close();
				withBusy(
					callTscServer(srv, key, routes).then(function () {
						return callTscLogin();
					}),
					'Подключаю Tailscale…'
				).then(function (r) {
					r = r || {};
					if (r.state === 'Running') {
						toast('Tailscale подключён — роутер в сети', true);
					} else if (r.authurl) {
						showTscAuthUrl(r.authurl);
					} else {
						toast('Сервер не ответил однозначно — смотрите статус в карточке', false);
					}
				}).catch(function (e) {
					toast('Не получилось: %s'.format(e && e.message || e), false);
				}).finally(refresh);
			});
		}

		// Ссылка для браузерного входа Tailscale: модалка с кликабельным
		// URL и кнопкой «Открыть» (target=_blank — окно уже открылось бы).
		function showTscAuthUrl(url) {
			var closeBtn = E('button', { 'class': 'btn', 'type': 'button' }, 'Закрыть');
			var close = openModal(E('div', { 'class': 'form' }, [
				E('h3', {}, 'Вход в сеть Tailscale'),
				E('p', { 'class': 'lead' },
					'Откройте ссылку в браузере и войдите через Google, Apple, Microsoft или GitHub — роутер подключится сам.'),
				E('div', { 'class': 'field' }, [
					E('label', {}, 'Ссылка для входа'),
					E('input', { 'type': 'text', 'readonly': 'readonly', 'value': url, 'style': 'width:100%' })
				]),
				E('div', { 'class': 'actions' }, [
					closeBtn,
					E('a', { 'class': 'btn btn-primary', 'href': url, 'target': '_blank', 'rel': 'noopener' }, 'Открыть')
				])
			]));
			closeBtn.addEventListener('click', close);
		}

		// showQrModal(link, name): большой QR во всю модалку.
		// Отдельный canvas 640×640 (красивый рендер крупно), подпись
		// ссылкой + кнопки «Копировать ссылку» / «Скачать PNG».
		function showQrModal(link, name) {
			var big = E('canvas', { 'width': '640', 'height': '640' });
			paintQr(big, link);

			var closeBtn = E('button', { 'class': 'btn', 'type': 'button' }, 'Закрыть');
			var copyBtn = E('button', {
				'class': 'btn',
				'type': 'button',
				'click': function () {
					copyText(link).then(function (ok) {
						toast(ok
							? 'Ссылка «%s» скопирована'.format(name)
							: 'Не удалось скопировать', ok);
					});
				}
			}, 'Копировать ссылку');
			var dlBtn = E('button', {
				'class': 'btn btn-primary',
				'type': 'button',
				'click': function () {
					if (big.getAttribute('data-qr-done') != '1') {
						toast('QR ещё не построился — попробуйте через секунду', false);
						return;
					}
					if (downloadCanvasPng(big, 'sing-bounds-%s.png'.format(name)))
						toast('QR сохранён: PNG 1080×1080', true);
					else
						toast('Не удалось сохранить QR', false);
				}
			}, 'Скачать PNG');

			var close = openModal(E('div', { 'class': 'form' }, [
				E('h3', { 'style': 'text-align:center' }, 'QR: %s'.format(name)),
				E('div', { 'class': 'qr-big-modal' }, [
					E('div', { 'class': 'qr-view' }, [ big ]),
					E('div', { 'class': 'qr-caption' }, link)
				]),
				E('div', { 'class': 'actions', 'style': 'justify-content:center' }, [
					closeBtn, copyBtn, dlBtn
				])
			]));
			closeBtn.addEventListener('click', close);
		}

		// Модалка «Добавить клиента»: одно поле имени -> add_client.
		function openAddClientModal(inb) {
			var fName = textField('Имя клиента', '', 'Например: Сергей — для себя');
			var addBtn = E('button', { 'class': 'btn btn-primary', 'type': 'button' }, 'Добавить');

			var cancelBtn = E('button', { 'class': 'btn', 'type': 'button' }, 'Отмена');
			var close = openModal(E('div', { 'class': 'form' }, [
				E('h3', {}, 'Добавить клиента'),
				E('div', { 'class': 'lead' },
					'UUID сгенерируется автоматически и сразу попадёт в конфиг инбаунда «%s».'.format(inb.name || inb.id)),
				E('div', { 'class': 'grid' }, [ fName ]),
				E('div', { 'class': 'actions' }, [
					cancelBtn,
					addBtn
				])
			]));
			cancelBtn.addEventListener('click', close);

			addBtn.addEventListener('click', function () {
				var name = fName._input.value.trim();
				if (!name) {
					toast('Введите имя клиента', false);
					return;
				}
				close();
				withBusy(callAddClient(inb.id, name), 'Добавляю клиента…')
					.then(function () {
						toast('Клиент «%s» добавлен — его UUID уже в конфиге'.format(name), true);
					})
					.catch(function (e) {
						toast('Не получилось: %s'.format(e && e.message || e), false);
					})
					.finally(refresh);
			});
		}

		// ------------------------------------------------------------------
		// ТАБ «НАСТРОЙКИ»: SNI по умолчанию, WAN-адрес для ссылок +
		// кнопка «Проверить» → check_wan (строка результата с точкой и мс).
		// Сохранение — LuCI uci-токен (uci.set + uci.save), только
		// global.sni (wan_ip — авто из check_wan, НЕ сохраняем фронтом:
		// бэкенд сам кэширует его в UCI при get_links).
		// ------------------------------------------------------------------

		var settingsPane = tabPanes['settings'];

		function renderSettingsPane() {
			while (settingsPane.firstChild)
				settingsPane.removeChild(settingsPane.firstChild);

			// Текущие значения из uci-стейта, загруженного в load().
			var curSni = uci.get('singbounds', 'global', 'sni') || '';
			var curWan = uci.get('singbounds', 'global', 'wan_ip') || '';

			var fSni = textField('SNI по умолчанию', curSni,
				'Подставляется при создании инбаунда; у созданных не меняется');

			var fWan = textField('WAN-адрес для ссылок', curWan,
				'Адрес, который подставляется в vless-ссылки');
			var fEnc = textField('Шифрование', 'VLESS + Reality', '', true);

			var ipResult = E('div', { 'class': 'ip-result', 'style': 'display:none' });

			var checkBtn = E('button', {
				'class': 'btn ip-check',
				'type': 'button',
				'click': function () {
					ipResult.style.display = 'none';
					withBusy(callCheckWan(), 'Проверяю внешний адрес…')
						.then(function (r) {
							r = r || {};
							if (!r.ip) {
								ipResult.className = 'ip-result err';
								ipResult.style.display = 'flex';
								while (ipResult.firstChild)
									ipResult.removeChild(ipResult.firstChild);
								ipResult.appendChild(E('span', { 'class': 'dot' }));
								ipResult.appendChild(document.createTextNode(
									'не удалось узнать внешний IP'));
								return;
							}
							// Успех: обновляем поле wan_ip найденным значением
							// (сохранение в UCI — дело бэкенда при get_links;
							// фронт только подставляет).
							if (fWan._input.value.trim() != r.ip)
								fWan._input.value = r.ip;
							ipResult.className = 'ip-result ok';
							ipResult.style.display = 'flex';
							while (ipResult.firstChild)
								ipResult.removeChild(ipResult.firstChild);
							ipResult.appendChild(E('span', { 'class': 'dot' }));
							ipResult.appendChild(document.createTextNode(
								'%s — ответ за %d мс'.format(r.ip, r.ms || 0)));
						})
						.catch(function (e) {
							ipResult.className = 'ip-result err';
							ipResult.style.display = 'flex';
							while (ipResult.firstChild)
								ipResult.removeChild(ipResult.firstChild);
							ipResult.appendChild(E('span', { 'class': 'dot' }));
							ipResult.appendChild(document.createTextNode(
								'не удалось узнать внешний IP'));
						});
				}
			}, 'Проверить');

			var saveBtn = E('button', {
				'class': 'btn btn-primary',
				'type': 'button',
				'click': function () {
					var sni = fSni._input.value.trim();

					if (!sni) {
						toast('SNI по умолчанию не может быть пустым', false);
						return;
					}

					// uci-токен LuCI: set → save
					// (токен уже выдан 'require uci' + load('singbounds')).
					uci.set('singbounds', 'global', 'sni', sni);
					uci.save()
						.then(function () {
							toast('Настройки сохранены', true);
							// sniDefault (дефолт модалки создания) должен
							// подхватить новое значение без перезагрузки
							// страницы — обновляем переменную замыкания.
							sniDefault = sni;
						})
						.catch(function (e) {
							toast('Не удалось сохранить: %s'.format(e && e.message || e), false);
						});
				}
			}, 'Сохранить');

			settingsPane.appendChild(E('div', { 'class': 'card' }, [
				E('div', { 'class': 'form' }, [
					E('h3', {}, 'Общие'),
					E('div', { 'class': 'lead' },
						'Значения по умолчанию для новых инбаундов.'),
					E('div', { 'class': 'grid' }, [ fSni, fEnc ]),
					E('div', { 'class': 'ip-row' }, [
						fWan,
						checkBtn
					]),
					ipResult,
					E('div', { 'class': 'actions' }, [ saveBtn ])
				])
			]));

			// Карточка «Tailscale»: пакет ставится ЗДЕСЬ, вручную, с
			// выбором места (память роутера / USB). Модала создания
			// туннеля пакет не ставит — 26 МБ не всегда влезают во флеш.
			// ВАЖНО: render() исполняется до вставки root в DOM —
			// getElementById здесь НЕ работает. Держим прямую ссылку.
			var tscBody = E('div', { 'class': 'tsc-install-body' });
			settingsPane.appendChild(E('div', { 'class': 'card' }, [
				E('div', { 'class': 'form' }, [
					E('h3', {}, 'Tailscale (пакет)'),
					E('div', { 'class': 'lead' },
						'Пакет нужен для mesh-туннелей. Установка ~26 МБ: во флеш роутера может не влезть — тогда выберите USB-носитель.'),
					tscBody
				])
			]));

			// Тело карточки грузится асинхронно (install_info с роутера);
			// ошибка не тихая — подсказка в карточке.
			callTscInstallInfo().then(function (info) {
				renderTscInstallBody(tscBody, info || {});
			}).catch(function (e) {
				tscBody.appendChild(E('p', { 'class': 'hint' },
					'Не удалось получить информацию о месте на роутере: %s'.format(e && e.message || e)));
			});
		}

		// Тело карточки установки Tailscale: статус + выбор места + кнопка.
		function renderTscInstallBody(container, info) {
			while (container.firstChild)
				container.removeChild(container.firstChild);

			var freeMb = Math.round((info.free_kb || 0) / 1024);
			var needMb = Math.round((info.need_kb || 26624) / 1024);
			var usbList = Array.isArray(info.usb) ? info.usb : [];

			if (info.installed) {
				container.appendChild(E('div', { 'class': 'kv', 'style': 'margin-bottom:0' }, [
					E('span', { 'class': 'st-badge on' }, 'установлен'),
					E('span', { 'class': 'hint' },
						'Версия: ' + (tscState && tscState.version ? tscState.version : 'tailscale'))
				]));
				return;
			}

			// Выбор места установки: память роутера / USB-точки.
			var where = info.space_ok ? 'overlay' : (usbList.length ? 'usb:' + usbList[0].mnt : 'overlay');

			var optOverlay = E('div', {
				'class': 'tsc-opt' + (where === 'overlay' ? ' sel' : ''),
				'click': function () {
					where = 'overlay';
					optOverlay.classList.add('sel');
					usbOpts.forEach(function (o) { o.classList.remove('sel'); });
					syncInstallBtn();
				}
			}, [
				E('label', {}, [
					E('input', { 'type': 'radio', 'name': 'tsc-where', 'checked': where === 'overlay' ? 'checked' : null }),
					E('span', {}, 'Память роутера')
				]),
				E('div', { 'class': 'hint' },
					'Свободно %d МБ · нужно ~%d МБ%s'.format(
						freeMb, needMb,
						info.space_ok ? '' : ' — не хватит места'))
			]);

			var usbOpts = [];
			for (var i = 0; i < usbList.length; i++) {
				(function (u) {
					var opt = E('div', {
						'class': 'tsc-opt' + (where === 'usb:' + u.mnt ? ' sel' : ''),
						'click': function () {
							where = 'usb:' + u.mnt;
							opt.classList.add('sel');
							optOverlay.classList.remove('sel');
							usbOpts.forEach(function (o) { if (o !== opt) o.classList.remove('sel'); });
							syncInstallBtn();
						}
					}, [
						E('label', {}, [
							E('input', { 'type': 'radio', 'name': 'tsc-where', 'checked': where === 'usb:' + u.mnt ? 'checked' : null }),
							E('span', {}, 'USB: %s'.format(u.mnt))
						]),
						E('div', { 'class': 'hint' }, u.dev)
					]);
					usbOpts.push(opt);
				})(usbList[i]);
			}

			if (!usbList.length)
				container.appendChild(E('div', { 'class': 'tsc-note' },
					'USB-носитель не найден. Подключите флешку (ext4/f2fs), чтобы появится выбор установки на неё.'));

			var installBtn = E('button', { 'class': 'btn btn-primary', 'type': 'button' }, 'Установить пакет');

			function syncInstallBtn() {
				installBtn.disabled = (where === 'overlay' && !info.space_ok);
				installBtn.title = installBtn.disabled
					? 'Недостаточно места в памяти роутера — нужен USB-носитель' : '';
			}
			syncInstallBtn();

			installBtn.addEventListener('click', function () {
				var label = where === 'overlay'
					? 'Память роутера' : 'USB (%s)'.format(where.slice(4));
				openConfirmModal('Установить пакет tailscale',
					'Пакет (~26 МБ) будет установлен: %s. Скачивание может занять пару минут.'.format(label),
					'Установить',
					function () {
						withBusy(callTscInstall(where), 'Устанавливаю tailscale…')
							.then(function () {
								toast('tailscale установлен — можно создавать Tailscale-туннель', true);
							})
							.catch(function (e) {
								toast('Не получилось: %s'.format(e && e.message || e), false);
							})
							.finally(refresh);
					});
			});

			var block = E('div', { 'class': 'tsc-block' });
			block.appendChild(optOverlay);
			usbOpts.forEach(function (o) { block.appendChild(o); });
			container.appendChild(block);
			container.appendChild(E('div', { 'class': 'actions' }, [ installBtn ]));
		}

		// ------------------------------------------------------------------
		// ТАБ «СИСТЕМА»: kv — Версия (sing-box <status.version>),
		// Конфигурация (/etc/sing-bounds/config.json), Uptime (ubus
		// system info); кнопки «Перезапустить сервис» (rpc-метод restart)
		// и «Удалить sing-bounds» (uninstall, red, confirm).
		// ------------------------------------------------------------------

		var systemPane = tabPanes['system'];

		// fmtUptime(sec) -> «2 ч 14 мин» / «5 мин» / «3 д 4 ч».
		function fmtUptime(sec) {
			sec = Math.max(0, Math.floor(sec || 0));
			var d = Math.floor(sec / 86400);
			var h = Math.floor((sec % 86400) / 3600);
			var m = Math.floor((sec % 3600) / 60);
			if (d > 0)
				return '%d д %d ч'.format(d, h);
			if (h > 0)
				return '%d ч %d мин'.format(h, m);
			return '%d мин'.format(m);
		}

		function renderSystemPane() {
			while (systemPane.firstChild)
				systemPane.removeChild(systemPane.firstChild);

			// Живой uptime через ubus system info (стандартный объект,
			// ACL на него в LuCI-базе уже есть); сбои — «—».
			var uptimeTxt = '—';
			callSystemInfo().then(function (info) {
				var el = systemPane.querySelector('[data-uptime]');
				if (el && info && info.uptime)
					el.textContent = fmtUptime(info.uptime);
			}).catch(function () { /* uptime недоступен — оставляем «—» */ });

			systemPane.appendChild(E('div', { 'class': 'card' }, [
				E('div', { 'class': 'form' }, [
					E('h3', {}, 'Сервис'),
					E('dl', { 'class': 'kv', 'style': 'margin:0' }, [
						E('dt', {}, 'Версия'),
						E('dd', {}, 'sing-bounds 1.1 · sing-box %s'.format(status.version || '?')),
						E('dt', {}, 'Конфигурация'),
						E('dd', {}, '/etc/sing-bounds/config.json'),
						E('dt', {}, 'Uptime'),
						E('dd', { 'data-uptime': '1' }, uptimeTxt)
					]),
					E('div', { 'class': 'actions', 'style': 'justify-content:flex-start' }, [
						E('button', {
							'class': 'btn',
							'type': 'button',
							'click': function () {
								withBusy(callRestart(), 'Перезапускаю сервис…')
									.then(function () {
										toast('Сервис перезапущен', true);
									})
									.catch(function (e) {
										toast('Не удалось перезапустить: %s'.format(e && e.message || e), false);
									})
									.finally(refresh);
							}
						}, 'Перезапустить сервис'),
						E('button', {
							'class': 'btn btn-remove',
							'type': 'button',
							'click': function () {
								openConfirmModal(
									'Удалить sing-bounds?',
									'Удалит всё: инбаунды, клиентов, файлы. Действие необратимо.',
									'Удалить',
									function () {
										return withBusy(callUninstall(), 'Удаляю…')
											.then(function () {
												toast('sing-bounds удалён', true);
											})
											.catch(function (e) {
												toast('Не удалось удалить: %s'.format(e && e.message || e), false);
											})
											.finally(function () {
												// ubus-объект исчезает при rpcd
												// reload: refresh даст ошибку —
												// тихо уходим на статус-страницу.
												window.location.href = '/cgi-bin/luci/admin/status/overview';
											});
									});
							}
						}, 'Удалить sing-bounds')
					])
				])
			]));
		}

		// --- первичный рендер табов Обзор/Инбаунды/Настройки/Система ---
		renderOverview(status, inbounds);
		renderInboundsPane(status, inbounds);
		renderSettingsPane();
		renderSystemPane();

		// Начальная вкладка: из hash (#overview/#inbounds/…), иначе обзор.
		var initial = (document.location.hash || '').replace(/^#/, '');
		var known = false;
		for (var k = 0; k < TABS.length; k++)
			if (TABS[k].id == initial)
				known = true;
		activateTab(known ? initial : 'overview', known);

		// ВАЖНО: первичный render() рисует карточки из данных load(),
		// где linksByInbound ещё пуст ({}) — pbk/sid «—», ссылка
		// «недоступна». Догружаем ссылки сразу после первичной отрисовки.
		refresh();

		// Убираем СТАНДАРТНУЮ LuCI-панель «Применить/Сохранить/Очистить»:
		// наш view делает все мутации через ubus без UCI-apply, панель
		// бессмысленна.
		// Скрываем ТОЛЬКО на нашей странице: класс на body-странице LuCI
		// не трогаем, чистим контейнер #view + хвост .main-right/.container.
		try {
			var killLuCIActions = function () {
				// Панель рендерится НЕ внутри root — ищем в родительском
				// контейнере после того, как LuCI вставил наш root в #view.
				var host = root.parentNode;
				if (!host)
					return;
				// Классический LuCI: .cbi-page-actions с .cbi-button-apply/…
				var doc = host.ownerDocument || document;
				var page = doc.getElementById('view') || doc.body;
				var bars = page.querySelectorAll('.cbi-page-actions');
				for (var i = 0; i < bars.length; i++)
					bars[i].classList.add('sb-page-actions-none');
				// mobile-вариант: плавающий .cbi-floating-scroll
				var floats = page.querySelectorAll('.main-right');
				for (var j = 0; j < floats.length; j++) { /* noop */ }
			};
			// root ещё не вставлен в DOM (LuCI вставит после return):
			// планируем на следующий тик И после load-события.
			window.setTimeout(killLuCIActions, 0);
			window.setTimeout(killLuCIActions, 300);
		} catch (e) { /* панель не найдена — не страшно */ }

		return root;
	}
});

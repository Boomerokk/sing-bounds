// Полная проверка loadState + renderConfig на синтетическом UCI-конфиге.
'use strict';

push(REQUIRE_SEARCH_PATH, './lib/*.uc');
push(REQUIRE_SEARCH_PATH, '../files/backend/*.uc');

let nb = require('netbounds');
let state = nb.loadState();

let failures = 0;
function check(name, ok, detail) {
	if (ok) printf('ok %s\n', name);
	else { failures++; printf('FAIL %s: %s\n', name, detail ?? ''); }
}

check('global.webui_port', state.global.webui_port == 7789 && type(state.global.webui_port) == 'int', sprintf('%J', state.global));
check('global.sni', state.global.sni == 'www.microsoft.com', sprintf('%J', state.global));
check('1 инбаунд', length(state.inbounds) == 1, sprintf('%d', length(state.inbounds)));
check('inbound.id', state.inbounds[0].id == 'in1', state.inbounds[0].id);
check('inbound.port int', state.inbounds[0].port == 443 && type(state.inbounds[0].port) == 'int', sprintf('%J', state.inbounds[0].port));
check('inbound.vip', state.inbounds[0].vip == '192.168.1.240', state.inbounds[0].vip);
check('2 клиента прикреплены', length(state.inbounds[0].clients) == 2,
	sprintf('%d', length(state.inbounds[0].clients)));
check('клиент c1 у in1', state.inbounds[0].clients[0].id == 'c1',
	sprintf('%J', state.inbounds[0].clients[0]));
check('клиент c2 у in1', state.inbounds[0].clients[1].uuid == '22222222-2222-2222-2222-222222222222',
	sprintf('%J', state.inbounds[0].clients[1]));
// stand_code (тест): опция есть в синтетическом конфиге (run-local.sh
// пишет 'a1b2c3d4e5f6') — loadState обязан её отдать; renderConfig его
// не использует, golden не меняется.
check('inbound.stand_code читается', state.inbounds[0].stand_code == 'a1b2c3d4e5f6',
	sprintf('%J', state.inbounds[0].stand_code));

// renderConfig из загруженного состояния == golden basic
// (строковое равенство канонического %J-вида, golden — канонический текст)
let cfg = nb.renderConfig(state, state.global);
let golden = trim(require('fs').readfile('golden/config-basic.json') ?? 'null');
check('renderConfig(loadState()) == golden basic', sprintf('%J', cfg) == golden,
	'конфиги различаются');

printf('---\n%d failures\n', failures);
exit(failures > 0 ? 1 : 0);

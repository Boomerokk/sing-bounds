// test-render-cli.uc — тест CLI-рендера (тест): render.uc обязан
// печатать на stdout валидный канонический JSON, байт-в-байт равный
// sprintf('%J', nb.renderConfig(nb.loadState(), ...)) и golden-файлу.
//
// Способ: запускаем render.uc как ДОЧЕРНИЙ процесс ucode (fs.popen) —
// так проверяется именно CLI-контракт (stdout/exit-код), а не внутренности.
// UCI-состояние подложено синтетическим /etc/config/singbounds
// (его готовит run-local.sh ДО запуска этого теста, аналогично
// test-loadstate.uc). Тест работает и на роутере с настоящим uci.so.
//
// popen-заметки (проверено на ucode 0.0.20250529, Alpine):
//   fs.popen(cmd)        -> файл-объект; stderr наследуется (идёт в наш
//                           stderr, НЕ в read), read("all") ждёт EOF;
//   p.close()            -> exit-код команды (int);
//   env для дочери       -> префикс VAR=... в команде: setenv-билтина
//                           в 0.0.20250529 НЕТ (getenv — есть), fs.popen
//                           идёт через sh, поэтому VAR=... работает.
//
// Запуск: из tests/ (пути golden/* и ../files/backend/* относительные),
// НАЧИНАТЬ из run-local.sh (он готовит /etc/config/singbounds).

'use strict';

const fs = require('fs');

let failures = 0;
let checks = 0;

function check(name, ok, detail) {
	checks++;
	if (ok) printf('ok %d %s\n', checks, name);
	else { failures++; printf('FAIL %d %s: %s\n', checks, name, detail ?? '(нет деталей)'); }
}

// --- 1. CLI печатает канонический JSON, равный golden basic ---
// golden/config-basic.json соответствует именно синтетическому состоянию,
// которое готовит run-local.sh (1 инбаунд, 2 клиента, PRIVATE_KEY_1, ...).
let golden = trim(fs.readfile('golden/config-basic.json') ?? '');
check('golden загружен', golden != '', 'файл golden/config-basic.json пуст/отсутствует');

// Локально настоящего uci.so нет: подкладываем заглушку тестов через env
// (render.uc читает SINGBOUNDS_UCI_STUB; значение — ШАБЛОН «*.uc»,
// относительный к cwd процесса: fs.popen наследует cwd теста = tests/,
// поэтому правильное значение — «lib/*.uc», НЕ «tests/lib/*.uc»;
// «голый» каталог без /*.uc require() не сканирует — всё проверено
// на 0.0.20250529). На роутере переменная не задана — render.uc берёт
// настоящий uci из дефолтного REQUIRE_SEARCH_PATH.
let cliCmd = 'SINGBOUNDS_UCI_STUB=lib/*.uc ucode ../files/backend/render.uc';

let p = fs.popen(cliCmd, 'r');
let out = p.read('all');
let rc = p.close();

check('render.uc: exit 0', rc == 0, sprintf('exit=%J', rc));
check('render.uc: stdout не пуст', length(out) > 0, sprintf('len=%d', length(out)));

// trim от завершающего \n; сравнение байт-в-байт.
let got = trim(out);
check('CLI == golden basic (байт-в-байт)', got == golden,
	sprintf('got: %.200s...', got));

// --- 2. stdout — ровно канонический %J + один \n (не «почти JSON») ---
check('CLI завершается ровно одним \\n',
	length(out) == length(got) + 1 && substr(out, length(out) - 1) == '\n',
	sprintf('len(out)=%d, len(golden)=%d', length(out), length(golden)));

// --- 3. внутренняя согласованность: рендер в этой же VM равен CLI ---
// Гоняем renderConfig здесь же (по тому же uci-состоянию — заглушка читает
// /etc/config/singbounds) и сверяем: модуль и CLI не разъехались.
push(REQUIRE_SEARCH_PATH, './lib/*.uc');
push(REQUIRE_SEARCH_PATH, '../files/backend/*.uc');
let nb = require('netbounds');
let state = nb.loadState();
let expect = sprintf('%J', nb.renderConfig(state, state.global)) + '\n';
check('CLI == renderConfig(loadState()) в этой же VM', out == expect,
	'CLI и модуль дают разный вывод');

// --- 4. контракт пустого состояния: exit 1, пустой stdout ---
// Временно уводим /etc/config/singbounds (мы root в run-local.sh,
// файл гарантированно существует) и восстанавливаем.
let uciFile = '/etc/config/singbounds';
let bak = fs.readfile(uciFile);
if (bak != null && fs.unlink(uciFile)) {
	let p2 = fs.popen(cliCmd, 'r');
	let out2 = p2.read('all');
	let rc2 = p2.close();
	check('пустое UCI: exit 1', rc2 == 1, sprintf('exit=%J', rc2));
	check('пустое UCI: stdout пуст', length(trim(out2)) == 0, sprintf('stdout=%J', out2));
	fs.writefile(uciFile, bak);
} else {
	// Не критично на роутере, где конфиг мог не создаваться этим прогоном.
	printf('SKIP: проверка пустого состояния (нет root/файла %s)\n', uciFile);
}

// --- итог ---
printf('---\n%d checks, %d failures\n', checks, failures);
exit(failures > 0 ? 1 : 0);

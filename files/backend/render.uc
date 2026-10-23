// render.uc — тонкий CLI-вход для sing-bounds.
//
// Запуск (после установки на роутере):
//   ucode /usr/lib/sing-bounds/render.uc          -> JSON-конфиг на stdout
//   singbounds-ctl render                         -> то же (обёртка в sh)
//
// Дизайн-решение: выбран ОТДЕЛЬНЫЙ файл-вход, чтобы
// netbounds.uc остался чистым модулем:
//   1) require('netbounds') кэшируется в VM — если netbounds.uc сам
//      станет и модулем, и точкой входа, тестам и WebUI пришлось бы
//      различать «загружен как библиотека» vs «выполняется как CLI»;
//   2) CLI-эффекты (print на stdout, exit-коды) не должны жить в модуле,
//      который переиспользует rpcd-бэкенд;
//   3) install-мэппинг остаётся линейным: файл → путь.
//
// Модуль netbounds и uci-заглушку ищем по шаблонам REQUIRE_SEARCH_PATH:
// на роутере актуальны '/usr/lib/sing-bounds/*.uc' и системный
// '/usr/lib/ucode/*.so' (настоящий uci); локально в тестах раньше
// пушатся './lib/*.uc' (заглушка uci) и '../files/backend/*.uc'.
// НЕ полагаемся на './*.uc' по умолчанию: скрипт может вызываться
// из любого cwd, поэтому явно пушим путь каталога самого файла
// (sourcepath() — путь текущего исходника; при запуске `ucode render.uc`
// это /usr/lib/sing-bounds/render.uc, и рядом лежит netbounds.uc).
//
// Контракт:
//   stdout — канонический %J-JSON (sprintf('%J',
//            renderConfig(...)), завершающий \n);
//   stderr — диагностика ошибок (через fs.stderr — fprintf в ucode НЕТ,
//            только print/printf в stdout; проверено на 0.0.20250529);
//   exit 0 — успех; 1 — пустое состояние (нет ни одного инбаунда —
//            стартовать sing-box не с чем); 2 — ошибка рендера.

'use strict';

// Каталог текущего файла без хвостового '/' (объявлен ДО использования —
// в ucode нет hoisting'а функций: вызов до объявления = Reference error,
// проверено на 0.0.20250529). fs.dirname даёт '' для пути без каталога;
// нормализуем в '.'.
function sourcepath_dir() {
	const fs = require('fs');
	let dir = fs.dirname(sourcepath());
	return (dir == '' || dir == null) ? '.' : dir;
}

push(REQUIRE_SEARCH_PATH, sourcepath_dir() + '/*.uc');
// uci: на роутере настоящий /usr/lib/ucode/uci.so уже в дефолтном
// REQUIRE_SEARCH_PATH. Локально же (WSL/Alpine, тесты CLI) настоящего
// uci.so НЕТ; заглушку тестов подкладываем через env
// SINGBOUNDS_UCI_STUB=<шаблон-каталог> (getenv — core-builtin ucode;
// проверено на 0.0.20250529: getenv есть, setenv — нет). Шаблон обязан
// оканчиваться на /*.uc — «голый» путь-каталог require() не сканирует.
if (getenv('SINGBOUNDS_UCI_STUB') != null)
	push(REQUIRE_SEARCH_PATH, getenv('SINGBOUNDS_UCI_STUB'));

let nb = require('netbounds');

let state = nb.loadState();

// Пустое состояние (нет конфига /etc/config/singbounds или нет инбаундов) —
// это НЕ «успешный пустой рендер»: sing-box check провалится или, хуже,
// запустится конфиг-пустышка. Явный отказ с понятным кодом 1 — init-скрипт
// тогда уйдёт в rollback-ветку и оставит старый конфиг в покое.
if (length(state.inbounds) == 0) {
	// fprintf — НЕ builtin ucode (Reference error на 0.0.20250529):
	// пишем в stderr через fs.stderr (файл-объект потока).
	const fs = require('fs');
	fs.stderr.write('render: нет инбаундов в /etc/config/singbounds (state пуст)\n');
	exit(1);
}

print(sprintf('%J', nb.renderConfig(state, state.global)));
print('\n');
exit(0);

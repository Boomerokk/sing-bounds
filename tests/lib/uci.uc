// uci.uc — заглушка uci-модуля для локального прогона тестов (см. tests/run-local.sh).
// Реальный uci.so есть только на OpenWrt (libuci): в не-OpenWrt сборках ucode
// этого модуля нет. Файл подмешивается в REQUIRE_SEARCH_PATH (шаблон ./lib/*.uc)
// ПЕРЕД netbounds.uc и перехватывает require('uci') внутри netbounds.uc.
//
// Заглушка — СКРИПТ-модуль для require(): без export, с top-level return
// (экспорты работают только при import, а netbounds.uc грузится через require).

// Зависимости берём require()-ом: скрипт-модуль для require() не может
// использовать статический import (не резолвится), а сам файл требует fs.
const fs = require('fs');
const readfile = fs.readfile;

// Упрощённый UCI-парсер (подмножество формата /etc/config/...):
//   config global 'global'
//       option webui_port '7789'
//   ...
function parse_ucifile(path) {
	let text = readfile(path);
	let sections = [];
	let current = null;

	for (let line in (text ? split(text, "\n") : [])) {
		line = trim(line);
		if (length(line) == 0 || substr(line, 0, 1) == '#')
			continue;

		let m = match(line, regexp('^config[ \t]+([^ \t]+)[ \t]*\'?([^\']*)\'?[ \t]*$'));
		if (m) {
			current = {
				'.type': m[1],
				'.name': length(m[2]) > 0 ? m[2] : ('cfg' + length(sections)),
				'.anonymous': length(m[2]) == 0
			};
			push(sections, current);
			continue;
		}

		m = match(line, regexp('^option[ \t]+([^ \t]+)[ \t]+\'([^\']*)\''));
		if (m == null)
			m = match(line, regexp('^option[ \t]+([^ \t]+)[ \t]+"([^"]*)"'));
		if (m == null)
			m = match(line, regexp('^option[ \t]+([^ \t]+)[ \t]+([^ \t]+)'));
		if (m && current)
			current[m[1]] = m[2];
	}

	return sections;
}

return {
	cursor: function(config_dir, delta_dir, config2_dir) {
		let dir = config_dir ?? '/etc/config';
		return {
			get: (config, section, option) => null,
			get_all: (config, section) => null,
			foreach: function(config, type, cb) {
				let sections = parse_ucifile(dir + '/' + config);
				if (sections == null)
					return null;

				let invoked = false;
				for (let s in sections) {
					if (type != null && s['.type'] != type)
						continue;
					cb(s);
					invoked = true;
				}
				return invoked;
			}
		};
	}
};

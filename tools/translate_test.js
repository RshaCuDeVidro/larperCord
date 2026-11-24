#!/usr/bin/env node
// Teste do editor de traduções do site (docs/assets/site/translate-core.js, o mesmo arquivo
// que a página usa): o leitor de .kdl e a checagem dos marcadores precisam concordar com
// tools/i18n_strings.py (que segue src/ui/i18n.zig) em cada entrada de cada i18n/*.kdl, e o
// .kdl que o editor baixa volta igual quando é lido de novo.
//
//   node tools/translate_test.js
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const { spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const C = require(path.join(ROOT, "docs/assets/site/translate-core.js"));

let passed = 0;
const failures = [];
function test(name, fn) {
  try {
    fn();
    passed++;
  } catch (e) {
    failures.push([name, e]);
  }
}

const py = spawnSync("python3", [path.join(ROOT, "tools/i18n_strings.py"), "--json"], { encoding: "utf8", maxBuffer: 64 << 20 });
if (py.status !== 0) {
  console.error(py.stderr);
  process.exit(1);
}
const REF = JSON.parse(py.stdout);
const FMT = new Set(REF.fmt);
const rules = { ru: { forms: ["one", "few", "many"] }, ja: { forms: ["other"] }, de: { forms: ["one", "other"] } };

test("marcadores: os mesmos casos de src/ui/i18n.zig", () => {
  const english = "{s} reacted with {s} to {d} messages";
  for (const ok of ["{s}さんが{s}で{d}件に反応", "{2}件に{0}さんが{1}で反応 {{ok}}", "{1}{1}{0}{2}"]) assert.strictEqual(C.checkTemplate(ok, english), null, ok);
  for (const bad of ["{s}さんが反応", "{s}{s}{d}{d}", "{s}{d}{d}", "{0}{s}{d}", "{s}{s}{d} }", "{0}{1}{3}", "{0}{1}"]) assert.notStrictEqual(C.checkTemplate(bad, english), null, bad);
  assert.strictEqual(C.checkTemplate("ok {{}}", "fine {{}}"), null);
  assert.notStrictEqual(C.checkTemplate("{0}", "fine"), null);
  // Um texto que o app nunca traduz (argumento com nome): nada a conferir.
  assert.strictEqual(C.checkTemplate("{x}", "com nome {[x]s}"), null);
});

test("marcadores: igual ao tools/i18n_strings.py em cada tradução de i18n/*.kdl", () => {
  let n = 0;
  for (const [key, text, why] of REF.checks) {
    const js = C.checkTemplate(text, key);
    assert.strictEqual(js === null, why === null, `${key} -> ${text}: python ${why}, js ${js}`);
    n++;
  }
  assert.ok(n > 500, "poucas traduções conferidas: " + n);
});

test("leitor: cada i18n/*.kdl abre com o cabeçalho e as entradas que o python acha", () => {
  for (const [name, info] of Object.entries(REF.files)) {
    const f = C.parseKdl(fs.readFileSync(path.join(ROOT, "i18n", name), "utf8"));
    assert.strictEqual(f.header.code, info.code, name);
    assert.strictEqual(f.header.language, info.name, name);
    assert.strictEqual(f.entries.length, info.entries, name);
    assert.strictEqual(f.entries.filter((e) => e.dropped).length, info.dropped, name);
  }
});

test("leitor: plural, /-, cabeçalho e erros com a linha", () => {
  const f = C.parseKdl('// x\nlanguage "Teste" code="tt" english="Test"\ndirection "rtl"\nplurals "ru"\n"{d} votes" one="{d} a" few="{d} b"\n/-"old" "velho"\n"a\\nb" "c"\n');
  assert.deepStrictEqual(f.header, { language: "Teste", code: "tt", english: "Test", direction: "rtl", plurals: "ru" });
  assert.deepStrictEqual(f.entries[0].forms, { one: "{d} a", few: "{d} b" });
  assert.strictEqual(f.entries[1].dropped, true);
  assert.strictEqual(f.entries[2].key, "a\nb");
  for (const [src, line] of [['"a" "b"\n"c" "d" "e"\n', 2], ['"a" "b"\nnovo "x"\n', 2], ['"a" "b" bad="c"\n', 1], ['"a" "sem fim\n', 2], ['\n\n"a" {\n', 3]]) {
    assert.throws(() => C.parseKdl(src), (e) => e instanceof C.KdlError && e.line === line, src);
  }
});

function state(entries, code) {
  const values = {};
  for (const e of entries) values[e.key] = { value: e.value, forms: e.forms };
  return { code: code, name: "Nome", english: "Name", rtl: false, plurals: "", values: values, stale: [] };
}
const KEYS = REF.keys.map((k) => ({ key: k, one: null, fmt: FMT.has(k) }));

test("o .kdl baixado volta igual: ja.kdl e ru.kdl inteiros", () => {
  for (const name of Object.keys(REF.files)) {
    const f = C.parseKdl(fs.readFileSync(path.join(ROOT, "i18n", name), "utf8"));
    const live = f.entries.filter((e) => !e.dropped && REF.keys.includes(e.key));
    const S = state(live, f.header.code);
    const out = C.serialize(S, KEYS, C.ruleOf(rules, f.header.code).forms, false);
    const back = C.parseKdl(out);
    assert.strictEqual(back.header.code, f.header.code);
    assert.strictEqual(back.entries.length, live.length, name);
    const byKey = Object.fromEntries(back.entries.map((e) => [e.key, e]));
    for (const e of live) {
      assert.strictEqual(byKey[e.key].value, e.value, e.key);
      assert.deepStrictEqual(byKey[e.key].forms, e.forms, e.key);
    }
  }
});

test("o .kdl baixado: vazias só com a opção, plural com as formas do idioma, fora de uso com /-", () => {
  const keys = [{ key: "{d} votes", one: "{d} vote", fmt: true }, { key: "Language", one: null, fmt: false }];
  const S = state([{ key: "Language", value: "Язык", forms: {} }], "ru");
  S.stale = [{ key: "Old text", value: "Старый", forms: {} }];
  S.rtl = true;
  const out = C.serialize(S, keys, ["one", "few", "many"], true);
  assert.match(out, /^language "Nome" code="ru" english="Name"$/m);
  assert.match(out, /^direction "rtl"$/m);
  assert.match(out, /^"\{d\} votes" one="" few="" many=""$/m);
  assert.match(out, /^\/-"Old text" "Старый"$/m);
  const lean = C.serialize(S, keys, ["one", "few", "many"], false);
  assert.doesNotMatch(lean, /votes/);
  // O que sai é o que o app lê: tools/i18n_strings.py --check aceita (o mesmo leitor do app).
  const back = C.parseKdl(out);
  assert.strictEqual(back.entries.find((e) => e.key === "Old text").dropped, true);
});

test("formas de plural do idioma: com a região, sem ela, e o padrão do inglês", () => {
  assert.deepStrictEqual(C.ruleOf(rules, "ru-UA").forms, ["one", "few", "many"]);
  assert.deepStrictEqual(C.ruleOf(rules, "ja").forms, ["other"]);
  assert.deepStrictEqual(C.ruleOf(rules, "klingon").forms, ["one", "other"]);
});

test("as mensagens saem nos dois idiomas", () => {
  C.setPt(true);
  assert.match(C.checkTemplate("{s}", "{d}"), /onde o inglês tem/);
  C.setPt(false);
  assert.match(C.checkTemplate("{s}", "{d}"), /where the English has/);
});

for (const [name, e] of failures) console.error(`FALHOU: ${name}\n  ${e && e.message}`);
console.log(`${passed} passaram, ${failures.length} falharam`);
process.exit(failures.length ? 1 : 0);

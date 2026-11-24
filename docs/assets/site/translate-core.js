// O núcleo do editor de traduções (translate.html): sem DOM, para a página e o teste
// (tools/translate_test.js) usarem o mesmo código. Os marcadores seguem src/ui/i18n.zig e
// tools/i18n_strings.py; o leitor de KDL é o subconjunto dos arquivos de tradução.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.LC_TC = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";
  var pt = false;
  function T(en, p) { return pt ? p : en; }
  function setPt(v) { pt = !!v; }
  var CATS = ["zero", "one", "two", "few", "many", "other"];

  // --- Marcadores (as mesmas regras de src/ui/i18n.zig e tools/i18n_strings.py) ---------

  // Os marcadores de um texto de formato: [[argumento, interior]], ou null quando o app não
  // traduz o texto (chave sem par, argumento com nome).
  function parseFormat(text) {
    var out = [], next = 0, i = 0;
    while (i < text.length) {
      var ch = text[i];
      if (ch === "}") {
        if (text[i + 1] === "}") { i += 2; continue; }
        return null;
      }
      if (ch !== "{") { i++; continue; }
      if (text[i + 1] === "{") { i += 2; continue; }
      var close = text.indexOf("}", i + 1);
      if (close < 0) return null;
      var inner = text.slice(i + 1, close);
      if (/[\[{]/.test(inner)) return null;
      var m = /^\d*/.exec(inner)[0];
      var arg;
      if (m) arg = parseInt(m, 10); else arg = next++;
      if (arg >= 32 || out.length >= 32) return null;
      out.push([arg, inner]);
      i = close + 1;
    }
    return out;
  }

  // null se a tradução serve para o texto de formato `english`; senão o porquê.
  function checkTemplate(tpl, english) {
    var phs = parseFormat(english);
    if (!phs) return null;
    var need = {}, used = {}, mode = null, seq = 0, i = 0;
    phs.forEach(function (p) { need[p[0]] = 1; });
    while (i < tpl.length) {
      var ch = tpl[i];
      if (ch !== "{" && ch !== "}") { i++; continue; }
      if (tpl[i + 1] === ch) { i += 2; continue; }
      if (ch === "}") return T("a lone } (write }} for a brace)", "uma } sozinha (escreva }} para a chave)");
      var close = tpl.indexOf("}", i + 1);
      if (close < 0) return T("a { that isn't closed (write {{ for a brace)", "uma { sem fechar (escreva {{ para a chave)");
      var inner = tpl.slice(i + 1, close), k;
      if (/^\d+$/.test(inner)) {
        if (mode === "copy") return T("mixes {N} with copied placeholders", "mistura {N} com marcadores copiados");
        mode = "index";
        k = parseInt(inner, 10);
        if (k >= phs.length) return T("{" + inner + "}: the English has only " + phs.length + " placeholder" + (phs.length === 1 ? "" : "s"), "{" + inner + "}: o inglês só tem " + phs.length + " marcador" + (phs.length === 1 ? "" : "es"));
      } else {
        if (mode === "index") return T("mixes {N} with copied placeholders", "mistura {N} com marcadores copiados");
        mode = "copy";
        if (seq >= phs.length) return T("{" + inner + "} is one too many: the English has " + phs.length, "{" + inner + "} a mais: o inglês tem " + phs.length);
        if (inner !== phs[seq][1]) return T("{" + inner + "} where the English has {" + phs[seq][1] + "}", "{" + inner + "} onde o inglês tem {" + phs[seq][1] + "}");
        k = seq++;
      }
      used[phs[k][0]] = 1;
      i = close + 1;
    }
    if (mode === "copy" && seq !== phs.length) return T("placeholders missing: " + seq + " of " + phs.length, "faltam marcadores: " + seq + " de " + phs.length);
    for (var a in need) if (!used[a]) return T("a value from the English is missing", "falta um valor do inglês");
    return null;
  }

  // --- O arquivo (o subconjunto de KDL dos arquivos de tradução) -------------------------

  function KdlError(msg, line) { this.message = msg; this.line = line; }

  function parseKdl(text) {
    var i = 0, n = text.length, line = 1;
    var out = { header: {}, entries: [] };
    function fail(msg, at) { throw new KdlError(msg, at || line); }
    function skip(nl) {
      while (i < n) {
        var ch = text[i];
        if (ch === " " || ch === "\t" || ch === "\r") i++;
        else if (ch === "\n" && nl) { i++; line++; }
        else if (ch === "\\") {
          i++;
          while (i < n && /[ \t\r]/.test(text[i])) i++;
          if (text.startsWith("//", i)) while (i < n && text[i] !== "\n") i++;
          if (text[i] === "\n") { i++; line++; }
        } else if (text.startsWith("//", i)) { while (i < n && text[i] !== "\n") i++; }
        else if (text.startsWith("/*", i)) {
          var depth = 0;
          while (i < n) {
            if (text.startsWith("/*", i)) { depth++; i += 2; }
            else if (text.startsWith("*/", i)) { depth--; i += 2; if (!depth) break; }
            else { if (text[i] === "\n") line++; i++; }
          }
          if (depth) fail(T("a /* comment that isn't closed", "um comentário /* sem fechar"));
        } else break;
      }
    }
    function str() {
      i++;
      var buf = "";
      for (;;) {
        if (i >= n) fail(T("a text that isn't closed", "um texto sem fechar"));
        var ch = text[i];
        if (ch === '"') { i++; return buf; }
        if (ch === "\\") {
          var e = text[i + 1], r = { n: "\n", t: "\t", r: "\r", '"': '"', "\\": "\\", "/": "/" }[e];
          if (r === undefined) fail(T("invalid escape: \\", "escape inválido: \\") + e);
          buf += r; i += 2; continue;
        }
        if (ch === "\n") line++;
        buf += ch; i++;
      }
    }
    function word() {
      var start = i;
      while (i < n && ' \t\r\n=;{}"()\\'.indexOf(text[i]) < 0) i++;
      if (i === start) fail(T("expected a text in quotes", "esperava um texto entre aspas"));
      return text.slice(start, i);
    }
    var seenEntry = false;
    for (;;) {
      skip(true);
      while (i < n && text[i] === ";") { i++; skip(true); }
      if (i >= n) break;
      var dropped = false;
      if (text.startsWith("/-", i)) { dropped = true; i += 2; skip(true); }
      var at = line, quoted = text[i] === '"';
      var key = quoted ? str() : word(), args = [], props = {};
      for (;;) {
        skip(false);
        if (i >= n || text[i] === "\n" || text[i] === ";") break;
        if (text[i] === "{" || text[i] === "}") fail(T("blocks aren't allowed here", "blocos não valem aqui"));
        var v = text[i] === '"' ? str() : word();
        if (text[i] === "=") {
          i++;
          if (text[i] !== '"') fail(v + "=: " + T("the value goes in quotes", "o valor vai entre aspas"));
          props[v] = str();
        } else args.push(v);
      }
      if (dropped) {
        if (quoted && args.length <= 1) out.entries.push({ key: key, value: args[0] || "", forms: pickForms(props), dropped: true });
        continue;
      }
      if (!quoted) {
        if (["language", "direction", "font-script", "plurals"].indexOf(key) < 0) fail(T("unknown line `" + key + "` (entries go in quotes)", "linha desconhecida `" + key + "` (as entradas vão entre aspas)"), at);
        if (args.length !== 1) fail(T("expected " + key + ' "…"', "esperava " + key + ' "…"'), at);
        if (key === "language") { out.header.language = args[0]; out.header.code = props.code; out.header.english = props.english; }
        else out.header[key] = args[0];
        continue;
      }
      seenEntry = true;
      if (args.length > 1) fail(T("one text after the English", "um texto depois do inglês"), at);
      for (var p in props) if (CATS.indexOf(p) < 0) fail(T("unknown plural form " + p + "=", "forma de plural desconhecida " + p + "="), at);
      out.entries.push({ key: key, value: args[0] || "", forms: pickForms(props), dropped: false });
    }
    return out;
  }
  function pickForms(props) {
    var f = {};
    CATS.forEach(function (c) { if (props[c] !== undefined) f[c] = props[c]; });
    return f;
  }
  function quote(s) {
    return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\t/g, "\\t").replace(/\r/g, "\\r") + '"';
  }

  function ruleOf(rules, code) {
    var c = (code || "").toLowerCase().replace(/_/g, "-");
    return rules[c] || rules[c.split("-")[0]] || { forms: ["one", "other"], examples: { one: "1", other: "0, 2, 5" } };
  }

  // --- O arquivo que sai -----------------------------------------------------------------

  function sortKey(a, b) {
    var x = a.toLowerCase(), y = b.toLowerCase();
    return x < y ? -1 : x > y ? 1 : a < b ? -1 : a > b ? 1 : 0;
  }
  // O .kdl: o cabeçalho, as entradas com texto (ou todas, com keepEmpty) em ordem, e as que o
  // app não usa mais comentadas com /-. `forms`: as formas de plural do idioma.
  function serialize(S, KEYS, forms, keepEmpty) {
    var BY_KEY = {};
    KEYS.forEach(function (k) { BY_KEY[k.key] = k; });
    var code = S.code || "xx", name = S.name || code;
    var lines = [
      "// larperCord — " + (S.english || name) + " (" + name + ") interface text.",
      "// Made in the translation editor: https://rshacudevidro.github.io/larperCord/translate.html",
      "// The guide: https://rshacudevidro.github.io/larperCord/guide/translating.html",
      "",
      "language " + quote(name) + " code=" + quote(code) + (S.english ? " english=" + quote(S.english) : ""),
    ];
    if (S.rtl) lines.push('direction "rtl"');
    if (S.plurals) lines.push("plurals " + quote(S.plurals));
    lines.push("");
    var keys = KEYS.map(function (k) { return k.key; }).sort(sortKey);
    keys.forEach(function (key) {
      var k = BY_KEY[key], v = S.values[key] || { value: "", forms: {} };
      var hasForms = Object.keys(v.forms).some(function (c) { return v.forms[c]; });
      if (!v.value && !hasForms && !keepEmpty) return;
      var s = quote(key);
      if (k.one !== null && forms.length > 1) {
        if (v.value) s += " " + quote(v.value);
        CATS.forEach(function (c) {
          if (v.forms[c] || (keepEmpty && forms.indexOf(c) >= 0 && !v.value)) s += " " + c + "=" + quote(v.forms[c] || "");
        });
      } else {
        s += " " + quote(v.value || "");
        CATS.forEach(function (c) { if (v.forms[c]) s += " " + c + "=" + quote(v.forms[c]); });
      }
      lines.push(s);
    });
    if (S.stale.length) {
      lines.push("", "// The app no longer uses these texts: kept (commented out with /-) so the translation isn't lost.");
      S.stale.forEach(function (e) {
        var s = "/-" + quote(e.key) + " " + quote(e.value || "");
        CATS.forEach(function (c) { if (e.forms[c]) s += " " + c + "=" + quote(e.forms[c]); });
        lines.push(s);
      });
    }
    return lines.join("\n") + "\n";
  }

  return { CATS: CATS, setPt: setPt, parseFormat: parseFormat, checkTemplate: checkTemplate, KdlError: KdlError, parseKdl: parseKdl, quote: quote, ruleOf: ruleOf, serialize: serialize };
});

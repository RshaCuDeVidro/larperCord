/* larperCord: o editor de traduções (translate.html). Tudo acontece nesta página: os textos
   do app e o contexto de cada um vêm de LC_I18N (i18n-data.js, gerado por tools/gen_site.py a
   partir do código), cada idioma pronto de i18n/<código>.kdl do próprio site, e o resultado é um
   .kdl para baixar. Os marcadores são conferidos como o app confere (src/ui/i18n.zig, em
   translate-core.js); o trabalho fica no localStorage deste navegador até alguém baixar.
   Nada vai para servidor. */
(function () {
  "use strict";
  var D = window.LC_I18N;
  var page = document.querySelector("[data-translate]");
  if (!D || !page) return;
  var C = window.LC_TC;
  var pt = document.documentElement.dataset.lang === "pt";
  function T(en, p) { return pt ? p : en; }
  C.setPt(pt);
  var ROOT = document.documentElement.dataset.root || "";
  var CATS = C.CATS, checkTemplate = C.checkTemplate, parseKdl = C.parseKdl, KdlError = C.KdlError;
  var DRAFT = "lc-translate-draft";
  var PAGE = 60;

  // --- Os textos do app ------------------------------------------------------------------

  // keys: [inglês, arquivo, linha, o que é, singular (contagem) ou null, formato (0/1), mais lugares]
  var KEYS = D.keys.map(function (k, i) {
    return { key: k[0], file: k[1], line: k[2], kind: k[3], one: k[4], fmt: !!k[5], more: k[6], i: i };
  });
  var BY_KEY = {};
  KEYS.forEach(function (k) { BY_KEY[k.key] = k; });

  function ruleOf(code) { return C.ruleOf(D.rules, code); }

  // --- O estado --------------------------------------------------------------------------

  var S = { code: "", name: "", english: "", rtl: false, plurals: "", values: {}, stale: [], from: "" };

  function rule() { return ruleOf(S.plurals || S.code); }
  function texts(k) {
    var v = S.values[k.key] || { value: "", forms: {} };
    var out = [v.value];
    for (var c in v.forms) out.push(v.forms[c]);
    return out;
  }
  function problemOf(k) {
    if (!k.fmt) return null;
    var v = S.values[k.key];
    if (!v) return null;
    var all = [v.value];
    for (var c in v.forms) all.push(v.forms[c]);
    for (var i = 0; i < all.length; i++) if (all[i]) { var why = checkTemplate(all[i], k.key); if (why) return why; }
    return null;
  }
  // done, same (o próprio inglês), missing (nada, ou uma forma vazia sem o texto solto), problem.
  function stateOf(k) {
    if (problemOf(k)) return "problem";
    var v = S.values[k.key] || { value: "", forms: {} };
    var any = texts(k).some(function (t) { return t; });
    if (!any) return "missing";
    var translated = texts(k).some(function (t) { return t && t !== k.key; });
    if (!translated) return "same";
    if (k.one !== null && !v.value) {
      var forms = rule().forms;
      if (forms.length > 1 && forms.some(function (f) { return !v.forms[f]; })) return "missing";
    }
    return "done";
  }
  function translatedCount() {
    // Como o app e tools/i18n_strings.py contam: algum texto diferente do inglês.
    var n = 0;
    KEYS.forEach(function (k) { if (texts(k).some(function (t) { return t && t !== k.key; })) n++; });
    return n;
  }

  function load(file, from) {
    var vals = {}, stale = [];
    file.entries.forEach(function (e) {
      if (!BY_KEY[e.key]) { stale.push(e); return; }
      if (e.dropped && vals[e.key]) return;
      vals[e.key] = { value: e.value, forms: e.forms };
    });
    S.values = vals;
    S.stale = stale;
    S.code = file.header.code || "";
    S.name = file.header.language || "";
    S.english = file.header.english || "";
    S.rtl = file.header.direction === "rtl";
    S.plurals = file.header.plurals || "";
    S.from = from || "";
    shown = PAGE;
    syncMeta();
    render();
    save();
  }
  function startNew() {
    load({ header: {}, entries: [] }, "new");
    note(T("A new language: fill in its name and code above, then translate below. The missing texts come first.", "Um idioma novo: preencha o nome e o código acima e traduza embaixo. Os textos que faltam vêm primeiro."));
  }

  // --- A página --------------------------------------------------------------------------

  var app = page.querySelector("[data-app]");
  var $ = function (sel) { return page.querySelector(sel); };
  var list = $("[data-list]"), more = $("[data-more]"), empty = $("[data-empty]");
  var startSel = $("[data-start]"), fileIn = $("[data-file]");
  var fName = $("[data-name]"), fCode = $("[data-code]"), fEnglish = $("[data-english]"), fDir = $("[data-dir]");
  var formsP = $("[data-forms]"), summary = $("[data-summary]"), bar = $("[data-bar]"), meter = $("[data-meter]"), noteP = $("[data-note]");
  var q = $("[data-q]"), seg = $("[data-show]"), keepEmpty = $("[data-keep-empty]");
  var show = "todo", shown = PAGE;

  function note(text) { noteP.hidden = !text; noteP.textContent = text || ""; }

  function syncMeta() {
    fName.value = S.name; fCode.value = S.code; fEnglish.value = S.english; fDir.value = S.rtl ? "rtl" : "ltr";
    var r = rule();
    formsP.textContent = r.forms.length > 1
      ? T("Counts in this language: ", "Contagens neste idioma: ") + r.forms.map(function (f) { return f + " (" + (r.examples[f] || "") + ")"; }).join(" · ")
      : T("This language has one form for every count.", "Este idioma tem uma forma só para qualquer número.");
  }

  [["name", fName], ["english", fEnglish]].forEach(function (p) {
    p[1].addEventListener("input", function () { S[p[0]] = p[1].value.trim(); save(); });
  });
  fCode.addEventListener("input", function () {
    S.code = fCode.value.trim();
    fCode.setAttribute("aria-invalid", S.code && !/^[A-Za-z][A-Za-z0-9_-]{0,14}$/.test(S.code) ? "true" : "false");
    syncMeta(); render(); save();
  });
  fDir.addEventListener("change", function () { S.rtl = fDir.value === "rtl"; render(); save(); });

  function mark(el, text, fmt) {
    // O inglês com os marcadores em destaque.
    el.textContent = "";
    if (!fmt) { el.textContent = text; return; }
    var re = /\{\{|\}\}|\{[^{}]*\}/g, last = 0, m;
    while ((m = re.exec(text))) {
      if (m[0] === "{{" || m[0] === "}}") continue;
      el.appendChild(document.createTextNode(text.slice(last, m.index)));
      var b = document.createElement("mark");
      b.textContent = m[0];
      el.appendChild(b);
      last = m.index + m[0].length;
    }
    el.appendChild(document.createTextNode(text.slice(last)));
  }

  function autosize(ta) { ta.style.height = "auto"; ta.style.height = Math.min(ta.scrollHeight + 2, 360) + "px"; }

  var RANK = { problem: 0, missing: 1, same: 2, done: 3 };
  function visible() {
    var needle = q.value.trim().toLowerCase();
    var rows = KEYS.filter(function (k) {
      var st = stateOf(k);
      if (show !== "todo" && show !== "stale" && st !== show) return false;
      if (!needle) return true;
      if (k.key.toLowerCase().indexOf(needle) >= 0 || k.file.toLowerCase().indexOf(needle) >= 0) return true;
      return texts(k).some(function (t) { return t && t.toLowerCase().indexOf(needle) >= 0; });
    });
    if (show === "todo") rows.sort(function (a, b) {
      return RANK[stateOf(a)] - RANK[stateOf(b)] || (a.file < b.file ? -1 : a.file > b.file ? 1 : a.line - b.line);
    });
    return rows;
  }

  function row(k) {
    var li = document.createElement("li");
    li.className = "trx-row";
    li.dataset.state = stateOf(k);
    var src = document.createElement("div");
    src.className = "trx-src";
    var en = document.createElement("p");
    en.className = "trx-en";
    en.lang = "en";
    en.dir = "ltr";
    mark(en, k.key, k.fmt);
    src.appendChild(en);
    var ctx = document.createElement("p");
    ctx.className = "trx-ctx";
    var a = document.createElement("a");
    a.href = D.repo + "/blob/main/" + k.file + "#L" + k.line;
    a.rel = "noopener";
    a.textContent = k.file.replace(/^src\//, "") + ":" + k.line;
    ctx.appendChild(a);
    var bits = [k.kind];
    if (k.more) bits.push(T("+" + k.more + " more place" + (k.more > 1 ? "s" : ""), "+" + k.more + " lugar" + (k.more > 1 ? "es" : "")));
    if (k.one !== null) bits.push(T("English singular: ", "singular em inglês: ") + k.one);
    ctx.appendChild(document.createTextNode(" · " + bits.join(" · ")));
    if (/^\s|\s$/.test(k.key)) {
      var sp = document.createElement("span");
      sp.className = "trx-hint";
      sp.textContent = T(" · keep the spaces at the edges", " · mantenha os espaços das pontas");
      ctx.appendChild(sp);
    }
    src.appendChild(ctx);
    li.appendChild(src);

    var dst = document.createElement("div");
    dst.className = "trx-dst";
    var v = S.values[k.key] || (S.values[k.key] = { value: "", forms: {} });
    var r = rule();
    var fields = [];
    if (k.one !== null && r.forms.length > 1) {
      r.forms.forEach(function (f) { fields.push({ form: f, label: f + " · " + (r.examples[f] || "") }); });
      if (v.value) fields.push({ form: "", label: T("any other count (for the forms left empty)", "qualquer outro número (para as formas vazias)") });
    } else fields.push({ form: "", label: "" });
    var err = document.createElement("p");
    err.className = "trx-err";
    err.setAttribute("aria-live", "polite");
    fields.forEach(function (f) {
      var lab = document.createElement("label");
      lab.className = "trx-in";
      if (f.label) {
        var sp = document.createElement("span");
        sp.className = "trx-form";
        sp.textContent = f.label;
        lab.appendChild(sp);
      }
      var ta = document.createElement("textarea");
      ta.rows = 1;
      ta.dir = S.rtl ? "rtl" : "auto";
      ta.lang = S.code || "";
      ta.spellcheck = true;
      ta.value = f.form ? v.forms[f.form] || "" : v.value;
      if (!f.label) ta.setAttribute("aria-label", T("Translation of: ", "Tradução de: ") + k.key);
      ta.addEventListener("input", function () {
        if (f.form) { if (ta.value) v.forms[f.form] = ta.value; else delete v.forms[f.form]; }
        else v.value = ta.value;
        autosize(ta);
        var why = k.fmt && ta.value ? checkTemplate(ta.value, k.key) : null;
        ta.setAttribute("aria-invalid", why ? "true" : "false");
        refreshRow(li, k, err);
        scheduleSummary();
        save();
      });
      lab.appendChild(ta);
      dst.appendChild(lab);
      requestAnimationFrame(function () { autosize(ta); });
    });
    dst.appendChild(err);
    li.appendChild(dst);
    refreshRow(li, k, err);
    return li;
  }

  function refreshRow(li, k, err) {
    var why = problemOf(k);
    err.textContent = why ? T("Shows in English until fixed: ", "Aparece em inglês até consertar: ") + why : "";
    li.dataset.state = stateOf(k);
  }

  function render() {
    var rows = show === "stale" ? [] : visible();
    list.textContent = "";
    if (show === "stale") {
      S.stale.forEach(function (e) {
        var li = document.createElement("li");
        li.className = "trx-row";
        li.dataset.state = "stale";
        var p = document.createElement("p");
        p.className = "trx-en";
        p.textContent = e.key;
        var t = document.createElement("p");
        t.className = "trx-ctx";
        t.textContent = (e.value || Object.values(e.forms)[0] || "") + " · " + T("kept in the file with /-, the app ignores it", "fica no arquivo com /-, o app ignora");
        li.appendChild(p);
        li.appendChild(t);
        list.appendChild(li);
      });
    }
    var frag = document.createDocumentFragment();
    rows.slice(0, shown).forEach(function (k) { frag.appendChild(row(k)); });
    list.appendChild(frag);
    more.hidden = rows.length <= shown;
    more.textContent = T("Show more (" + (rows.length - shown) + " left)", "Mostrar mais (faltam " + (rows.length - shown) + ")");
    empty.hidden = list.children.length > 0;
    summarize();
  }

  var summaryTimer = 0;
  function scheduleSummary() { clearTimeout(summaryTimer); summaryTimer = setTimeout(summarize, 120); }
  function summarize() {
    var counts = { problem: 0, missing: 0, same: 0, done: 0, stale: S.stale.length };
    KEYS.forEach(function (k) { counts[stateOf(k)]++; });
    var done = translatedCount(), total = KEYS.length, pct = Math.floor(100 * done / total);
    bar.style.width = pct + "%";
    meter.setAttribute("aria-valuenow", String(pct));
    summary.textContent = (S.name || S.code ? (S.name || S.code) + " — " : "") + pct + "% · " +
      T(done + " of " + total + " texts translated", done + " de " + total + " textos traduzidos") +
      (counts.problem ? " · " + T(counts.problem + " with wrong placeholders", counts.problem + " com marcadores errados") : "");
    Object.keys(counts).forEach(function (c) {
      var b = seg.querySelector('[data-n="' + c + '"]');
      if (b) b.textContent = counts[c];
    });
    seg.querySelector("[data-stale-tab]").hidden = !counts.stale;
  }

  // --- O que salva no navegador (só conveniência: o arquivo baixado é o que vale) ---------

  var saveTimer = 0;
  function save() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      try {
        var vals = {};
        for (var key in S.values) {
          var v = S.values[key];
          if (v.value || Object.keys(v.forms).length) vals[key] = v;
        }
        localStorage.setItem(DRAFT, JSON.stringify({ code: S.code, name: S.name, english: S.english, rtl: S.rtl, plurals: S.plurals, values: vals, stale: S.stale, from: S.from, at: Date.now() }));
      } catch (e) { /* sem armazenamento: só não guarda */ }
    }, 500);
  }
  function restore() {
    try {
      var d = JSON.parse(localStorage.getItem(DRAFT) || "null");
      if (!d || !d.values) return false;
      S.code = d.code || ""; S.name = d.name || ""; S.english = d.english || ""; S.rtl = !!d.rtl; S.plurals = d.plurals || "";
      S.values = d.values; S.stale = d.stale || []; S.from = d.from || "";
      syncMeta();
      render();
      var when = new Date(d.at);
      note(T("Your work from ", "O seu trabalho de ") + when.toLocaleString(pt ? "pt-BR" : "en") + T(" is back (it stays in this browser). Pick something in \"Start from\" to begin again.", " voltou (ele fica neste navegador). Escolha algo em \"Começar de\" para recomeçar."));
      return true;
    } catch (e) { return false; }
  }

  // --- Começar, abrir, baixar --------------------------------------------------------------

  function hasWork() {
    for (var key in S.values) { var v = S.values[key]; if (v.value || Object.keys(v.forms).length) return true; }
    return false;
  }
  function confirmLose() {
    return !hasWork() || window.confirm(T("Replace what's in the editor? Download it first if you want to keep it.", "Trocar o que está no editor? Baixe antes se quiser guardar."));
  }

  var opt = document.createElement("option");
  opt.value = "";
  opt.textContent = T("— pick —", "— escolha —");
  startSel.appendChild(opt);
  opt = document.createElement("option");
  opt.value = "new";
  opt.textContent = T("A new language (the template)", "Um idioma novo (o modelo)");
  startSel.appendChild(opt);
  D.languages.forEach(function (l) {
    var o = document.createElement("option");
    o.value = l.code;
    o.textContent = l.name + (l.english ? " (" + l.english + ")" : "") + " — " + Math.floor(100 * l.translated / l.total) + "%";
    startSel.appendChild(o);
  });

  function loadBuiltin(code) {
    var l = D.languages.filter(function (x) { return x.code === code; })[0];
    if (!l) return startNew();
    note(T("Loading ", "Abrindo ") + l.file + "…");
    fetch(ROOT + "i18n/" + l.file).then(function (r) {
      if (!r.ok) throw new Error(r.status);
      return r.text();
    }).then(function (text) {
      load(parseKdl(text), code);
      note(T("Started from i18n/" + l.file + ", the file that comes with the app.", "Começou de i18n/" + l.file + ", o arquivo que vem com o app."));
    }).catch(function () {
      note(T("Couldn't open i18n/" + l.file + " from the site. Download it from the repository and open it here.", "Não deu para abrir i18n/" + l.file + " do site. Baixe do repositório e abra aqui."));
    });
  }

  startSel.addEventListener("change", function () {
    var v = startSel.value;
    startSel.value = "";
    if (!v || !confirmLose()) return;
    if (v === "new") startNew(); else loadBuiltin(v);
    history.replaceState(null, "", v === "new" ? "#new" : "#lang=" + v);
  });

  function openText(text, name) {
    try {
      var f = parseKdl(text.replace(/^﻿/, ""));
      if (!f.header.code) f.header.code = (name || "").replace(/\.kdl$/i, "");
      load(f, "file");
      var unknown = f.entries.filter(function (e) { return !BY_KEY[e.key]; }).length;
      note(T("Opened " + name + ".", "Abriu " + name + ".") + (unknown ? " " + T(unknown + " entries the app no longer uses are under \"No longer used\".", unknown + " entradas que o app não usa mais estão em \"Fora de uso\".") : ""));
    } catch (e) {
      if (e instanceof KdlError) note(name + ":" + e.line + ": " + e.message);
      else throw e;
    }
  }
  $("[data-open]").addEventListener("click", function () { fileIn.click(); });
  fileIn.addEventListener("change", function () {
    var f = fileIn.files[0];
    fileIn.value = "";
    if (!f || !confirmLose()) return;
    f.text().then(function (t) { openText(t, f.name); });
  });
  page.addEventListener("dragover", function (e) { if (e.dataTransfer && Array.prototype.indexOf.call(e.dataTransfer.types, "Files") >= 0) e.preventDefault(); });
  page.addEventListener("drop", function (e) {
    var f = e.dataTransfer && e.dataTransfer.files[0];
    if (!f) return;
    e.preventDefault();
    if (!confirmLose()) return;
    f.text().then(function (t) { openText(t, f.name); });
  });

  $("[data-download]").addEventListener("click", function () {
    if (!S.code || !/^[A-Za-z][A-Za-z0-9_-]{0,14}$/.test(S.code)) {
      note(T("Fill in the language code first (like de, fr or pt-PT).", "Preencha o código do idioma antes (como de, fr ou pt-PT)."));
      fCode.focus();
      return;
    }
    var blob = new Blob([C.serialize(S, KEYS, rule().forms, keepEmpty.checked)], { type: "text/plain;charset=utf-8" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = S.code + ".kdl";
    document.body.appendChild(a);
    a.click();
    setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  });

  seg.addEventListener("click", function (e) {
    var b = e.target.closest("[data-v]");
    if (!b) return;
    show = b.dataset.v;
    shown = PAGE;
    seg.querySelectorAll("[data-v]").forEach(function (x) { x.setAttribute("aria-checked", x === b ? "true" : "false"); });
    render();
  });
  var qTimer = 0;
  q.addEventListener("input", function () { clearTimeout(qTimer); qTimer = setTimeout(function () { shown = PAGE; render(); }, 150); });
  more.addEventListener("click", function () { shown += PAGE; render(); });

  app.hidden = false;
  var hash = location.hash;
  var m = /^#lang=([A-Za-z0-9_-]+)$/.exec(hash);
  if (m) loadBuiltin(m[1]);
  else if (hash === "#new") startNew();
  else if (!restore()) startNew();

  // Para o teste (tools/translate_test.js).
  window.LC_TRANSLATE = { load: load, state: S, stateOf: stateOf, keys: KEYS };
})();

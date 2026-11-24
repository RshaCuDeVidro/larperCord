#!/usr/bin/env python3
"""Textos da interface para as traduções em i18n/<idioma>.kdl.

A chave de cada tradução é o texto em inglês exatamente como está no código. Este
script acha esses textos em src/**/*.zig:

  - chamadas de i18n.tr, trZ, fmt, fmtZ e allocPrint (o inglês é o segundo texto) e de
    i18n.plural e pluralAlloc (a chave é o plural em inglês; o singular vai no contexto);
  - funções que repassam o par português/inglês para elas (showToast, notice,
    setProblem...): achadas sozinhas, pelos parâmetros `pt` e `en`/`english`;
  - tabelas com o par em campos: `.en = "..."` ou `.<nome>_en = "..."` (e `.teclas`
    quando a linha tem `.teclas_pt`), fora dos dados da demonstração.

Junta textos separados por `++`, aceita strings de várias linhas (`\\\\`), escapes e
chamadas quebradas em linhas. Ignora blocos `test` e os roteiros de QA.

Uso (só a biblioteca padrão):
  python3 tools/i18n_strings.py                  todos os textos em inglês, ordenados, sem repetição
  python3 tools/i18n_strings.py --check          confere todos os i18n/*.kdl (ou só o de --lang): arquivo
                                                 inválido, cabeçalho errado, marcador errado (em cada forma
                                                 de plural) e chave repetida saem com código 1; faltando,
                                                 sobrando e i18n/keys.txt desatualizado são avisos
  python3 tools/i18n_strings.py --check --file ARQUIVO  o mesmo, para um arquivo fora de i18n/
  python3 tools/i18n_strings.py --check --strict  idem, e falta de tradução ou inglês vindo de uma
                                                 variável que o script não lê também saem com 1
  python3 tools/i18n_strings.py --keys           grava i18n/keys.txt (os textos do código, que o app
                                                 usa para dizer quanto cada idioma traduz)
  python3 tools/i18n_strings.py --template XX [--name NOME] [--english NOME] [-o ARQUIVO]
                                                 o modelo de um idioma novo: cada texto em inglês com a
                                                 tradução vazia, um comentário //: com onde e o que ele é,
                                                 e as formas de plural do idioma
  python3 tools/i18n_strings.py --update ARQUIVO [--no-context]
                                                 põe num arquivo de tradução os textos novos (vazios) e
                                                 marca com /- os que o código não usa mais, sem perder
                                                 nenhuma tradução; refaz os comentários //:
  python3 tools/i18n_strings.py --pending PASTA [--chunks N]
                                                 os textos ainda sem tradução, em N arquivos
                                                 (padrão 4), uma linha por texto com o lugar
  python3 tools/i18n_strings.py --merge ARQUIVO  junta as traduções preenchidas de ARQUIVO
                                                 (mesmo formato) em i18n/<--lang>.kdl
  --lang XX                                      um idioma só (i18n/XX.kdl); --pending e --merge usam ja

O arquivo de tradução começa dizendo quem é (`language "日本語" code="ja" english="Japanese"`,
e se precisar `direction "rtl"`, `font-script "ja"`, `plurals "ru"`) e tem uma entrada por linha,
`"inglês" "tradução"`. Um texto com contagem (i18n.plural) tem uma forma por categoria do
CLDR, como propriedade: `"{d} votes" one="{d} голос" few="{d} голоса" many="{d} голосов"`.

Marcadores (só nos textos de formato: fmt, fmtZ, allocPrint, plural e quem repassa para eles):
  - copie os marcadores do inglês como estão ({s}, {d}, {d:.0}...): eles são
    preenchidos na mesma ordem do inglês;
  - para mudar a ordem, use {0}, {1}...: o N-ésimo marcador do texto em inglês
    (contando do zero), com a mesma formatação dele. Não misture os dois jeitos;
  - todo valor do inglês precisa aparecer; {{ e }} viram { e }.
Uma tradução que não segue isso aparece em inglês no app.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

# As funções do src/ui/i18n.zig: nome -> (posição do inglês, é texto de formato).
BASE = {
    "tr": (1, False),
    "trZ": (1, False),
    "fmt": (2, True),
    "fmtZ": (2, True),
    "allocPrint": (2, True),
    # (buf ou gpa, n, pt_one, pt_other, en_one, en_other, args): a chave é o en_other.
    "plural": (5, True),
    "pluralAlloc": (5, True),
}
FORMAT_FNS = {"fmt", "fmtZ", "allocPrint", "plural", "pluralAlloc"}
PLURAL_FNS = {"plural", "pluralAlloc"}

# Fora da busca: roteiros de QA, os testes e o próprio i18n.zig.
SKIP_FILES = re.compile(r"^(qa_.*|tests)\.zig$")
# Tabelas `.en = "..."` que nunca passam por i18n.tr: dados da demonstração e nomes
# de emoji (só servem para a busca).
SKIP_TABLES = {
    "src/net/fake_gateway.zig",
    "src/net/fake_interactions.zig",
    "src/net/fake_conta.zig",
    "src/ui/emoji_data.zig",
}
# Recebem pt/en e de propósito não passam pelo i18n: mensagens para quem escreve
# plugins (o runtime não conhece o i18n), os dados da demonstração e as palavras
# que vão na consulta da busca (o analisador só entende português e inglês).
NOT_I18N = {
    ("src/plugins/runtime.zig", "tr"),
    ("src/plugins/runtime.zig", "raiseFmt"),
    ("src/plugins/engine.zig", "runtime_tr"),
    ("src/net/fake_gateway.zig", "pick"),
    ("src/ui/search_sugg.zig", "word"),
}
KEYWORDS = {"if", "while", "for", "switch", "catch", "orelse", "return", "and", "or", "try", "else", "defer", "errdefer"}


# --- Lendo o Zig ----------------------------------------------------------------

TOKEN = re.compile(
    r"""
    (?P<nl>\n)
  | (?P<ws>[ \t\r]+)
  | (?P<comment>//[^\n]*)
  | (?P<mline>\\\\[^\n]*)
  | (?P<str>"(?:[^"\\\n]|\\.)*")
  | (?P<char>'(?:[^'\\\n]|\\.)*')
  | (?P<id>@"(?:[^"\\\n]|\\.)*"|@?[A-Za-z_][A-Za-z0-9_]*)
  | (?P<num>[0-9][0-9A-Za-z_.]*)
  | (?P<op>\+\+|.)
    """,
    re.X,
)


def zig_unescape(body):
    """O texto de uma string do Zig, sem as aspas, com os escapes resolvidos."""
    out = bytearray()
    i = 0
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out += ch.encode()
            i += 1
            continue
        e = body[i + 1]
        if e in 'nrt\\\'"':
            out += {"n": b"\n", "r": b"\r", "t": b"\t"}.get(e, e.encode())
            i += 2
        elif e == "x":
            out.append(int(body[i + 2 : i + 4], 16))
            i += 4
        elif e == "u":
            end = body.index("}", i)
            out += chr(int(body[i + 3 : end], 16)).encode()
            i = end + 1
        else:
            raise ValueError("escape desconhecido: \\" + e)
    return out.decode("utf-8", "surrogateescape")


class Tok:
    __slots__ = ("kind", "text", "value", "line")

    def __init__(self, kind, text, value, line):
        self.kind, self.text, self.value, self.line = kind, text, value, line

    def __repr__(self):
        return f"{self.kind}:{self.text!r}@{self.line}"


def lex(src):
    toks = []
    line = 1
    mline = None  # string de várias linhas em andamento
    for m in TOKEN.finditer(src):
        kind = m.lastgroup
        text = m.group()
        if kind == "nl":
            line += 1
            continue
        if kind == "ws":
            continue
        if kind == "mline":
            part = text[2:]
            if mline is not None and mline.line + mline.value.count("\n") + 1 == line:
                mline.value += "\n" + part
            else:
                mline = Tok("str", text, part, line)
                toks.append(mline)
            continue
        mline = None
        if kind == "comment":
            continue
        if kind == "str":
            toks.append(Tok("str", text, zig_unescape(text[1:-1]), line))
        else:
            toks.append(Tok(kind, text, None, line))
    return toks


def match_close(toks, i):
    """Índice do fechamento do (, [ ou { em toks[i]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j].text
        if toks[j].kind != "op":
            continue
        if t in pairs:
            depth += 1
        elif t in (")", "]", "}"):
            depth -= 1
            if depth == 0:
                return j
    return len(toks) - 1


def split_args(toks, open_i, close_i):
    """Os argumentos entre toks[open_i] = '(' e toks[close_i] = ')'."""
    args, cur, depth = [], [], 0
    for t in toks[open_i + 1 : close_i]:
        if t.kind == "op" and t.text in "([{":
            depth += 1
        elif t.kind == "op" and t.text in ")]}":
            depth -= 1
        if depth == 0 and t.kind == "op" and t.text == ",":
            args.append(cur)
            cur = []
            continue
        cur.append(t)
    if cur:
        args.append(cur)
    return args


def literal(arg):
    """O texto de um argumento feito só de strings (com ++), ou None."""
    if not arg or len(arg) % 2 == 0:
        return None
    parts = []
    for k, t in enumerate(arg):
        if k % 2 == 0:
            if t.kind != "str":
                return None
            parts.append(t.value)
        elif not (t.kind == "op" and t.text == "++"):
            return None
    return "".join(parts)


def callee(toks, open_i):
    """`p.toggle` para o ( em toks[open_i]; None se não for chamada."""
    j = open_i - 1
    if j < 0 or toks[j].kind != "id":
        return None
    name = [toks[j].text]
    if j >= 2 and toks[j - 1].text == "." and toks[j - 2].kind == "id":
        name.insert(0, toks[j - 2].text)
    return ".".join(name)


class File:
    def __init__(self, path, text):
        self.path = path
        self.rel = path.relative_to(ROOT).as_posix()
        self.text = text
        self._toks = None
        self.skip = None

    @property
    def toks(self):
        if self._toks is None:
            self._toks = lex(self.text)
            self.skip = self._test_blocks()
        return self._toks

    def _test_blocks(self):
        """Faixas de tokens dentro de `test "..." { }`."""
        out = []
        toks = self.toks
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.kind == "id" and t.text == "test" and (i == 0 or toks[i - 1].text in ("}", ";")):
                j = i + 1
                while j < len(toks) and toks[j].text != "{":
                    j += 1
                end = match_close(toks, j)
                out.append((i, end))
                i = end
            i += 1
        return out

    def in_test(self, i):
        _ = self.toks
        return any(a <= i <= b for a, b in self.skip)


# --- Funções que repassam o par -------------------------------------------------


class Wrapper:
    def __init__(self, f, name, pub, nparams, pt_i, en_i, calls):
        self.file, self.name, self.pub = f, name, pub
        self.nparams, self.pt_i, self.en_i = nparams, pt_i, en_i
        self.calls = calls  # (módulo ou None, nome) chamados com pt/en no corpo
        self.base = None  # o i18n.* a que chega, quando chega


def find_wrappers(files):
    found = []
    for f in files:
        if f.rel == "src/ui/i18n.zig":
            continue
        toks = f.toks
        for i, t in enumerate(toks):
            if not (t.kind == "id" and t.text == "fn" and i + 2 < len(toks) and toks[i + 1].kind == "id" and toks[i + 2].text == "("):
                continue
            close = match_close(toks, i + 2)
            params = split_args(toks, i + 2, close)
            names = []
            for p in params:
                ids = [x.text for x in p if x.kind == "id" and x.text not in ("comptime", "noalias")]
                names.append(ids[0] if ids else "")
            if "pt" not in names or not ({"en", "english"} & set(names)):
                continue
            pt_i = names.index("pt")
            en_i = names.index("en") if "en" in names else names.index("english")
            # O corpo: o primeiro { fora do tipo de retorno.
            j = close + 1
            while j < len(toks) and not (toks[j].text == "{" and toks[j - 1].text not in ("struct", "union", "enum", "error", "opaque")):
                if toks[j].text == ";":
                    break
                j += 1
            if j >= len(toks) or toks[j].text != "{":
                continue
            end = match_close(toks, j)
            calls = []
            for k in range(j, end):
                if toks[k].text == "(" and toks[k - 1].kind == "id":
                    args = split_args(toks, k, match_close(toks, k))
                    flat = [{x.text for x in a} for a in args]
                    if any("pt" in a for a in flat) and any(({"en", "english"} & a) for a in flat):
                        mod = toks[k - 3].text if k >= 3 and toks[k - 2].text == "." else None
                        calls.append((mod, toks[k - 1].text))
            pub = i > 0 and toks[i - 1].text == "pub"
            found.append(Wrapper(f, toks[i + 1].text, pub, len(params), pt_i, en_i, calls))
    # Chega ao i18n direto ou por outra que chega (até parar de mudar).
    changed = True
    while changed:
        changed = False
        for w in found:
            if w.base is not None:
                continue
            for mod, name in w.calls:
                if mod == "i18n" and name in BASE:
                    w.base = name
                else:
                    other = next((o for o in found if o.name == name and o.base is not None and (o.pub or o.file is w.file)), None)
                    if other is not None:
                        w.base = other.base
                if w.base is not None:
                    changed = True
                    break
    return found


# --- Os textos -------------------------------------------------------------------


class Use:
    __slots__ = ("key", "fmt", "file", "line", "ctx", "one")

    def __init__(self, key, fmt, file, line, ctx, one=None):
        self.key, self.fmt, self.file, self.line, self.ctx = key, fmt, file, line, ctx
        # i18n.plural: o singular em inglês (a chave é o plural).
        self.one = one


def enclosing(toks, i):
    """A chamada (ou o campo) em volta do token i, para dar contexto."""
    if i >= 3 and toks[i - 1].text == "=" and toks[i - 2].kind == "id" and toks[i - 3].text == ".":
        field = "." + toks[i - 2].text
    elif i >= 3 and toks[i - 1].text == "=" and toks[i - 2].kind == "id" and toks[i - 3].text in ("const", "var"):
        return toks[i - 3].text + " " + toks[i - 2].text
    else:
        field = None
    depth = 0
    for j in range(i - 1, max(-1, i - 400), -1):
        t = toks[j].text
        if toks[j].kind != "op":
            continue
        if t in (")", "]", "}"):
            depth += 1
        elif t in ("(", "[", "{"):
            if depth == 0:
                if t == "(":
                    name = callee(toks, j)
                    if name and name.split(".")[-1] not in KEYWORDS and not name.startswith("i18n."):
                        return f"{field} em {name}" if field else name
                elif t == "{" and field:
                    return field
            else:
                depth -= 1
    return field or ""


def explained(arg):
    """O inglês de uma chamada com texto de variável vem de um lugar que este script
    lê: um campo de tabela (`x.en`, `x.label_en`, `x.teclas`) ou o parâmetro `en` /
    `english` de quem repassa para o i18n."""
    texts = [t.text for t in arg]
    if len(texts) == 1 and texts[0] in ("en", "english"):
        return True
    last = texts[-1] if texts else ""
    return len(texts) >= 2 and texts[-2] == "." and (last == "en" or last.endswith("_en") or last == "teclas")


def collect(files):
    wrappers = [w for w in find_wrappers(files) if w.base is not None]
    uses = []
    dynamic = []
    for f in files:
        toks = f.toks
        for i, t in enumerate(toks):
            if t.kind != "id" or i + 1 >= len(toks) or toks[i + 1].text != "(":
                # Tabela: `.en = "..."` dentro de .{ ... }.
                if t.kind == "id" and (t.text == "en" or t.text.endswith("_en") or t.text == "teclas") and i >= 2 and toks[i - 1].text == "." and toks[i - 2].text in ("{", ",") and i + 2 < len(toks) and toks[i + 1].text == "=":
                    if f.rel in SKIP_TABLES or f.in_test(i):
                        continue
                    end = i + 2
                    while end < len(toks) and not (toks[end].text in (",", "}") and toks[end].kind == "op"):
                        end += 1
                    value = literal(toks[i + 2 : end])
                    if value is None:
                        continue
                    # O resto da estrutura: com `.ja` ela tem o próprio japonês;
                    # `.teclas` só vale com `.teclas_pt`.
                    open_i = i - 2
                    while open_i > 0 and not (toks[open_i].text == "{" and toks[open_i - 1].text == "."):
                        open_i -= 1
                    close_i = match_close(toks, open_i)
                    fields = {toks[k].text for k in range(open_i, close_i) if toks[k].kind == "id" and toks[k - 1].text == "." and toks[k + 1].text == "="}
                    if "ja" in fields or (t.text == "teclas" and "teclas_pt" not in fields):
                        continue
                    uses.append(Use(value, False, f.rel, t.line, "tabela " + "." + t.text))
                continue
            if f.in_test(i) or (i > 0 and toks[i - 1].text == "fn"):
                continue
            name = t.text
            is_base = i >= 2 and toks[i - 1].text == "." and toks[i - 2].text == "i18n" and name in BASE
            cands = []
            if is_base:
                en_i, is_fmt = BASE[name]
                cands.append((en_i - 1, en_i, is_fmt, None))
            else:
                for w in wrappers:
                    if w.name == name and (w.pub or w.file is f):
                        cands.append((w.pt_i, w.en_i, w.base in FORMAT_FNS, w))
            if not cands:
                continue
            close = match_close(toks, i + 1)
            args = split_args(toks, i + 1, close)
            method = toks[i - 1].text == "." and not is_base
            for pt_i, en_i, is_fmt, w in cands:
                if w is not None:
                    shift = 1 if (method and len(args) == w.nparams - 1) else 0
                    if len(args) != w.nparams - shift:
                        continue
                    pt_i -= shift
                    en_i -= shift
                if en_i >= len(args):
                    continue
                en = literal(args[en_i])
                pt = literal(args[pt_i])
                if en is None or (w is not None and pt is None):
                    if is_base:
                        dynamic.append((f.rel, args[en_i][0].line, explained(args[en_i]), " ".join(t.text for t in args[en_i])))
                    continue
                one = literal(args[4]) if is_base and name in PLURAL_FNS and len(args) > 5 else None
                uses.append(Use(en, is_fmt, f.rel, args[en_i][0].line, enclosing(toks, i - 2) if is_base else name, one))
                break
    return uses, dynamic


THEMES = ROOT / "themes"
# description-en e label-en (o tema e as opções), e o en= / text-en= dos textos
# desenhados (span "TRIPULAÇÃO" en="CREW"), que src/ui/display_text.zig procura igual.
THEME_EN = re.compile(r'(?<![\w-])(?:(?:description|label|text)-)?en="((?:[^"\\]|\\.)*)"')


def theme_uses():
    """Os textos em inglês dos temas embutidos (themes/builtin.zig): a descrição do
    tema, o nome e a descrição de cada opção e os textos desenhados. O app procura esse
    inglês nas tabelas (themeText em src/ui/settings.zig, display_text.zig). Temas da
    comunidade ficam só em pt/en."""
    names = re.findall(r'@embedFile\("([^"]+\.kdl)"\)', (THEMES / "builtin.zig").read_text(encoding="utf-8"))
    uses = []
    for name in names:
        path = THEMES / name
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for m in THEME_EN.finditer(line):
                text = re.sub(r"\\(.)", lambda e: {"n": "\n", "t": "\t"}.get(e.group(1), e.group(1)), m.group(1))
                if text:
                    uses.append(Use(text, False, path.relative_to(ROOT).as_posix(), n, "tema " + name[:-4]))
    return uses


_files = None


def source_files():
    """Os .zig que podem ter textos (os outros nem são lidos como Zig: é bem mais rápido)."""
    global _files
    if _files is not None:
        return _files
    every = [File(p, p.read_text(encoding="utf-8")) for p in sorted(SRC.rglob("*.zig")) if not SKIP_FILES.match(p.name)]
    maybe = [f for f in every if re.search(r"\bpt\s*:", f.text) and re.search(r"\b(en|english)\s*:", f.text)]
    names = {w.name for w in find_wrappers(maybe) if w.base is not None}
    call = re.compile(r"\b(" + "|".join(sorted(names)) + r")\s*\(") if names else None
    table = re.compile(r"\.(en|\w+_en|teclas)\s*=\s*\"")
    _files = [f for f in every if "i18n." in f.text or (call and call.search(f.text)) or (f.rel not in SKIP_TABLES and table.search(f.text))]
    return _files


# --- Marcadores ------------------------------------------------------------------


def parse_format(text):
    """Os marcadores de um texto de formato: lista de (argumento, interior), ou None
    quando o std.fmt não aceitaria ou quando o app não traduz (argumento com nome)."""
    out = []
    nxt = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "}":
            if text[i + 1 : i + 2] == "}":
                i += 2
                continue
            return None
        if ch != "{":
            i += 1
            continue
        if text[i + 1 : i + 2] == "{":
            i += 2
            continue
        close = text.find("}", i + 1)
        if close < 0:
            return None
        inner = text[i + 1 : close]
        if "[" in inner or "{" in inner:
            return None
        m = re.match(r"\d*", inner)
        if m.group():
            arg = int(m.group())
        else:
            arg = nxt
            nxt += 1
        if arg >= 32 or len(out) >= 32:
            return None
        out.append((arg, inner))
        i = close + 1
    return out


def check_template(tpl, english):
    """None se a tradução serve para o texto de formato `english`; senão o porquê."""
    phs = parse_format(english)
    if phs is None:
        return None  # o app nunca traduz esse texto: nada a conferir
    need = {a for a, _ in phs}
    used = set()
    mode = None
    seq = 0
    i = 0
    while i < len(tpl):
        ch = tpl[i]
        if ch not in "{}":
            i += 1
            continue
        if tpl[i + 1 : i + 2] == ch:
            i += 2
            continue
        if ch == "}":
            return "'}' sozinha (use '}}')"
        close = tpl.find("}", i + 1)
        if close < 0:
            return "'{' sem fechar (use '{{' para a chave)"
        inner = tpl[i + 1 : close]
        if inner.isdigit():
            if mode == "copy":
                return "mistura {N} com marcadores copiados"
            mode = "index"
            k = int(inner)
            if k >= len(phs):
                return f"{{{inner}}}: o inglês só tem {len(phs)} marcador(es)"
        else:
            if mode == "index":
                return "mistura {N} com marcadores copiados"
            mode = "copy"
            if seq >= len(phs):
                return f"{{{inner}}} a mais: o inglês tem {len(phs)}"
            if inner != phs[seq][1]:
                return f"{{{inner}}} no lugar de {{{phs[seq][1]}}}"
            k = seq
            seq += 1
        used.add(phs[k][0])
        i = close + 1
    if mode == "copy" and seq != len(phs):
        return f"faltam marcadores: {seq} de {len(phs)}"
    if used != need:
        return "falta algum valor do inglês"
    return None


# --- O arquivo de tradução (subconjunto do KDL do src/theme/kdl.zig) ----------------


class KdlError(Exception):
    pass


HEADER_NODES = ("language", "direction", "font-script", "plurals")
CATEGORIES = ("zero", "one", "two", "few", "many", "other")


class Entry:
    """Uma entrada: a chave, o texto (o que vale para as formas que faltam), as formas de
    plural ({categoria: texto}), a linha e se está comentada com /- (fora do app)."""

    __slots__ = ("key", "value", "forms", "line", "dropped", "comments")

    def __init__(self, key, value, forms, line, dropped=False, comments=None):
        self.key, self.value, self.forms, self.line, self.dropped = key, value, forms, line, dropped
        # Os comentários // logo acima (os //: de contexto ficam de fora: são refeitos).
        self.comments = comments or []

    def text(self):
        """O texto sem contagem: o solto, ou a última forma (other, many…), como o app."""
        if self.value:
            return self.value
        for cat in reversed(CATEGORIES):
            if self.forms.get(cat):
                return self.forms[cat]
        return ""

    def translated(self):
        """Tem tradução de verdade: algum texto não vazio e diferente do inglês."""
        return any(v and v != self.key for v in [self.value, *self.forms.values()])


class TransFile:
    def __init__(self):
        self.header = {}  # language, code, english, direction, font-script, plurals
        self.header_line = {}
        self.entries = []
        self.head_text = ""  # tudo antes da primeira entrada (comentários e cabeçalho)


def parse_file(text, name="arquivo"):
    """O arquivo de tradução inteiro, como o app lê (src/ui/i18n.zig `parseFile`), mais as
    entradas comentadas com /- e os comentários. Texto vazio é tradução que falta (o app
    ignora). Erro de sintaxe ou de forma: KdlError com arquivo:linha."""
    out = TransFile()
    i, n, line = 0, len(text), 1
    pending_comments = []

    def fail(msg, at=None):
        raise KdlError(f"{name}:{at or line}: {msg}")

    def skip(newlines):
        nonlocal i, line
        while i < n:
            ch = text[i]
            if ch in " \t\r":
                i += 1
            elif ch == "\n" and newlines:
                i += 1
                line += 1
            elif ch == "\\":
                i += 1
                while i < n and text[i] in " \t\r":
                    i += 1
                if text.startswith("//", i):
                    while i < n and text[i] != "\n":
                        i += 1
                if i < n and text[i] == "\n":
                    i += 1
                    line += 1
            elif text.startswith("//", i):
                start = i
                while i < n and text[i] != "\n":
                    i += 1
                if newlines:
                    c = text[start:i]
                    if not c.startswith("//:"):
                        pending_comments.append(c)
            elif text.startswith("/*", i):
                depth = 0
                while i < n:
                    if text.startswith("/*", i):
                        depth += 1
                        i += 2
                    elif text.startswith("*/", i):
                        depth -= 1
                        i += 2
                        if depth == 0:
                            break
                    else:
                        if text[i] == "\n":
                            line += 1
                        i += 1
                if depth != 0:
                    fail("comentário /* sem fechar")
            else:
                break

    def string():
        nonlocal i, line
        i += 1
        buf = []
        while True:
            if i >= n:
                fail("string sem fechar")
            ch = text[i]
            if ch == '"':
                i += 1
                return "".join(buf)
            if ch == "\\":
                e = text[i + 1 : i + 2]
                r = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "/": "/"}.get(e)
                if r is None:
                    fail("escape inválido: \\" + e)
                buf.append(r)
                i += 2
                continue
            if ch == "\n":
                line += 1
            buf.append(ch)
            i += 1

    def word():
        nonlocal i
        start = i
        while i < n and text[i] not in ' \t\r\n=;{}"()\\':
            i += 1
        if i == start:
            fail("esperava um texto entre aspas")
        return text[start:i]

    first_entry_at = None
    while True:
        skip(True)
        while i < n and text[i] == ";":
            i += 1
            skip(True)
        if i >= n:
            break
        dropped = False
        node_start = i
        if text.startswith("/-", i):
            dropped = True
            i += 2
            skip(True)
        at = line
        quoted = text[i] == '"'
        key = string() if quoted else word()
        args, props = [], {}
        while True:
            skip(False)
            if i >= n or text[i] in "\n;":
                break
            if text[i] in "{}":
                fail("só `\"inglês\" \"tradução\"` por linha (sem blocos)")
            v = string() if text[i] == '"' else word()
            if i < n and text[i] == "=":
                i += 1
                if i >= n or text[i] != '"':
                    fail(f"{v}=: o valor vai entre aspas")
                props[v] = string()
            else:
                args.append(v)
        comments, pending_comments[:] = list(pending_comments), []
        if dropped:
            if quoted and len(args) <= 1:
                out.entries.append(Entry(key, args[0] if args else "", {k: v for k, v in props.items() if k in CATEGORIES}, at, True, comments))
            continue
        if not quoted:
            if key not in HEADER_NODES:
                fail(f"linha desconhecida `{key}` (a entrada vai entre aspas: \"inglês\" \"tradução\")", at)
            if first_entry_at is not None:
                fail(f"`{key}` vai no começo do arquivo, antes das entradas", at)
            if len(args) != 1:
                fail(f"esperava {key} \"…\"", at)
            if key == "language":
                if not args[0]:
                    fail("o nome do idioma está vazio", at)
                out.header["language"] = args[0]
                for k, v in props.items():
                    if k not in ("code", "english"):
                        fail(f"language: propriedade desconhecida {k}= (code=, english=)", at)
                    out.header[k] = v
                code = props.get("code")
                if code is not None and not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,14}", code):
                    fail("code: letras, números e -, até 15 (\"ja\", \"pt-PT\")", at)
            elif key == "direction":
                if args[0] not in ("ltr", "rtl"):
                    fail('direction: "ltr" ou "rtl"', at)
                out.header["direction"] = args[0]
            elif key == "font-script":
                if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,14}", args[0]):
                    fail('font-script: um código como "ja", "zh" ou "ko"', at)
                out.header["font-script"] = args[0]
            elif key == "plurals":
                if rule_forms(args[0]) is None:
                    fail("plurals: um código de idioma que o app conhece", at)
                out.header["plurals"] = args[0]
            out.header_line[key] = at
            continue
        if first_entry_at is None:
            first_entry_at = at
            out.head_text = text[:node_start - sum(len(c) + 1 for c in comments)].rstrip() if comments else text[:node_start].rstrip()
        if not key:
            fail("chave vazia", at)
        if len(args) > 1:
            fail(f"esperava um texto depois da chave, achei {len(args)}", at)
        forms = {}
        for k, v in props.items():
            if k not in CATEGORIES:
                fail(f"forma de plural desconhecida {k}= (zero, one, two, few, many ou other)", at)
            forms[k] = v
        out.entries.append(Entry(key, args[0] if args else "", forms, at, False, comments))
    if first_entry_at is None:
        out.head_text = text.rstrip()
    return out


def kdl_entries(text, name="arquivo"):
    """[(chave, tradução, linha)] das entradas valendo (o texto sem contagem)."""
    return [(e.key, e.text(), e.line) for e in parse_file(text, name).entries if not e.dropped]


def kdl_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r") + '"'


def sort_key(k):
    return (k.casefold(), k)


# --- Plural (a tabela de src/ui/i18n.zig) ------------------------------------------------

_rules = None


def plural_rules():
    """{código: (formas, {forma: "1, 21, 31"})} da tabela `rules` de src/ui/i18n.zig (a mesma
    que o app usa)."""
    global _rules
    if _rules is None:
        src = (SRC / "ui" / "i18n.zig").read_text(encoding="utf-8")
        _rules = {}
        for forms, examples, langs in re.findall(r'\.rule = \.\w+, \.forms = "([^"]*)", \.examples = "([^"]*)", \.langs = "([^"]*)"', src):
            ex = {k: v.replace(",", ", ") for k, v in (part.split("=", 1) for part in examples.split())}
            for code in langs.split():
                _rules[code.lower().replace("_", "-")] = (forms.split(), ex)
    return _rules


def rule_of(code):
    rules = plural_rules()
    c = code.lower().replace("_", "-")
    return rules.get(c) or rules.get(c.split("-")[0])


def rule_forms(code):
    """As formas que os números inteiros usam no idioma (o código com a região, ou sem), ou None."""
    r = rule_of(code)
    return r[0] if r else None


def rule_examples(code):
    """{forma: "1, 21, 31"} para o idioma (ou o inglês)."""
    r = rule_of(code)
    return r[1] if r else {"one": "1", "other": "0, 2, 5"}


def forms_of(header, code):
    """As formas do arquivo: as do `plurals`, as do código, ou as do inglês."""
    return rule_forms(header.get("plurals") or code) or ["one", "other"]


# --- Contexto (o que cada texto é, para quem traduz) ------------------------------------

KINDS = [
    ({"button", "buttonSoft", "textButton", "toolButton", "iconButton", "cornerButton", "roundButton", "accentButton",
      "pageButton", "const cancel", "const close_lbl", "chip", "dspChip", "plainChip", "const back_t"}, "button"),
    ({"tip", "tooltip", "tip_en", "const pick_tip", "dica", "setHint"}, "tooltip"),
    ({"showToast", "notice", "noticeHttp", "desktopNotify", "naoEnviada"}, "notification"),
    ({"toggle", "toggleIf", "segmented", "slider", "stepper", "colorRow", "picker", "radio"}, "setting"),
    ({"note", "markedNote", "footNote", "para", "footer", "wrapText", "wrapFlow", "desc"}, "description"),
    ({"heading", "section", "title", "title_en", "titulo", "head", "const title"}, "title"),
    ({"fail", "setProblem", "complain", "sessionRefused", "raise", "raiseFmt"}, "error message"),
    ({"textInput", "ImGui_InputTextWithHint", "ImGui_InputTextWithHintEx", "proxyField", "search", "const hint", "hint"}, "text box placeholder"),
    ({"empty", "offline"}, "empty state"),
    ({"label", "const label", "label_en", "name", "name_en", "const lbl", "kv", "statRow"}, "label"),
]


def kind_of(u):
    """Botão, dica, aviso, configuração… a partir de onde o texto aparece (em inglês: vai no
    comentário de quem traduz)."""
    ctx = u.ctx or ""
    if ctx.startswith("tema "):
        return "theme text"
    if ctx.startswith("tray.") or ctx.endswith("em tray.show"):
        return "tray menu item"
    last = ctx.split(" em ")[-1]
    tail = last.split(".")[-1]
    field = ctx.split(" em ")[0] if " em " in ctx else ""
    for names, kind in KINDS:
        if last in names or tail in names or field.lstrip(".") in names:
            if kind == "label" and ("menu" in u.file or "menu" in ctx.lower()):
                return "menu item"
            return kind
    if "menu" in u.file or "menu" in ctx.lower():
        return "menu item"
    if ctx.startswith("tabela"):
        return "list entry"
    if "settings" in u.file:
        return "settings text"
    return "text"


def context_line(uses):
    """`//: src/ui/x.zig:12 · button · +2 more places · plural, one: "{d} vote"` para a primeira
    vez que o texto aparece."""
    u = uses[0]
    parts = [f"{u.file}:{u.line}", kind_of(u)]
    if len(uses) > 1:
        parts.append(f"+{len(uses) - 1} more place{'s' if len(uses) > 2 else ''}")
    one = next((x.one for x in uses if x.one), None)
    if one is not None:
        parts.append(f"count; English singular: {kdl_quote(one)}")
    elif any(x.fmt for x in uses) and parse_format(u.key):
        parts.append("placeholders: " + " ".join("{" + inner + "}" for _, inner in parse_format(u.key)))
    return "//: " + " · ".join(parts)


# --- Conferindo -------------------------------------------------------------------------


def load_lang(lang):
    path = ROOT / "i18n" / f"{lang}.kdl"
    text = path.read_text(encoding="utf-8") if path.exists() else ""
    return path, text


def lang_files():
    return sorted((ROOT / "i18n").glob("*.kdl"))


def check_file(tf, rel, code, uses):
    """Os erros (arquivo que o app não lê direito) e os avisos de um arquivo de tradução."""
    errors, warnings = [], []
    keys = {u.key for u in uses}
    fmt_keys = {u.key for u in uses if u.fmt}
    plural_keys = {u.key for u in uses if u.one is not None}
    h = tf.header
    if "language" not in h:
        errors.append((1, f'falta `language "Nome" code="{code}"` no começo do arquivo'))
    elif h.get("code") is None:
        errors.append((tf.header_line["language"], f'language: falta code="{code}"'))
    elif rel.startswith("i18n/") and h["code"] != code:
        errors.append((tf.header_line["language"], f'language: code="{h["code"]}" num arquivo {code}.kdl'))
    forms_ok = set(forms_of(h, h.get("code") or code)) | {"other"}
    seen = {}
    for e in tf.entries:
        if e.dropped:
            continue
        if e.key in seen:
            errors.append((e.line, f"chave repetida (a primeira na linha {seen[e.key]}): {e.key!r}"))
        seen.setdefault(e.key, e.line)
        texts = [("", e.value)] + [(k + "=", v) for k, v in e.forms.items()]
        if e.key in fmt_keys:
            for label, v in texts:
                if not v:
                    continue
                why = check_template(v, e.key)
                if why:
                    errors.append((e.line, f"{label}{why}: {e.key!r} -> {v!r}"))
        if e.forms and e.key in keys and e.key not in plural_keys:
            warnings.append((e.line, f"formas de plural num texto sem contagem (o app só usa o texto solto): {e.key!r}"))
        if e.key in plural_keys:
            extra = set(e.forms) - forms_ok
            if extra:
                warnings.append((e.line, f"forma{'s' if len(extra) > 1 else ''} que o idioma não usa ({', '.join(sorted(extra))}): {e.key!r}"))
    return errors, warnings


def keys_text(uses):
    def esc(k):
        return k.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
    return "".join(esc(k) + "\n" for k in sorted({u.key for u in uses}, key=sort_key))


KEYS_FILE = ROOT / "i18n" / "keys.txt"


def cmd_keys(uses):
    KEYS_FILE.write_text(keys_text(uses), encoding="utf-8")
    print(f"{KEYS_FILE.relative_to(ROOT).as_posix()}: {len({u.key for u in uses})} textos")
    return 0


def coverage(tf, keys):
    """(traduzidos, total) dos textos do código (a entrada igual ao inglês não conta)."""
    done = {e.key for e in tf.entries if not e.dropped and e.key in keys and e.translated()}
    return len(done), len(keys)


def language_status(uses):
    """O estado de cada i18n/*.kdl, para o site (tools/gen_site.py) e o --check."""
    keys = {u.key for u in uses}
    out = []
    for path in lang_files():
        tf = parse_file(path.read_text(encoding="utf-8"), path.name)
        done, total = coverage(tf, keys)
        live = [e for e in tf.entries if not e.dropped]
        have = {e.key for e in live}
        h = tf.header
        out.append({
            "code": h.get("code", path.stem), "name": h.get("language", path.stem), "english": h.get("english", ""),
            "rtl": h.get("direction") == "rtl", "file": path.name, "translated": done, "total": total,
            "missing": len(keys - have) + sum(1 for e in live if e.key in keys and not e.text()),
            "placeholders": sum(1 for e in live if e.key in keys and e.text() and not e.translated()),
            "stale": len(have - keys), "forms": forms_of(h, h.get("code", path.stem)),
        })
    return out


def cmd_check(uses, dynamic, lang, strict=False, file=None):
    keys = {u.key for u in uses}
    fmt_keys = {u.key for u in uses if u.fmt}
    unexplained = [d for d in dynamic if not d[2]]
    print(f"textos no código: {len(keys)} ({len(fmt_keys)} de formato; {sum(1 for u in uses if u.one) and len({u.key for u in uses if u.one})} com contagem; {len(dynamic)} chamadas com texto de variável)")
    paths = [Path(file).resolve()] if file else [ROOT / "i18n" / f"{lang}.kdl"] if lang else lang_files()
    bad = False
    missing_total = 0
    for path in paths:
        rel = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)
        if not path.exists():
            print(f"erro: {rel} não existe", file=sys.stderr)
            bad = True
            continue
        try:
            tf = parse_file(path.read_text(encoding="utf-8"), rel)
        except KdlError as e:
            print(f"erro: {e}", file=sys.stderr)
            bad = True
            continue
        errors, warnings = check_file(tf, rel, path.stem, uses)
        live = [e for e in tf.entries if not e.dropped]
        have = {e.key for e in live if e.text()}
        missing = keys - have
        missing_total += len(missing)
        stale = sorted({e.key for e in live} - keys, key=sort_key)
        done, total = coverage(tf, keys)
        print(f"{rel} ({tf.header.get('language', '?')}): {len(live)} traduções, {done} de {total} textos traduzidos ({100 * done // max(total, 1)}%)")
        print(f"aviso: {rel}: {len(missing)} sem tradução (aparecem em inglês)")
        # A tradução igual ao inglês é espaço reservado: o texto de máquina que voltou para o
        # inglês, ou o texto novo que entra assim até alguém traduzir (nomes e siglas ficam
        # iguais mesmo).
        same = [e for e in live if e.key in keys and e.text() and not e.translated()]
        if same:
            print(f"aviso: {rel}: {len(same)} iguais ao inglês, para traduzir (menos nomes e siglas, que ficam assim)")
        if stale:
            print(f"aviso: {rel}: {len(stale)} que o código não usa mais:")
            for k in stale:
                line = next(e.line for e in live if e.key == k)
                print(f"  {rel}:{line}: {k!r}")
        for line, msg in warnings:
            print(f"aviso: {rel}:{line}: {msg}")
        for line, msg in errors:
            print(f"erro: {rel}:{line}: {msg}", file=sys.stderr)
        bad = bad or bool(errors)
    # Inglês que vem de uma variável que este script não lê: a tradução só existe se
    # o mesmo texto aparecer escrito em outro lugar. Use um campo .en ou um texto direto.
    for file, line, _, expr in unexplained:
        print(f"aviso: {file}:{line}: o inglês vem de `{expr}`, que este script não lê")
    every = [File(p, p.read_text(encoding="utf-8")) for p in sorted(SRC.rglob("*.zig")) if not SKIP_FILES.match(p.name)]
    for w in find_wrappers([f for f in every if re.search(r"\bpt\s*:", f.text)]):
        if w.base is None and (w.file.rel, w.name) not in NOT_I18N:
            print(f"aviso: {w.file.rel}: {w.name}() recebe pt/en mas não passa pelo i18n (os arquivos de tradução não chegam lá)")
    # A lista que o app usa para a porcentagem de cada idioma.
    want = keys_text(uses)
    if not KEYS_FILE.exists() or KEYS_FILE.read_text(encoding="utf-8") != want:
        print("aviso: i18n/keys.txt desatualizado (a porcentagem no app sai um pouco errada): python3 tools/i18n_strings.py --keys")
    if strict and (missing_total or unexplained):
        print(f"erro: --strict: {missing_total} sem tradução, {len(unexplained)} chamadas com inglês que o script não lê", file=sys.stderr)
        return 1
    return 1 if bad else 0


def cmd_json(uses):
    """O que o teste do editor do site compara com o leitor e a checagem dele."""
    fmt_keys = {u.key for u in uses if u.fmt}
    checks, files = [], {}
    for path in lang_files():
        tf = parse_file(path.read_text(encoding="utf-8"), path.name)
        files[path.name] = {"code": tf.header.get("code"), "name": tf.header.get("language"), "entries": len(tf.entries),
                            "dropped": sum(1 for e in tf.entries if e.dropped)}
        for e in tf.entries:
            for v in [e.value, *e.forms.values()]:
                if v and e.key in fmt_keys:
                    checks.append([e.key, v, check_template(v, e.key)])
    json.dump({"keys": sorted({u.key for u in uses}, key=sort_key), "fmt": sorted(fmt_keys, key=sort_key), "checks": checks, "files": files}, sys.stdout, ensure_ascii=False)
    return 0


def first_uses(uses):
    by_key = {}
    for u in uses:
        by_key.setdefault(u.key, []).append(u)
    return by_key


def entry_text(key, value, forms, comments=(), dropped=False):
    """As linhas de uma entrada: os comentários, e a entrada (com /- se ficou de fora)."""
    s = kdl_quote(key)
    if value or not forms:
        s += " " + kdl_quote(value)
    for cat in CATEGORIES:
        if cat in forms:
            s += f" {cat}={kdl_quote(forms[cat])}"
    return list(comments) + [("/-" if dropped else "") + s]


def header_lines(code, name, english, forms):
    return [
        f"// larperCord — {english or name} ({name}) interface text.",
        "//",
        "// Fill in the second text of each line; an empty one shows in English. The //: line above",
        "// each entry says where the text is and what it is. Placeholders ({s}, {d}…) must stay:",
        "// copy them as they are, or write {0}, {1}… to change their order. Text with a count has one",
        f"// form per plural category of this language ({', '.join(forms)}).",
        "// The guide: https://rshacudevidro.github.io/larperCord/guide/translating.html",
        "// Try it without building: put this file in the larpercord/i18n folder of the settings",
        "// (~/.config on Linux, %APPDATA% on Windows); saving it updates the app.",
        "",
        f"language {kdl_quote(name)} code={kdl_quote(code)}" + (f" english={kdl_quote(english)}" if english else ""),
    ]


def forms_hint(code_or_plurals):
    """`//: one = 1, 21, 31 · few = 2, 3, 4, 22 · many = 0, 5, 11, 12, 14`: que números caem em cada forma."""
    ex = rule_examples(code_or_plurals)
    forms = rule_forms(code_or_plurals) or ["one", "other"]
    return "//: " + " · ".join(f"{f} = {ex.get(f, '')}" for f in forms)


def template_entry(key, uses, forms, context=True, rule_code=None):
    is_plural = any(u.one is not None for u in uses)
    comments = [context_line(uses)] if context else []
    if is_plural and forms != ["other"]:
        if context and rule_code:
            comments.append(forms_hint(rule_code))
        return entry_text(key, "", {f: "" for f in forms}, comments)
    return entry_text(key, "", {}, comments)


def cmd_template(uses, code, name, english, out):
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,14}", code):
        print("erro: o código é como ja, de, pt-PT (letras, números e -)", file=sys.stderr)
        return 1
    if code.lower() in ("pt", "en"):
        print("erro: português e inglês ficam no código (src/**/*.zig), não num arquivo", file=sys.stderr)
        return 1
    forms = forms_of({}, code)
    by_key = first_uses(uses)
    lines = header_lines(code, name or code, english or "", forms)
    for key in sorted(by_key, key=sort_key):
        lines.append("")
        lines += template_entry(key, by_key[key], forms, True, code)
    text = "\n".join(lines) + "\n"
    if out:
        Path(out).write_text(text, encoding="utf-8")
        print(f"{out}: {len(by_key)} textos para traduzir ({code}, plural: {' '.join(forms)})")
    else:
        sys.stdout.write(text)
    return 0


def cmd_update(uses, src_file, context=True):
    """Os textos novos entram vazios, os que o código não usa mais ficam com /- (a tradução
    não se perde: se o texto voltar, a entrada volta a valer), e os //: são refeitos."""
    path = Path(src_file)
    text = path.read_text(encoding="utf-8")
    try:
        tf = parse_file(text, str(src_file))
    except KdlError as e:
        print(f"erro: {e}", file=sys.stderr)
        return 1
    code = tf.header.get("code") or path.stem
    forms = forms_of(tf.header, code)
    by_key = first_uses(uses)
    entries = {}
    for e in tf.entries:
        # Uma entrada valendo ganha da comentada com a mesma chave.
        if e.key in entries and e.dropped:
            continue
        entries[e.key] = e
    added = stale = revived = 0
    lines = tf.head_text.split("\n") if tf.head_text else header_lines(code, code, "", forms)
    if "language" not in tf.header:
        lines += ["", f"language {kdl_quote(code)} code={kdl_quote(code)}"]
    for key in sorted(set(entries) | set(by_key), key=sort_key):
        lines.append("")
        e = entries.get(key)
        if e is None:
            lines += template_entry(key, by_key[key], forms, context, tf.header.get("plurals") or code)
            added += 1
            continue
        live = key in by_key
        if live and e.dropped:
            revived += 1
        if not live and not e.dropped:
            stale += 1
        ctx = [context_line(by_key[key])] if live and context else []
        if ctx and e.forms and any(u.one is not None for u in by_key[key]):
            ctx.append(forms_hint(tf.header.get("plurals") or code))
        if not live:
            ctx = ["//: the app no longer uses this text (kept so the translation isn't lost)"]
        lines += entry_text(key, e.value, e.forms, e.comments + ctx, dropped=not live)
    path.write_text("\n".join(lines).rstrip("\n") + "\n", encoding="utf-8")
    print(f"{src_file}: {added} novos (vazios), {stale} fora de uso (com /-), {revived} de volta")
    return 0


def cmd_pending(uses, lang, out_dir, chunks):
    path, text = load_lang(lang)
    have = {k for k, v, _ in kdl_entries(text, path.name) if v}
    by_key = first_uses(uses)
    pend = [(us[0], len(us)) for k, us in by_key.items() if k not in have]
    pend.sort(key=lambda p: (p[0].file, p[0].line, p[0].key))
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("pendentes-*.kdl"):
        old.unlink()
    size = -(-len(pend) // chunks) if pend else 0
    paths = []
    for c in range(chunks):
        part = pend[c * size : (c + 1) * size]
        p = out_dir / f"pendentes-{c + 1}.kdl"
        lines = [
            f"// {lang}: textos sem tradução, parte {c + 1} de {chunks} ({len(part)} textos).",
            "// Preencha o segundo texto de cada linha; linhas com \"\" ficam de fora ao juntar.",
            "// O comentário diz onde o texto aparece (arquivo:linha, a função em volta);",
            "// \"formato\" = tem marcadores {…} (veja as regras no topo de i18n/" + lang + ".kdl).",
            "",
        ]
        for u, count in part:
            where = f"{u.file}:{u.line}"
            if u.ctx:
                where += f" {u.ctx}"
            if count > 1:
                where += f" (+{count - 1} lugar{'es' if count > 2 else ''})"
            if u.fmt and parse_format(u.key):
                where += " formato"
            lines.append(f'{kdl_quote(u.key)} ""  // {where}')
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        paths.append((p, len(part)))
    for p, n in paths:
        print(f"{p}: {n}")
    print(f"total: {len(pend)}")
    return 0


def cmd_merge(uses, lang, src_file):
    path, text = load_lang(lang)
    rel = path.relative_to(ROOT).as_posix()
    tf = parse_file(text, rel)
    table = {e.key: e for e in tf.entries if not e.dropped}
    fmt_keys = {u.key for u in uses if u.fmt}
    keys = {u.key for u in uses}
    added = replaced = 0
    bad = []
    for e in parse_file(Path(src_file).read_text(encoding="utf-8"), str(src_file)).entries:
        if e.dropped or not e.text():
            continue
        if e.key not in keys:
            bad.append(f"{src_file}:{e.line}: o código não usa este texto: {e.key!r}")
            continue
        if e.key in fmt_keys:
            why = next((w for v in [e.value, *e.forms.values()] if v for w in [check_template(v, e.key)] if w), None)
            if why:
                bad.append(f"{src_file}:{e.line}: {why}: {e.key!r} -> {e.text()!r}")
                continue
        if e.key in table:
            old = table[e.key]
            replaced += (old.value, old.forms) != (e.value, e.forms)
        else:
            added += 1
        table[e.key] = Entry(e.key, e.value, {k: v for k, v in e.forms.items() if v}, 0)
    write_lang(path, tf, table)
    for b in bad:
        print(f"fora: {b}", file=sys.stderr)
    print(f"{rel}: {added} novas, {replaced} trocadas, {len(bad)} recusadas, {len(table)} no total")
    return 1 if bad else 0


def write_lang(path, tf, table):
    """Grava o arquivo com o começo de antes (comentários e cabeçalho) e as entradas em ordem."""
    body = []
    for k in sorted(table, key=sort_key):
        e = table[k]
        body += entry_text(k, e.value, e.forms, e.comments)
    head = tf.head_text
    path.write_text((head.rstrip("\n") + "\n\n" if head else "") + "\n".join(body) + "\n", encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description="Textos da interface para as traduções em i18n/<idioma>.kdl")
    ap.add_argument("--lang", default=None)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--strict", action="store_true", help="com --check: falta de tradução e inglês que o script não lê também são erro")
    ap.add_argument("--file", metavar="ARQUIVO", help="com --check: um arquivo de tradução em qualquer lugar")
    ap.add_argument("--keys", action="store_true", help="grava i18n/keys.txt")
    ap.add_argument("--template", metavar="CÓDIGO")
    ap.add_argument("--name", help="com --template: o nome do idioma na própria língua")
    ap.add_argument("--english", help="com --template: o nome do idioma em inglês")
    ap.add_argument("-o", "--output", metavar="ARQUIVO", help="com --template: grava aqui em vez de mostrar")
    ap.add_argument("--update", metavar="ARQUIVO")
    ap.add_argument("--no-context", action="store_true", help="com --update: sem os comentários //:")
    ap.add_argument("--pending", metavar="PASTA")
    ap.add_argument("--chunks", type=int, default=4)
    ap.add_argument("--merge", metavar="ARQUIVO")
    ap.add_argument("--where", action="store_true", help="com --list: arquivo:linha de cada texto")
    ap.add_argument("--json", action="store_true", help="para tools/translate_test.js: os textos e a checagem de cada tradução")
    a = ap.parse_args()
    files = source_files()
    uses, dynamic = collect(files)
    uses += theme_uses()
    if a.check:
        return cmd_check(uses, dynamic, a.lang, a.strict, a.file)
    if a.json:
        return cmd_json(uses)
    if a.keys:
        return cmd_keys(uses)
    if a.template:
        return cmd_template(uses, a.template, a.name, a.english, a.output)
    if a.update:
        return cmd_update(uses, a.update, not a.no_context)
    if a.pending:
        return cmd_pending(uses, a.lang or "ja", a.pending, max(1, a.chunks))
    if a.merge:
        return cmd_merge(uses, a.lang or "ja", a.merge)
    by_key = first_uses(uses)
    for k in sorted(by_key, key=sort_key):
        if a.where:
            u = by_key[k][0]
            print(f"{kdl_quote(k)}  // {u.file}:{u.line} {u.ctx}{' formato' if any(x.fmt for x in by_key[k]) else ''}")
        else:
            print(kdl_quote(k))
    return 0


if __name__ == "__main__":
    sys.exit(main())

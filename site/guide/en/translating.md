# Translating larperCord

Portuguese and English live in the code. Every other language is one `.kdl` file: the English text of the app on the left, the translation on the right. You don't need Zig, a compiler or the repository to translate: a file in the app's translations folder applies while the app runs, and saving it updates the text on the spot. Adding a language to the app is adding that file to `i18n/`, with no code change.

[Translation status](page:translation-status) shows how far each language is.

## The quick way: the editor

The [translation editor](translate:new) runs in the browser, with nothing sent anywhere:

1. In **Start from**, pick **A new language** (or a language that already exists, to continue it), and fill in its name and code.
2. Translate. Each English text comes with where it is in the code and what it is (a button, a tooltip, a setting, an error…). The missing ones come first, placeholders are checked while you type, and a text with a count asks for each plural form of your language.
3. Press **Download .kdl**. Your work also stays in that browser, so you can close the page and come back.

You can open a `.kdl` you already have (or drop it on the page) and carry on from it.

## The file

```kdl
language "Deutsch" code="de" english="German"

"Sign in" "Anmelden"
"Replying to {s}" "Antwort an {s}"
"{d} votes" one="{d} Stimme" other="{d} Stimmen"
```

The file starts by saying which language it is:

| Line | What it does |
|---|---|
| `language "Deutsch" code="de" english="German"` | The name in the language itself (Settings → Language shows it), the code and the name in English. The code is the ISO 639 one, with a region when that matters: `de`, `pt-PT`, `zh-TW`. The app picks a file over English when the system's language has the same code |
| `direction "rtl"` | Optional. The language is written right to left (Arabic, Hebrew, Persian). The app already shapes and orders each right-to-left text by itself; this also marks exported conversations as right to left |
| `font-script "ja"` | Optional. Which fallback fonts come first when the system has several: `ja`, `ko` or `zh`. By default, the code |
| `plurals "ru"` | Optional. Use another language's plural rules (a code the app doesn't know yet) |

Then one entry per line: the English text exactly as it is in the app, and the translation. Inside the quotes, `\n` is a new line, `\"` a quote and `\\` a backslash; a long entry can go on after a `\` at the end of the line. Lines starting with `//` are comments.

A text that isn't in the file, or whose translation is empty (`"Sign in" ""`), shows in English, never in Portuguese, so a translation that's halfway done is fine to use and to send.

## Placeholders

Some texts have values the app fills in: `{s}` is a text, `{d}` a number, and some have formatting, like `{d:0>2}`. They only matter in texts that have them:

- copy them exactly as they are in the English text, and they are filled in the same order: `"Replying to {s}" "Antwort an {s}"`;
- to change the order, write `{0}`, `{1}`… instead: `{N}` is the Nth placeholder of the English text, counting from 0, with its formatting. `"{1s} {0d}, {2d}"` (November 9, 2026) becomes `"{0}. {1} {2}"`. Don't mix both ways in one text;
- every value of the English text has to appear;
- `{{` and `}}` are literal braces.

A translation that breaks these rules shows in English. The editor and `tools/i18n_strings.py --check` point out which ones.

## Counts

A text with a count, like `{d} votes`, has one form per plural category of the language, following the [CLDR plural rules](https://cldr.unicode.org/index/cldr-spec/plural-rules). The key is the English plural, and each form goes as a property:

```kdl
"{d} votes" one="{d} голос" few="{d} голоса" many="{d} голосов"
```

| Language | Forms | Which numbers |
|---|---|---|
| Japanese, Chinese, Korean, Vietnamese… | one text for every number | |
| English, German, Dutch, Swedish… | `one`, `other` | 1 · 0, 2, 5, 21 |
| French | `one`, `many`, `other` | 0, 1 · 1000000 · 2, 5 |
| Spanish, Italian, Catalan, European Portuguese | `one`, `many`, `other` | 1 · 1000000 · 0, 2, 5 |
| Russian, Ukrainian, Belarusian | `one`, `few`, `many` | 1, 21, 31 · 2–4, 22 · 0, 5–20 |
| Polish | `one`, `few`, `many` | 1 · 2–4, 22 · 0, 5, 12, 21 |
| Arabic | `zero`, `one`, `two`, `few`, `many`, `other` | 0 · 1 · 2 · 3–10 · 11–99 · 100 |

The template and the editor list the forms of your language with the numbers that use each one. A plain text next to the forms (`"{d} votes" "{d} Stimmen" one="{d} Stimme"`) is used for any form you leave out, and a language with a single form needs just that one text. Each form follows the placeholder rules above.

## Try it in the app

Put the file in the translations folder:

| System | Folder |
|---|---|
| Linux | `~/.config/larpercord/i18n/` (or `$XDG_CONFIG_HOME/larpercord/i18n/`) |
| Windows | `%APPDATA%\larpercord\i18n\` |

Settings → Language → **Open the translations folder** opens (and creates) it. Each file there:

- with a new code, is a new language in Settings → Language;
- with the code of a language that comes with the app (`ja.kdl`, `ru.kdl`), goes on top of it: only what the file has changes, so a file with three lines fixes three texts.

The list shows how much of the app each language translates. Saving the file updates the text right away, with a notice; a broken line shows in red on the Language page, with the file and the line, and the language keeps the text it had.

## On the command line

From the repository, with Python 3 (only the standard library):

```bash
# The template of a new language: every English text with an empty translation, a //: line
# saying where it is and what it is, and the plural forms of the language
python3 tools/i18n_strings.py --template de --name Deutsch --english German -o de.kdl

# After the app changes: new texts come in empty, the ones it no longer uses get /- in front
# (the app ignores them; nothing you translated is lost), and the //: lines are made again
python3 tools/i18n_strings.py --update de.kdl

# Check every file in i18n/ (or one, with --lang de, or one anywhere, with --file de.kdl):
# broken files, wrong placeholders and repeated entries are errors; missing translations
# are only counted
python3 tools/i18n_strings.py --check --file de.kdl
```

## Send it

Add the file to the repository as `i18n/<code>.kdl` in a pull request. Nothing else changes: the build packs every file of that folder into the app, compressed, and the language shows up in Settings → Language and on the [status page](page:translation-status). CI runs the check on every pull request: a broken file or a wrong placeholder fails it, a missing translation doesn't.

## What isn't in the file yet

- Dates: Portuguese, English, Japanese and Russian write them their own way ("9 de novembro de 2026", "2026年11月9日"); other languages write them like English. Relative times ("3 days ago") and everything else are in the file.
- Plugins have their own texts, in each plugin.

## For developers

New text in the interface goes through `i18n.tr` (or `fmt`, `allocPrint`, and `plural` for counts) with the Portuguese and the English side by side, as in the rest of the code. Then:

- add the English to `i18n/*.kdl` (translated, if you speak the language; otherwise the English text itself as a placeholder, which [the status page](page:translation-status) counts as "same as English");
- `python3 tools/i18n_strings.py --keys` updates `i18n/keys.txt`, the list the app uses to say how much each language translates;
- `python3 tools/i18n_strings.py --check` before the pull request.

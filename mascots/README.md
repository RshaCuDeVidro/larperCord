# Writing mascots

**English** · [Português](README.pt-BR.md)

The Terminal mascot (the purple cat with the `>_` face) can wear anything you like. In Settings → Mascot →
**Customize** you pick eyes, mouths, hats, accessories, ears and colors from a library, with a live preview.
A mascot file goes further: it is a [KDL](https://kdl.dev) file that picks those same parts **and can draw
its own** with simple shapes, one drawing per expression. Files are data only: nothing in them runs.

Put the file, for example `my-mascot.kdl`, in your mascots folder:

| System | Folder |
|---|---|
| Linux | `~/.config/larpercord/mascots/` (or `$XDG_CONFIG_HOME/larpercord/mascots/` when that variable is set) |
| Windows | `%APPDATA%\larpercord\mascots\`, usually `C:\Users\<you>\AppData\Roaming\larpercord\mascots\`. To open it, paste `%APPDATA%\larpercord` in File Explorer's address bar |

The easiest start: build a look in Settings → Mascot → Customize and press **Save as file**. The app writes
the file into the folder, switches to it and shows it under **Mascot files**, where **Open folder** opens the
folder for you. **From then on, saving the file updates the mascot right away**, everywhere it shows up: the
opening, the About page, the empty lists and the corner mascot. If there's an error, the file's card shows
`file:line:column` and the mascot keeps the last version that worked.

Save the file as UTF-8 (on Windows, Notepad's "UTF-8" is right).

## Minimal example

```kdl
mascot "Pirate Pete" author="you" license="CC0-1.0"

look eyes="dots" mouth="fang" hat="pirate" ears="pointy" accessories="eyepatch earring"
colors palette="lava"
```

That's a whole mascot: three lines, no drawing. Everything below is optional.

## Top-level nodes

| Node | What it does |
|---|---|
| `mascot "name" author=… license=… description=…` | metadata. The name shows in the list of files |
| `look eyes=… mouth=… hat=… ears=… accessories="…"` | parts from the library (lists below). Leave one out and it stays the default |
| `colors palette="…"` or `colors body-top="#…" …` or `colors theme=#true` | the five colors (below) |
| `eyes { … }` | your own eyes, drawn with shapes. Replaces `look eyes=` |
| `mouth { … }` | your own mouth, drawn with shapes. Replaces `look mouth=` |
| `layer "front" { … }` | shapes in front of everything (your own hat, glasses, a sticker…) |
| `layer "back" { … }` | shapes behind the body (wings, a tail, a cape…) |

An unknown node, part or color is an error with `file:line:column`, so a typo never goes unnoticed.

## Parts

**Eyes** (`look eyes=`): `prompt` (the `>_`, default), `dots`, `ovals`, `big`, `cat`, `sleepy`, `happy`,
`wink`, `stars`, `hearts`, `pixel`, `binary`, `cyclops`, `lashes`, `visor`.

**Mouths** (`look mouth=`): `smile` (default), `cursor`, `cat` (`:3`), `uwu`, `tongue`, `fang`, `vampire`,
`open`, `o`, `flat`, `wavy`, `smirk`, `grin`, `pout`, `whistle`, `bunny`.

**Hats** (`look hat=`): `none` (default), `crown`, `tophat`, `beanie`, `cap`, `cowboy`, `chef`, `halo`,
`horns`, `flowers`, `viking`, `wizard`, `bow`, `propeller`, `beret`, `tiara`, `pirate`, `helmet`, `sprout`,
`antenna`, and the holiday ones: `santa`, `witch`, `party`. With a hat picked, the corner mascot doesn't
switch to the holiday hat.

**Accessories** (`look accessories=`, several separated by spaces): `glasses`, `shades`, `monocle`,
`eyepatch`, `blush`, `freckles`, `bandaid`, `mustache`, `bowtie`, `scarf`, `bandana`, `earring`. Eyewear
(`glasses`, `shades`, `monocle`, `eyepatch`) and neckwear (`bowtie`, `scarf`, `bandana`) are one at a time: the
last one wins.

**Ears** (`look ears=`): `pointy` (default), `round`, `floppy`, `bunny`, `tiny`, `none`.

Every eye and every mouth has a version for each expression (happy, laughing, startled, angry, sad, asleep,
dizzy, worried), plus blinking, looking around, eating and the error face.

## Colors

```kdl
colors palette="meia-noite"
colors palette="menta" accent="#FF3366"         // a palette with one color changed
colors body-top="#9D40FF" body-bottom="#7A1FE6" ink="#12061F" tufts="#F7A8FF" accent="#29E6FF"
colors theme=#true                               // follow the theme's accent color
```

| Name | What it colors |
|---|---|
| `body-top`, `body-bottom` | the body gradient, top to bottom |
| `ink` | the face (eyes, mouth, mustache, glasses frames). Keep it in contrast with the body |
| `tufts` | inside the ears, and a soft second color |
| `accent` | details: the headset in calls, the bow tie, the scarf, the cat eyes' iris |

Palettes: `uva` (grape), `menta` (mint), `por-do-sol` (sunset), `oceano` (ocean), `morango` (strawberry),
`limao` (lime), `grafite` (graphite), `neve` (snow), `caramelo` (caramel), `matrix`, `algodao-doce` (cotton
candy), `lava`, `meia-noite` (midnight), `floresta` (forest).

Without a `colors` node the mascot keeps the default purple, and the corner mascot follows the theme's accent
color, as always.

## Drawing your own parts

Inside `eyes`, `mouth` and `layer`, each line is a shape. Coordinates are in the units of the mascot's
drawing (the same as `assets/mascote-terminal.svg`, viewBox `-10 -34 147.14 134`):

- the body goes from x 0 to 127, the top of the head is at y ≈ 7 and the feet at y ≈ 96;
- the default eyes are at (40, 50) and (84, 55): the face leans a little, the right side is lower;
- the mouth sits around (63.5, 70);
- the ear tips are at about (21, −15) and (106, −15); hats sit on y ≈ 5.

| Shape | Attributes |
|---|---|
| `circle` | `cx cy r` |
| `ellipse` | `cx cy rx ry`, optional `rotate` (degrees) |
| `rect` | `x y w h`, optional `r` (rounded corners) |
| `line` | `x1 y1 x2 y2` |
| `polyline` | `points="x y x y …"` (open) |
| `polygon` | `points="x y x y …"` (closed) |
| `path` | `d="M … L … H … V … Q … C … Z"`, like SVG: uppercase is absolute, lowercase relative; `Z` closes and fills |

Every shape also takes `fill`, `stroke`, `width` (the stroke, default 3) and `opacity` (0 to 1). A color is
`#RRGGBB`, `#RRGGBBAA`, one of the mascot's five (`ink`, `body-top`, `body-bottom`, `tufts`, `accent`: they
follow the palette), `white`, `black` or `none`. Without `fill` and `stroke`, closed shapes are filled with
`ink` and open ones are stroked with it.

The eyes and the mouth move with the face (they follow the mouse and hop when you type); `front` and `back`
move with the body.

### One drawing per expression

```kdl
eyes {
    // the default: used by every expression that has no block of its own
    circle cx=40 cy=50 r=5
    circle cx=84 cy=55 r=5
    when "happy" "laugh" {
        path d="M 32 54 Q 40 44 48 54" stroke="ink" width=4
        path d="M 76 58 Q 84 48 92 58" stroke="ink" width=4
    }
    when "sleep" {
        line x1=33 y1=52 x2=47 y2=52
        line x1=77 y1=56 x2=91 y2=56
    }
}
```

The expressions: `normal`, `happy`, `laugh`, `startled`, `angry`, `sad`, `sleep`, `dizzy`, `worried`, plus
`error` (the login failed) and `eat` (the mouth opens: eating, yawning). One `when` can list several.

What happens when a block is missing:

- blinking squeezes each eye in place, so any drawing blinks;
- `sleep` without a block of its own closes the default eyes the same way;
- `error` and `dizzy` without a block use the usual `x` eyes and spirals;
- `eat` without a block uses the usual round open mouth;
- the connecting "…" always takes the mouth's place.

### Limits

A file has at most 64 KB, 256 shapes and 4096 points (256 per shape; a curve becomes about 10 points).
Numbers are kept between −400 and 400 and the stroke under 40.

## A full example

```kdl
mascot "Little Star" author="you" license="CC0-1.0" description="Star eyes that blink and laugh."

look hat="sprout" accessories="blush"
colors palette="algodao-doce"

eyes {
    circle cx=40 cy=50 r=7 fill="white" stroke="ink" width=1.6
    circle cx=41 cy=51 r=3.6
    circle cx=84 cy=55 r=7 fill="white" stroke="ink" width=1.6
    circle cx=85 cy=56 r=3.6
    when "happy" "laugh" {
        path d="M 32 53 Q 40 43 48 53" stroke="ink" width=4
        path d="M 76 58 Q 84 48 92 58" stroke="ink" width=4
    }
}

mouth {
    path d="M 55 69 Q 59.5 74 63.5 69.5 Q 67.5 74 72 69" stroke="ink" width=2.6
    when "laugh" "startled" { ellipse cx=63.5 cy=72 rx=6 ry=6.5 fill="ink" }
}

layer "front" {
    path d="M 98 22 L 101 28 L 108 29 L 103 33 L 104 40 L 98 36 L 92 40 L 93 33 L 88 29 L 95 28 Z" fill="#FFD84A" stroke="ink" width=1
}
```

More examples, each showing off a part of the format, are in [`community/`](community/).

## Sharing your mascot

Mascots people send in show up in the
[community mascot gallery](https://rshacudevidro.github.io/larperCord/community-mascots.html), with a picture
and the file to download.

1. Make the mascot and check it in the app: no error on its card in Settings → Mascot → Mascot files, and
   every expression looks right in the big preview (the buttons under it switch the face, the headset and the
   tape).
2. Fill in the `mascot` node: a name, `author=`, `license=` (an open license written as its SPDX identifier,
   such as `CC0-1.0`, `CC-BY-4.0` or `MIT`) and a `description=`.
3. Fork [the repository](https://github.com/RshaCuDeVidro/larperCord), add the file to `mascots/community/`
   and open a pull request. One mascot per pull request. A screenshot of it in the pull request helps.

Rules: a name of its own, an original drawing (don't redraw someone else's character or logo), and only `.kdl`
files in the folder.

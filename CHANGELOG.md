# What changed in each version

## 0.7.0

**Writing themes**
- Every component, property and value a theme can use is now listed in one place, the theme schema, and the app checks each theme against it when it loads: a name it doesn't know, a property a component doesn't have, a value that isn't one of the choices or a number out of range shows as a warning with the line and the column, and a typo gets a suggestion (`unknown property 'varient' on messages (did you mean 'variant'?)`). A theme that loaded before still loads. `larpercord --theme-check FILE.kdl` lists every warning and error in the terminal, in both modes and with the options on and off, without opening a window (`--strict` fails on warnings too; CI checks the bundled and community themes this way), and `--theme-schema` prints the schema as JSON, which the site's theme builder now reads.
- `extends "classico"` starts a theme from another one, bundled or in your themes folder, and changes only what differs: colors token by token, fonts and metrics property by property, styles style by style, options by name, and the layout, palette and roles whole. `vars { gap 8 }` gives names to values, used as `$gap` in any property or inside a color expression, and a theme that extends a base can change the base's variables, also where the base uses them. The theme builder and the community gallery understand both.
- `theme-api 2` at the top of a theme turns the check strict: what would be a warning is an error, and the app doesn't load the theme until it's fixed. Themes without it work as before.
- `larpercord --theme-lsp` is a language server for theme files: Neovim, Helix, VS Code and other editors show the errors and warnings while you type, complete components, properties, values, color tokens, options and variables, and show the description of each on hover. It talks over stdin and stdout and opens no window, on Linux and Windows. Setup snippets are in themes/README.md.

**Theme parts**
- A `parts` block styles the pieces inside the components, and each piece in each state: `part "message.author:hover" color="@accent"`, `part "channel.item:selected" bg="@selected" radius=4`. The pieces are the message row and its author, time, text and reply line; the channel row, category, unread marker, ping badge and the people under a voice channel; the member row, name and group heading; the message box and its hint. The states are hover, selected, unread, mention, speaking, muted, offline and self, and they combine (`channel.item:selected:hover`). A piece takes a background, a text color, a border, rounding, a stripe on the side where the text starts (the right side in Arabic or Hebrew), opacity and font weight, with colors that follow the light or dark mode and the accent picked in Settings. It works in every layout variant (cozy, irc and bubbles messages; discord, tree and pills channels; discord and tty members; box, pill and prompt message box), is worked out once when the theme loads, and a theme without `parts` draws exactly as before. Guide: "Parts and states" in themes/README.md, and Studio Ink in the community gallery uses most of them.
- The Inspector shows the theme part under each element with the states it has right now, ready to paste into a theme (`larpercord ctl inspect el` returns it too).

**Themes**
- Vector shapes: `shape kind=path d="…"` draws SVG path data (`M`, `L`, `H`, `V`, `C`, `S`, `Q`, `T`, `A` and `Z`, uppercase absolute and lowercase relative), filled with `fill=` (`fill-rule=nonzero|evenodd`, holes included) and/or stroked with `color=` and `thickness=`. `viewbox=` says which part of the coordinates fits in the node, without distortion and at the interface scale. The path is read and turned into lines once, when the theme loads, and the fill becomes a mask made once per size; a mistake stops the theme with the line of the `shape` and the character of `d` where it is. Up to 1024 commands.
- Four new procedural backgrounds: `rain` (the wind's tilt with `angle=`), `matrix` (columns of characters drawn by the app, so no font is needed), `waves` (`lines=`) and `particles` (fine dust and large blurred discs), with `density=`, `seed=` and `motion=` like the others. They are masks made once and tinted with the theme's colors: still, they never wake the app; moving, at most 15 frames per second, and they stop with "Reduce motion" and when the window is hidden or in the background.
- Wallpaper: Settings → Appearance → Wallpaper → "Choose image…" puts a picture from your computer (PNG, JPEG, WebP or BMP) behind the theme. It's only ever a local file picked in the system's file dialog: a theme can't point to a file or an address, and nothing goes online. Fit (the theme's, Fill, Whole, Tile or Center) and Dim are saved in settings.kdl, and Remove takes it away. A theme places it with a `wallpaper` node (`fit=`, `dim=`, `blur=`, `opacity=`, `radius=`); in themes without one, like the bundled ones, it goes behind the whole layout and the panels turn translucent only as far as the text keeps its contrast, with the theme's animated background stepping aside. The picture is read in the background and shrunk to what covers the window, never asks for frames, and leaves memory while the window is hidden.
- The theme creator on the site checks and previews the new nodes, and refuses what the app refuses. Guide: themes/README.md. Japanese follows the new texts; the new Russian ones are in English for now.

**Translations**
- Every language besides Portuguese and English is now just a file. Each `i18n/*.kdl` says which language it is on its first line (`language "日本語" code="ja" english="Japanese"`, and if needed `direction "rtl"`, `font-script` and `plurals`), and the build packs every file of that folder into the app, compressed: adding a language needs no code change. A `.kdl` in the translations folder (`~/.config/larpercord/i18n/`, `%APPDATA%\larpercord\i18n\`) with a new code is a new language in Settings → Language; with the code of a built-in one, it goes on top of it. Missing text shows in English, never in Portuguese. A saved Japanese or Russian setting stays as it was.
- Saving a file in the translations folder updates the app's text on the spot, like themes do. A line with a mistake shows in red on the Language page, with the file and the line, and the language keeps the text it had until the file opens again.
- Settings → Language lists every language with how much of the app it translates (日本語 — 99%) and where its file comes from, has buttons for the translations folder and the translation editor, and "Follow system" says which language that is right now. The system language now finds a translation file too (`de` with a `de.kdl`), with the region first (`pt-PT` before `pt`), and `--lang` takes any code.
- Plural forms: a text with a count has one form per CLDR category of the language (`"{d} votes" one="{d} голос" few="{d} голоса" many="{d} голосов"`), with the rules of 20 families of languages. Relative times ("3 days ago", "через 2 минуты") moved from the code to the files, so any language can translate them, and votes, threads, unread messages, mentions, results, tabs, members, plugins found and mutual friends and servers count with each language's forms: Russian says "21 голос", and a poll or an invite with one vote or one member no longer says "1 votes" or "1 members".
- On the website: a translation editor (each English text with where it is in the code and what it is, placeholders checked while you type, the missing ones first, the plural forms of the language and the `.kdl` to download; it runs in the browser and keeps the work there), the "Translating larperCord" guide and a status page with each language.
- `tools/i18n_strings.py --template de` makes the template of a new language (each text empty, with where it is and what it is), `--update` brings a translation up to date without losing anything (texts the app dropped get `/-`), `--keys` keeps the list the app counts from, and `--check` checks every file. CI fails on a broken file or a wrong placeholder; a missing translation only warns.
- Exported conversations follow a right-to-left translation (`dir="rtl"` on the page), and each message keeps its own direction. Japanese follows the new texts; the new Russian ones are in English for now.

**Plugins**
- Labels in any language: `larper.tr{ pt = "olá", en = "hello", ja = "こんにちは" }` picks the interface's language (the exact code, then the base language, then English), `larper.lang()` returns the real code (`"ja"`, `"ru"`…) and `-- @name:<code>` and `-- @description:<code>` translate the plugin's card. Menus, choices, the panel and the options take the same tables. The old `larper.tr("olá", "hello")` keeps working.
- Real HTTP: `larper.http.put`, `patch`, `delete`, `head` and `request` besides `get` and `post`. `*.example.com` in `@hosts` covers the subdomains (a wildcard on a whole top-level domain, a public suffix or a shared hosting domain stops the plugin from starting, and Discord's domains can't be declared at all). `Authorization` and `X-API-Key` only go to the hosts in `@credentials` that you approved, and the card warns about them. `res.headers` brings a list of allowed headers, and redirects are followed only to an approved host, over HTTPS, up to 5. The plugin's card lists its last 32 requests, never a header value or a body.
- `larper.secrets` keeps API keys and passwords in the system keyring (Credential Manager on Windows, Secret Service on Linux), separate for each plugin and never in the log.
- Actions on messages: `larper.react`, `larper.reply`, `larper.edit` (only your own messages), `larper.delete` and `larper.attach` (both ask first, on screen), `larper.pin`, `larper.unpin`, `larper.thread`, and `larper.send` with `reply_to`. They only run straight from a gesture on the plugin (its command, keybind, panel button or menu entry, never an event, a timer or an HTTP answer), with a ceiling per gesture and per minute, and go the same way as the app's own buttons.

## 0.6.8

**Control from outside**
- `larpercord ctl` controls the larperCord that is already running, from scripts, status bars and system shortcuts: `status` and `unread` answer in JSON (connection, account, the call with its channel and server, mute, deafen, push to talk, mentions, unread DMs and channels); `mute`, `unmute`, `toggle-mute`, `deafen`, `undeafen` and `toggle-deafen` do the same as the buttons and `Ctrl+Shift+M`/`D`, sound and what goes to Discord included; `show`, `hide` and `toggle` do what the tray does; `open` takes a Discord link or a channel ID. It works with the window hidden in the tray, and answers in the terminal on Windows too. Examples for each desktop are in docs/ctl.md.
- Push to talk anywhere on Linux: in push to talk mode, `ptt-down` and `ptt-up` press and release the key from outside, so a compositor shortcut (Hyprland's `bind`/`bindr`, Sway's `bindsym --release`) talks even with another window focused, exactly like the key in Settings → Voice. KDE and GNOME shortcuts, which don't fire on release, use `ptt-toggle`. Leaving the call releases it.
- `watch` keeps running and prints a line each time something changes: the status in JSON, `--waybar` for a waybar module (the number of mentions, an icon per state for the call, muted, deafened, talking, mentions and unread, and a tooltip) or `--format text` for polybar. With the app closed it shows offline and comes back by itself when the app opens.
- For status bars that want more: in a call, `status` and `watch` list who's in it with their picture, who's talking right now (a new line goes out when someone starts or stops), each person's volume, your status and the gateway ping. `mentions` gives the unread DMs and mentions with the start of each message and a link to open it, `channels` gives every server, channel and DM with its unread count (for a launcher), `presence` changes your status and `volume` sets someone's volume.
- Only your user can use it: the app listens on 127.0.0.1, on a random port, and each connection starts with a key that changes every time the app opens, in a file only you can read. It's on by default, and Settings → Advanced → External control turns it off; off, nothing listens. Nobody using it costs nothing: no polling and no frames. Japanese follows the new texts; the new Russian ones are in English for now.

**Mentions**
- `@` finds anyone in the server: typing `@` and a name in a server's message box now also asks Discord for the members whose username or server nickname starts with what you typed, not only the people larperCord already has loaded. In a big server the member list only carries who's online, so mentioning someone offline who hadn't written recently wasn't possible. They join the list with their nickname, picture and role color; a still "searching the server…" shows while the answer is on its way, and the person you had selected stays selected when the list updates.
- It goes easy on your account: Discord allows one member request per server every 30 seconds, and the search shares that window with the request for the authors of old messages (and goes first). It waits 300 ms after the last key and needs 2 letters, asks for 10 people like the official client does, never asks again for what already came back (nor for a longer name when the shorter one came back with fewer than 10), keeps only the latest search while it waits, and sends at most 4 a minute across all servers. Never in DMs or groups, and not in servers whose member list already has everyone. Japanese follows the new text; the Russian one is in English for now.

**Messages**
- Select text in the message box and B and I appear above the selection, on the side where it ends: they put ** and * around the selected text, for bold and italic, and the markdown preview updates on the spot. Settings → Chat → "Formatting bar" turns it off, from ryokky3 (#31). Japanese follows the new texts; the new Russian ones are in English for now.

**Private pictures**
- Location and camera details come off photos and videos before they're sent: Settings → Privacy → "Remove location and camera details from photos and videos", on by default. What goes to Discord is a copy without the GPS, the camera model and the rest that hides in the file (Exif and XMP in JPEG, PNG and WebP, a PNG's text and time chunks, the location and camera boxes of an MP4 or MOV from a phone); the picture itself isn't recompressed, and a photo taken sideways stays upright. The file on your computer is never touched: the copy is made right before sending, in a temporary folder only your user can open, and goes away when the send finishes. GIFs, voice messages and other files go as they are, and a broken file goes as it is rather than not at all.
- Crop and hide parts of a picture before sending: an image in the tray (a screenshot pasted with Ctrl+V, for example) has an Edit button that opens an editor over the window. Drag to crop, with the size shown and handles on the corners and edges; drag over a name, an address or a face to hide it with big pixel blocks or a black bar. The hidden part is gone from the file that's sent, not just covered: the blocks are big and carry a little random noise, and there's no light blur, which can be read back. Undo (Ctrl+Z), Reset, Cancel (Esc) and Done (Enter); Done puts a PNG of the result in the tray in place of the original, with the same spoiler and alt text. Pictures up to 20 megapixels open in the editor, a photo taken sideways opens upright, and pasted and edited images now also live in that private temporary folder. Japanese follows the new texts; in Russian they show in English for now.

**Inspector (developer tools)**
- F12 (or Ctrl+Shift+I) opens the Inspector, docked to the right or the bottom with the app fitting in the rest, or floating. Ctrl+Shift+E picks an element on screen: the click picks instead of reaching the app, and a card shows what it is, its size, its color with the theme's name for it, the font, the contrast against the background and the theme file and line that draws it. Both shortcuts can be changed, and it's also in the command palette and in Settings → Advanced.
- Elements shows the frame as a tree: the theme's layout pieces, and inside each one the boxes, texts, images and clickable areas it drew, with the `.kdl` node's properties, the Dear ImGui id and status, the QA mark in builds with the robot, and how long each component took to draw. It searches by text, component, color or mark.
- Network lists every HTTP request (Discord's API, images, plugins) with status, time, size and how long it waited on the rate limit; picking one shows the headers, what was sent, the response as a JSON tree and the time of each phase, and copies it as a curl line. Gateway lists every frame of the gateway and the voice gateway, heartbeats hidden, with the content as a tree. Your token is never recorded: no Authorization header, and the token in IDENTIFY and RESUME shows as asterisks.
- Console shows the log without turning on the debug log, and has a command line (`help`) that can also find, click and type, read the frame's tree, the network and the log, switch themes and take screenshots; from outside, the same commands run as `larpercord ctl inspect …`. Events shows what the interface asked the app, what the app asked the network and what came back. Performance graphs the last 300 frames and each component's cost, GPU work, memory and CPU. State shows the session, the open conversation, the theme's colors and the window.
- Closed and never opened, it costs nothing. What it records stays in memory only. `--inspect` opens with it recording from the start. Guide: docs/inspector.md. The new Russian texts are in English for now.

**Calls**
- Drag someone in a call onto another voice channel in the channel list to move them there, like in Discord (with "Move Members"). A click still opens their profile; Esc or dropping anywhere else cancels.

**Videos**
- Videos go fullscreen: the new button at the right end of a video's control bar, a double-click on the video, or F with the mouse over it or while it plays puts the window in real fullscreen with the video over the whole app, on black, and the same controls: play/pause, the progress bar with the time, volume and leave fullscreen. While it plays, the controls and the mouse cursor hide after 2 seconds without moving the mouse and come back when it moves (with "Reduce motion" they don't fade). Space plays or pauses, ← and → skip 5 s, ↑ and ↓ change the volume and M mutes; Esc, F, F11, a double-click or the button leave. The video goes on from where it was, without starting over or downloading again, and the window goes back exactly as it was: windowed, maximized, or still fullscreen if it already was (F11). Leaving fullscreen through the system (a desktop shortcut) takes the video out too, and closing to the tray leaves fullscreen first, so the window comes back from the tray as it was before. In a call, the mute and deafen shortcuts still work, and an incoming call shows over the video. The rest of the app isn't drawn while the video is fullscreen.
- In fullscreen the video is decoded up to the screen size, at most 1080p, instead of the 854×480 of the conversation, and goes back to that size when it leaves, a paused video included. With a 1080p video that's about 25 MB more while in fullscreen (three 8 MB frames waiting to be shown plus the texture), given back on leaving; a smaller video never grows past its own size. Without FFmpeg, where the play opens the browser, there's no button. The keys are listed in Settings → Keybinds. Japanese follows the new texts; the new Russian ones are in English for now. The QA has a new suite for it (the button, the window before and after, F11 before, maximized, leaving through the system, the controls hiding, the keys, the decoding size and memory, "Reduce motion" and the tray), also run in a light theme, in Japanese and at 125%.

**Notifications**
- Reply from the notification: DM and mention notifications now have Mark as read and Reply buttons, and clicking the notification brings the window up (also from the tray) on that conversation, at the message. Mark as read reads the conversation like the menu item does, without showing the window. Where the notification has a text box, what you type goes out as a reply to that message, without showing the window either, pinging the author or not like the "@ ON/OFF" in the text box; where it doesn't, Reply opens the conversation with the reply ready. A reply follows the same rules as the text box (slowmode, permissions, timeouts, still connecting): when it can't go out, the text becomes the conversation's draft and another notification says why, opening the conversation to try again. Reading a conversation here or on another device closes its notifications, and quitting the app closes them all, so no button is left with nobody to answer it. Settings → Notifications → "Reply from the notification" turns the buttons off. Japanese follows the new texts; the new Russian ones are in English for now.
- On Linux, notifications go straight to the notification server over D-Bus instead of through notify-send, with no new dependency (the same libdbus the tray icon opens). KDE Plasma gets the text box in the notification; GNOME and others with buttons get the buttons, and Reply opens the conversation. On Wayland, the window comes up focused with the activation token the server sends. Without D-Bus or without a notification server, it falls back to notify-send as before, and it switches when a server shows up or changes.
- On Windows, notifications are real toasts with the buttons and a text box next to Reply, registered for your user only (no administrator), without changing how the window groups with the Start menu shortcut. If Windows doesn't take them, they go out as the tray balloon as before. Reminders, calls, updates and plugin notifications keep coming, now with a click that brings the window up.
- The QA has a new suite with a private D-Bus session and a fake notification server inside the app's own binary: KDE-style and GNOME-style servers, mark as read and an inline reply with the window in the tray, a reply blocked by slowmode, the click with the activation token, the server going away, and no session at all.

**Text in any language**
- The Terminal mascot's name in Settings → Mascot goes through the translation, like Classic next to it (#20).
- In English, the mascot's "Games" switch (the d20, feeding it, hide and seek) is now "Tricks", so it no longer shares its name with the Games page under Privacy; in Japanese the two are 遊び and ゲーム (#20).
- Bold and italic now show in Japanese too. No Japanese font has either style, so the fallback font drew **bold** text regular and *italic* text upright; the letters that come from the fallback are now emboldened and slanted synthetically, only on the spans that ask for it, from ryokky3 (#31).
- Symbols the color emoji font doesn't have, like ⛧, now come from another font on the system instead of showing as a box, the way letters of other scripts already did. A letter or symbol missing from the font that was found for its Unicode block looks for a font of its own, a symbol that only the Japanese, Chinese or Korean font has no longer stays a box, and up to 12 of these fonts can load instead of 8. By ErnstBecker (#48).

**Server folders**
- Folders in the server bar can be edited now, and the change goes to your Discord account like in the official app: drag a server onto another to make a folder with both, drag servers into a folder, out of it and between the others, and drag a whole folder somewhere else. Right-click a folder for Folder Settings (a name, and a color from the palette or any hex code), Mark Folder as Read (every server in it, in one request) and Remove Folder (its servers stay, loose, where it was); a server's menu has Add to Folder… (your folders or a new one) and Remove from Folder. A folder without a name shows its servers' names. Opening and closing a folder stays on this computer.
- The bar changes right away and the account saves each change; several in a row within a second go out together. Each save is a single request, made from the copy of the account settings the app already gets from Discord (when it connects, when another device changes something and in the answer to each save); only without that copy does it read them first. If another device saved something in between, Discord refuses and answers with the settings as they are, and the change is made again on top of them. Only the folders go to Discord: every other account setting, including ones the app doesn't know, stays exactly as it was, and a folder that didn't change goes back byte for byte. If the settings come in a shape the app can't read in full, nothing is written. If saving fails, the bar goes back to what the account has and a notice says why. A change made on another device rearranges the bar here as it arrives.
- The folders now show in every server bar that has room for them: the vertical one, the horizontal one and the list (papel, escritorio, cupertino). In the dock and the terminal tabs the servers stay one by one, so dragging there only reorders them (dropped in the middle of a folder's servers, a server goes into that folder), and the menus work everywhere. The QA has new suites that drag, rename, recolor, move servers in and out, reorder, remove a folder, fail a save and get a change from another device, decoding each request back and counting the requests of each save. Japanese follows the new texts; the new Russian ones are in English for now.

**Connection**
- Signing in and every reconnect no longer wait up to a second before sending IDENTIFY or RESUME. When Discord's first message came in together with the answer to the connection, the app only noticed it a second later.
- A token Discord refuses (4004) after the connection had dropped a few times in a row now shows why on the sign-in screen, instead of "the connection keeps dropping; retrying more slowly", which also wasn't true: nothing retries after that.

**Favorite GIFs**
- The Favorites tab of the GIF picker opens instantly with every GIF already playing: larperCord keeps a small clip of each favorite on your computer and plays it from there, with nothing downloaded, and shows the list from last time until Discord's arrives. Starring a GIF makes its clip from the file that just played, without downloading it again; favorites that have no clip yet (starred on another device, or before this version) get one in the background when the picker opens, one at a time, through the same path as images, so Data Saver and "Animate Tenor and Giphy GIFs" off still mean nothing is downloaded (those tiles work as before). Sending still sends the GIF's link, exactly as before.
- The clips are animated WebPs of about 40 KB: up to 160 px on the long side at 100% interface scale (more at higher scales), 15 frames per second and the first 6 seconds; a GIF of 64 KB or less is kept as it is. They live in `~/.cache/larpercord/gif-favorites/<account>` (`%LOCALAPPDATA%\larpercord\gif-favorites` on Windows), folders 700 and files 600 on Linux, capped at 50 MB per account, dropping the clip shown longest ago; a GIF removed from your favorites loses its clip the next time the list is read. Settings → Privacy shows how many there are and counts them in the cache size, and Clear cache, removing the account and Delete all data delete them. Building from source now also needs libwebpmux (part of the libwebp package on Arch and Fedora, `libwebp-dev` on Debian and Ubuntu); the portable Linux build and the Windows build carry it inside. Japanese follows the new text; in Russian it shows in English for now.

**Lighter in the tray**
- Closing to the tray now gives memory back instead of only hiding the window: the window, the renderer (the GPU context) and every texture go away, the font atlas, pictures, GIF frames, the video frame, theme effects and the image editor's included, and the freed memory goes back to the system (`malloc_trim` on Linux; on Windows the process heaps are compacted and the working set is emptied). Coming back (the tray icon, a second larperCord, a notification, `larpercord ctl show`, the floating window's back button) builds a new window with the same size, place, maximized or fullscreen state and transparency (the glass theme), and the text box keeps what you were typing. Small pictures that were on screen (avatars, server icons, emoji) stay in RAM as pixels, so the window comes back whole without downloading them again; bigger ones load again when they show up, and a paused video picks up where it was. Messages, DM notifications, reminders, calls and `ctl` keep working in the tray. In our QA, with Mesa's software OpenGL, the app went from about 100 MB to 52 MB (PSS) in the tray, and from 176 MB to 73 MB RSS; on a real GPU the driver's memory for the context goes too (tens of MB with NVIDIA).
- With the floating window open the main window only hides, as before, since the floating window draws with its renderer, fonts and pictures; closing the floating window while in the tray lets everything go. Coming back from the tray takes a little longer than just showing a hidden window, because the renderer starts again.
- With the window open, a picture that hasn't been drawn for a minute (scrolled away, another channel) leaves memory, GIF frames included, and loads again when it comes back into view; this was already so, and now the QA checks it by moving the pictures' clock forward. The QA also closes to the tray and back twice, checking that nothing of the GPU is left in the tray, that the screen comes back drawn the same pixel for pixel (a channel name and a member's photo), that pictures come back, that the text box keeps its text and that a DM in the tray still becomes a notification.

**Performance**
- The mascot in the corner no longer draws itself from scratch on every frame while it stands still. Its body is a shape full of curves that Dear ImGui cuts into triangles point by point, the most expensive part of drawing it, and that happened again on every frame where anything else moved: a GIF playing, someone typing, a call timer ticking. Now, when nothing about it changed since the frame before (the pose, where the eyes look, the look from Personalize, the size, the interface scale, the theme color), the triangles from last time are copied back as they were, so the screen comes out the same pixel for pixel. When it's invisible (half transparent), the texture it's drawn into is reused as well. As soon as it moves, it's drawn as before. In our measurement (the demo with a GIF playing, the classico theme at 1280×800), a frame with the mascot went from about 1.08 ms to 0.89 ms, and the mascot itself from about 245 µs to about 60 µs; redrawing nonstop, a frame went from 0.94 ms to 0.73 ms. The QA compares the reused drawing with a fresh one, pixel for pixel, at home, asleep, with a look full of parts, invisible and at 125% interface scale, checks that the parts that move with the clock (the propeller hat, the halo) still move, and that it comes back right from the tray.

**Memory**
- Settings → Performance now splits all of the app's RAM into parts that add up to the total, with nothing left unnamed: the program, system libraries, fonts, the video driver, other mapped files, thread stacks, the heap in use (the window and textures in SDL, the interface in Dear ImGui, glyphs in FreeType, connections in curl, encryption in OpenSSL, plugins in Lua, messages, people and servers, and the rest of the app and libraries), the free heap not returned yet, and what the video driver and libraries take outside malloc. The parts are measured: they come from the process memory map and from counters in the libraries' own allocation calls; only the account data is still an estimate, marked with ~, and the rest of the heap gets the difference. Before, the big blocks of the heap (each one a mapping of its own) showed up as nameless memory. `--stats` prints the same list when startup ends and once a minute. Japanese follows the new texts; the new Russian ones are in English for now.
- Messages take less memory: their reactions live in a block of their own, only on messages that have any, instead of eight empty slots in every message kept (a message in memory went from 648 to 272 bytes, with the same eight reactions at most); the message list of a conversation that has been off screen for 30 seconds gives back the room it had reserved for messages to come; and after a big READY the gateway keeps 64 KB of buffers instead of up to 2 MB.
- `tools/ram_conta_grande.sh` measures RAM and CPU on a fake account the size of a big real one (52 servers, 2,450 channels, roles, emojis, a few hundred DMs, member lists, pages of history, pictures and background traffic), generated by `tools/conta_grande.py` and served by the network QA's fake Discord, in a network namespace that only has 127.0.0.1: no account and nothing leaves the computer. It takes the QA build with `-Dqa=true -Dqa-rede=true`, which never goes into releases.
- `-Dmimalloc=true` builds with mimalloc 3.6.1 (MIT, in `third_party/mimalloc`) in place of the system's malloc, on Linux and Windows. On the fake account it used about three times the RAM (memory it frees stays with it instead of going back to the system) for the same CPU, so the releases keep the system's malloc and mimalloc stays an option for whoever wants to try.

## 0.6.7

**Floating window**
- Picture-in-picture: right-click the conversation name in the header, a tab or a channel (or use the command palette) and pick "Open in Floating Window", or press the new button in the call bar: a small separate window, always on top and resizable, follows that conversation live with a message box to reply, or the call with everyone's tiles, who's talking and the mute, deafen and leave buttons. The arrow button brings the main window back on that conversation or call, even from the tray, and the floating window keeps working while the main one is hidden in the tray. Its top bar moves it, it remembers its size and place, it closes by itself when the call ends, and one is open at a time.
- It stays light: it draws with the main window's fonts, pictures and emoji (nothing is loaded twice), only when something in it changes, and closed it costs nothing. On Wayland the compositor decides whether a window stays on top (KWin and Hyprland let you pin it), and the app says so the first time. Japanese follows the new texts; the new Russian ones are in English for now.

**Messages**
- Message reminders: right-click a message → Remind Me… and pick in 20 minutes, in 1 hour, in 3 hours, tomorrow at 9:00, next week (Monday at 9:00) or your own date and time, with an optional short note. "Tomorrow" and "next week" follow your clock across daylight saving time. When a reminder is due, a notice stays in the corner until you jump to the message, snooze it 10 minutes or mark it done; the corner mascot carries a little note to it, and with the window unfocused or in the tray a desktop notification goes out, through the same path as DMs and never on Do Not Disturb. A reminder that came due while the app was closed shows up as overdue when it opens. The saved messages panel has a Reminders tab with what's due, what's coming and what's done, with edit and delete, and the saved button shows how many are due. The app doesn't check on a timer: it sleeps until the next reminder. Reminders stay only on your computer, one file per account next to the saved messages, and "Delete all data" removes them. Japanese follows the new texts; the new Russian lines are in English for now.
- A message with a lone `*` (or `**`, `~~`, `||` with nothing to close it) no longer vanishes: the marker used to swallow itself and turn the rest of the message into that style, so a message that was just "*" came out empty. Now a marker only styles text when there is one to close it, like Discord, and otherwise shows as typed. `2 * 3 * 4` shows as typed too.
- Search finds messages instantly as you type, even offline: larperCord keeps a local index of every message it already has, the ones loaded in memory and the ones in the message cache on disk, and keeps it up to date as messages arrive, get edited or deleted and as history pages load (which also drops messages deleted while the app was closed). While you type, the last word counts as the start of a word ("hypr" finds "hyprland"); accents and case don't matter, and Japanese and Chinese are found character by character. from:, in:, mentions:, has:link, image, file, video and sound, before:, after: and during: work on this computer too; pinned:, has:embed and has:sticker still need Discord. Results from here are marked "on this computer".
- Enter still searches Discord, which has the whole history, and its results join the local ones, each message once. With no connection, Enter doesn't try and says so. Building the index never asks Discord for anything.
- The index is saved next to the message cache, per account, readable only by your user. It's read in the background, rebuilt from the cache when it's missing, follows Settings → Privacy → "Keep messages on disk" (off: memory only) and goes away with Clear cache, a removed account and Delete all data. Settings → Privacy shows how many messages it holds and its size on disk and in memory. In our measurements, 50,000 messages take about 10 MB in memory and 4 MB on disk, and a search takes under 2 ms. Japanese follows the new texts; in Russian they show in English for now.

**Export and save**
- Export a conversation: right-click a channel or DM (or the conversation's name in the header) → Export Conversation… and pick HTML (a single page that opens offline, in the current theme's colors, with authors, profile pictures that were already on your computer, times, formatting, replies, attachments and basic link cards), Markdown or JSON (documented fields, IDs as text, ISO times), the date range among the days on your computer, and whether to include media. The file goes where you choose in the system's save dialog, media in a folder next to it. It runs in the background with progress and Cancel, and ends with Open and Open folder.
- Export never asks Discord for anything, not even its CDN: it only uses what's already on your computer (the messages in memory and in the message cache, and the files the app already downloaded). The window says how many messages there are and since when; to include older ones, scroll up in the conversation first. Media is off by default; when on, the folder gets the profile pictures and images that were already on your computer, and everything else stays as a link to the original. The QA counts every command the app sends and every media download it starts, and checks that exporting starts none.
- Save images, GIFs, videos and files to disk: right-click one (or use the buttons in the image viewer) → Save… (system dialog with a suggested name and the right extension) or Save to Downloads (the system's Downloads folder, from user-dirs on Linux and the Known Folder on Windows, with a new name if the file already exists). It saves the original file, not the reduced preview (for Tenor and Giphy, the real GIF, when Settings → Privacy → Animate Tenor and Giphy GIFs is on), reusing what's already downloaded, through the same allowed domains and proxy as images, without your account. Russian shows the new texts in English for now; Japanese follows them.

**Presence**
- Album art in the "Listening to Spotify" activity: the big image of the activity ("spotify:<id>") now comes from Spotify's CDN (i.scdn.co), like the official app downloads. A malformed id keeps the card without the image. When a proxy is configured, the art goes through it, like all outside media.
- Show the game you're running (Settings → Privacy, off by default): your status shows "Playing <game>" with the time played for the games on your list, found by looking at the running programs every 15 seconds, the way the Discord desktop app detects games. It works for games that don't use Rich Presence, like Dota 2 (#36). Add a game from the list of programs running now (with a filter; system and background programs are left out) or by choosing its executable. Each game has a name you can edit, an on/off switch and "Only this file", which also checks the full path. Only games on the list are ever sent; with several running, the first on the list wins, and closing the game clears it. A game running through Wine or Proton shows up by its .exe. When a Rich Presence activity is on too, both go to Discord side by side instead of one replacing the other (the same game from both shows once), at the same pace as Rich Presence. Off, nothing looks at your processes. Japanese follows the new texts; the new Russian texts stay in English for now.

**Servers**
- Kicked or banned from a server (or you left it): nothing goes to it anymore. The member list of the channel that was open there is no longer asked for again on every reconnect, what was waiting to be sent to it is dropped, and a call there ends quietly instead of trying to reconnect with the old token. The same when it happens while the connection is down and the new session just doesn't bring the server back.

**Network and privacy**
- The connection now looks like the Chrome it already claimed to be. The app sent Chrome's headers but connected the way OpenSSL does by default, so its connection fingerprint (JA4) said otherwise. Now the TLS handshake carries the same ciphers, groups, signatures and extensions as Chrome 156, with the same JA4. On Linux, the release binary also speaks HTTP/2 with Chrome's settings and accepts br and zstd, where it used to fall back to HTTP/1.1. On Windows too (below).
- With the debug log on (Settings → Advanced), each request to Discord's API (method, path and status) and each gateway op that goes out (its number and server) is written down, with no token or content, to see what the app sent if the account ever gets flagged again.
- `--tls-fingerprint` prints the app's TLS and HTTP/2 fingerprint, as a site that echoes it back sees it, and tools/tls_check.sh compares it with Chrome's. Neither uses a token.

**Lighter**
- The app file is about 360 KB smaller: the Japanese and Russian translations, the changelog and the emoji table go inside it compressed and only open when needed (when you pick the language, open Updates, or the first emoji shows up). The last emoji of the table, the Wales flag, no longer reads one byte past its end.

**Text in any language**
- Russian: 341 texts that had been machine-translated (added from 0.6.2 to 0.6.6) are back in English, as placeholders waiting for a person to translate them; 63 more are being rewritten in DivannKokos's pull request (#29). Everything translated by pIat0n and DivannKokos stays. `tools/i18n_strings.py --lang ru --check` says how many are left, and the top of i18n/ru.kdl explains how to send a translation.
- The Chat and Plugins page titles go through the translation, and the texts the themes draw (like "CREW" in orbital or "SECTIONS" in editorial) can be translated in the language files (#20).
- Sentences that were cut with "…" in narrow places now wrap: the empty Active Now column, the add friend tab, message requests, the voice and timer settings, the language server command and archived threads (#20).

**Mascot**
- Invisible status: the corner mascot now fades as one figure. Each part used to fade on its own, so the ears showed through the body where they overlap and, with a hat on, looked like a pair of glasses. Now the whole mascot, hat and headset included, is drawn once and faded together. The Ctrl+C clone fades the same way.
- Settings → Mascot → Customize has Eye height and Mouth height sliders that move the eyes and the mouth up or down on the face, for every eye and mouth style and for the drawings in mascot files. Moving one toward the other pushes it along, so they never get closer than in the usual drawing. Glasses, eye bags and the magnifier follow the eyes; the mustache, the mute tape and the gum follow the mouth. The heights show wherever the look does and are saved with it and by "Save as file" (`eye-height` and `mouth-height` in mascot files, see mascots/README.md). Default puts them back, and Undo takes back a whole drag. Japanese follows the new texts; the two new Russian lines stay in English until someone translates them.
- Customize has a Name field: the name shows in a bubble when you rest the mouse on the corner mascot and under the big preview, and is saved with the look and by "Save as file" (`name` in mascot files). Default and the ready-made looks keep it.
- Customize → More tweaks opens more sliders: eye position, eye spacing, uneven eyes (one higher than the other), eye size, mouth position and size, ear size and angle, a rounder or squarer body, a slimmer or chubbier body, and how strong the blush is. Two-color eyes gives the right eye its own color, from a few ready ones or in hex. Glasses, cheeks, freckles and eye bags follow the eyes; the mustache, the mute tape, the gum and the call microphone follow the mouth; ears, hats, the headset, neckwear and the shapes of mascot files follow the body, and growing eyes or mouth keep their distance from each other. It all shows wherever the look does and is saved with it and by "Save as file" (the keys are in mascots/README.md); Default puts everything back and Undo takes back a whole drag. Japanese follows the new texts; the new Russian lines stay in English until someone translates them.
- In the big preview you can grab the eyes or the mouth and drag them around, with the same limits as the sliders and one Undo per drag.
- The corner mascot reacts to what you type, all worked out on your computer from the text in the message box. Text in ALL CAPS makes it cover its ears, a ||spoiler|| makes it cover its eyes until you send it (or take it out), a code block puts glasses on it to review it, and a long message has it hold a scroll that unrolls as you write, then pull back worried near the limit (2000 characters, 4000 with Nitro, or what fits in the message box, whichever comes first). Typing @ or # makes it point at the member list or the channel list, a / at the start opens a tiny terminal next to it showing your command, and a lot of Backspace in a row gets you a cup of tea or a pat on the arm. It has a few secrets too (try `>_`, `miau` or `meow`, `sudo` and `rm -rf`). Nothing it does covers the text you're typing. Settings → Mascot → Reacts to what you type turns it off.
- Games (Settings → Mascot → Games). Now and then (1 in 50 messages) it rolls a d20 when you send: a 20 brings confetti and a 1 knocks it over. Drag an emoji from the emoji picker or from a reaction in the chat onto it and it eats it, and its eyes turn into that emoji for a moment. A link dropped on it goes into a little portal, and an image dropped on it is held up in a picture frame (the file still goes to the attachments, as before). Every so often, when it's idle and its life of its own is Normal or Lively, it plays hide-and-seek behind the channel list (or the member list) with only the tips of its ears showing: click them to find it, or it comes back by itself after 30 seconds.
- More shortcuts it reacts to, next to Ctrl+C, Ctrl+Z and Ctrl+F: Ctrl+K jumps into a portal, Ctrl+S holds a floppy disk, Ctrl+P prints its own paw, Ctrl+X brings out scissors, Ctrl+V spits out a clone, and Esc makes it duck into the message box for a moment, but only when Esc had nothing else to close (a menu, the palette, a reply, the text in the box…) and at most once every 20 seconds. The keys still do what they always did. They're part of Games. Both new switches are on by default and rest while A life of its own is Off or Reduce motion is on. Japanese follows the new texts; the new Russian lines stay in English until someone translates them.
- Type the mascot's name (Customize → Name) in the message box and it answers "You called?". The paws over its eyes, the glasses and the emoji eyes follow the eye position, spacing, size and height you set in Customize.

**Updates**
- A new version no longer hides in a toast that lasted under two seconds: a bar at the top says which version came out and stays until you close it, with "Update now", the download progress and "Restart now" when it's installed; closing it lasts until the app opens again. The settings button keeps a dot while there's something to update, and with the app in the tray or unfocused, a desktop notification says so too. Installed by a package manager, the button explains how to update through it.
- Settings → Updates → "Update automatically", off by default: when a new version is found, it downloads and installs in the background (signature checked as always) and opens the next time the app starts.

**Notifications**
- A new message sound, like Discord's: a short cue for direct messages, groups and mentions (@everyone, @here and your roles included, following the server's notification settings), on by default in Settings → Notifications → New message sound. It plays with the window unfocused or hidden in the tray, and in another conversation; not for the conversation you're looking at, your own messages, muted channels and servers, or in Do Not Disturb. A burst of messages plays it once every 1.5 seconds. The sound can be turned off, swapped for another built-in one or for a file of yours, with its own volume, right there or in Settings → Voice → Sounds, and it goes out on the same output as the call sounds. The demo gets a DM from a friend now and then. The new texts are in English in Russian until someone translates them.

**Install**
- Opening from an app launcher on Wayland (which sets XDG_ACTIVATION_TOKEN to focus the window) no longer crashes on startup. The token is cleared from the environment when the window shows, and the copy of the environment the app kept still pointed at the old, shorter list (#44).
- Windows is now a single `larpercord.exe`, with SDL3, curl and OpenSSL inside: the official curl DLL keeps its own OpenSSL, out of the app's reach, so the connection could only look like Chrome's with them built together. The zip went from 11.4 to 9.6 MB. The three DLLs stay in the release so older versions can still update themselves; the new `.exe` doesn't load the ones left in the folder, and `install.ps1` removes them.

**Calls**
- With push-to-talk on, the Off button of noise suppression works again: it had the same id as the shortcut box above it (#35).
- Record audio from the message box: the microphone button next to the options (or Ctrl+Shift+R, changeable in Settings → Keybinds) records with the microphone chosen in Settings → Voice, with its volume and noise suppression. While it records, a bar takes the place of the box with the time and the live level; Send (Enter) sends it and Cancel (Esc) throws it away. It goes as a regular .ogg file (Opus, mono, 32 kbit/s, about 240 KB per minute), the same way as any attached file and replying if the box is replying, and the text you were typing stays in the box. Up to 10 minutes, with a warning in the last 30 seconds. It doesn't record during a call or where you can't attach files (the button says why), and Settings → Chat → Record audio button hides it.

**Media and GIFs**
- Audio files sent in chat (.mp3, .ogg, .wav, .flac, .m4a…) now play right in the conversation instead of only downloading. The player shows the waveform of the whole file as its seek bar (the part already played in the theme's accent color; click or drag to jump, hover to see the time at that point), the current and total time, the file name and size, a speed button (1×, 1.5×, 2×) and a download button. With the mouse over it, Space plays or pauses and ← → skip 5 seconds (when no text box has focus). Spoiler and sensitive covers still hide it until clicked.
- Ogg Opus, MP3 and WAV/AIFF play with no extra install: MP3 and WAV through dr_mp3 and dr_wav (from dr_libs, public domain), built into the app. FLAC, Ogg Vorbis, AAC/M4A and others play through FFmpeg when it's installed (the same one videos use); without it they stay a file card that says so. Files up to 32 MB. The sound goes to the output device and volume chosen in Settings → Voice, one audio at a time, and it stops when you leave that conversation or the window goes to the tray.
- While audio or a voice message plays, small bars dance to the sound: next to the file name, and around the play button of voice messages. They only move while playing, with the window focused and without "Reduce motion"; otherwise only the progress bar moves, and paused nothing is redrawn. Settings → Chat → Audio visualizer turns them off.

**Keybinds**
- Ctrl+R restarts larperCord, like the button in Settings → Updates, and can be changed in Settings → Keybinds. By ErnstBecker (#42).

**Themes**
- Six new themes in the community gallery on the site: Rose Pine, Tokyo Night, Kanagawa, Dracula, One Dark and GitHub Dark. By mealet (#43).

## 0.6.6

**Appearance**
- Settings → Appearance picks the fonts for the interface and for code from the ones installed on your device: the list reads the font files themselves, with the family name from each file (Windows reads C:\Windows\Fonts and your own fonts folder; on other systems fontconfig answers). "Theme" goes back to what the theme asks for, and the choice is saved, from ryokky3 (#26). Japanese follows the new texts.

## 0.6.5

**Mascot**
- A new mascot, Terminal, with a ">_" wink, is now the main one, with an all-new opening: a terminal cursor blinks, a tube-TV line lights up and opens the body, the ears spring up, the face gets typed in, it shows "..." while connecting, and it switches off like an old TV as the app opens. The demo plays the whole opening too.
- Four more openings to pick from in Settings → Mascot → Opening: Code, TV, Pixels and Portal, or Shuffle for a different one each time. "Replay the opening" plays it again.
- The mascot has its own tab in Settings. The previous mascot, Classic, is one click away there, with a live preview of both. The choice changes the app icon everywhere it can: the window and taskbar, the tray, Windows notifications and, on Linux, the app menu icon. On Windows, the icon of the app file itself stays Terminal.
- The mascot shows up around the app: asleep in an empty inbox, pins, saved messages and friends list, and loading with the conversation. Click it on the login screen or in Settings → About and it reacts.
- Corner mascot: it sits on the message box (Settings → Mascot → Corner mascot, on by default). Its eyes follow the mouse, it types along with you, hops when you send, gets startled by a mention, and laughs, celebrates, gets sad or waves at what you write (all worked out on your computer). It falls asleep after a few idle minutes. Grab and throw it and it bounces off the window edges, gets dizzy and walks back. Hover over it slowly to pet it, double-click it for a trick, and poke it too many times and it sulks for a few seconds, a different way each time.
- It also puts on a headset in a call, with tape over its mouth while you're muted. It catches fire when you type fast, gets dizzy when the conversation scrolls too fast, eats a file you drag into the window and worries when a message can't be sent. Late at night it has eye bags and yawns, in the morning it stretches, on some dates it wears a hat, and it takes the theme's accent color. It reacts to the emoji you add to messages and shows your status: a moon when idle, a sign on Do Not Disturb (mentions don't startle it then), see-through when invisible. Ctrl+C makes a clone, Ctrl+Z walks it backwards, Ctrl+F gives it a magnifier, and the mouse wheel over it tickles. Right-click it for Do a Trick, Sleep, Hide for 1 Hour and Switch Mascot.
- A life of its own: left alone, it does things by itself now and then. It drinks coffee, reads, plays a handheld, blows gum, whistles, exercises, chases a fly, fishes an emoji out of the chat's reactions, stacks blocks that fall on it when you move, doodles a heart in the message box until you type, and waters its little plant. Sometimes it goes for a walk around the window: it sits on the last message, climbs the member list, hangs from the header or peeks out from behind the channel list.
- It plays with the interface too. It sits on the "is typing…" line, takes deleted messages to a trash can, erases edited ones, pushes the jump-to-present button, holds on (or falls) when you resize the window, and carries a letter to the DM icon when a DM arrives. It tries to grab the pointer when it rests nearby and sits on it when it rests on top. It jumps along when you switch channels and peeks when you open a thread.
- While the window is unfocused it waits for you; gone for 20 minutes, it sets up a tent and a campfire. When you come back it packs up, runs to the mouse and, after hours away, says it missed you. Its little plant grows a bit each day you use the app until it's a small tree, and wilts after a week away until it gets watered.
- Settings → Mascot sets how lively it is (off, calm, normal, lively) and has a switch for wandering, the interface, the mouse, waiting for you and the plant.
- It stays light: it only draws extra frames for a moment when something happens, and only while the window is focused. Its life of its own only starts after 8 seconds without you touching anything and stops when it falls asleep; measured on the demo, about half a percent of one CPU core while it's awake and idle.
- Customize the Terminal mascot in Settings → Mascot → Customize: 15 eye styles, 16 mouths (:3, uwu, tongue out, little fang, vampire, open grin, tiny o, flat, wavy, smirk, toothy grin, pout, whistle, buck teeth and the "_" cursor), 22 hats (crown, top hat, beanie, cap, cowboy, chef, halo, devil horns, flower crown, viking, wizard, bow, propeller, beret, tiara, pirate, space helmet, sprout, antennae and the three holiday ones), 12 accessories (glasses, sunglasses, monocle, eye patch, blush, freckles, band-aid, mustache, bow tie, scarf, bandana, earring), 6 ear shapes and 14 color palettes, or your own hex for each color, or the theme's accent. Every eye and mouth works with every face: a big preview switches between them and shows the call headset and the mute tape.
- 16 ready-made looks (Hacker, Wizard, Royalty, Pirate, Chef, Astronaut, Nerd, Kitty, Vampire, Cowboy, Cutie, Little devil, Robot, Little angel, Viking, Garden), plus Random look, Default and Undo. The look shows wherever the mascot does: the five openings, About, the empty lists and the corner mascot, with everything it already did. The default look stays exactly as before. Holiday hats still show up when no hat is picked, and Settings → Mascot → Holiday hats turns them off.
- Mascot files: a .kdl file in the mascots folder (~/.config/larpercord/mascots, %APPDATA%\larpercord\mascots on Windows) picks parts and colors, or draws its own eyes, mouth and layers in front of or behind the body with circles, ellipses, rectangles, lines and paths, one drawing per expression. "Save as file" writes the current look, the list in the tab picks a file, "Open folder" opens the folder, saving a file updates the mascot right away, and a broken file shows file:line:column while the mascot keeps the last version that worked. The format is in mascots/README.md, and the site has a community mascot gallery with four examples.

**Messages**
- Arabic and Hebrew in the message box now show in the right order and line up to the right, like in sent messages, from majd-tqe's report (#9). The cursor, clicking, selecting and Backspace follow the text on screen, and ← and → move across the screen instead of through the text.
- Old messages now show the server nickname, server avatar and role color, like new ones. Discord's message history doesn't say who the author is in the server, so larperCord asks the gateway for the authors it doesn't know yet: at most one request per server every 30 seconds (Discord's limit), with the pages you load in the meantime joined into it, up to 100 people per request, each person once per session, never in DMs or groups, paced with everything else sent to the gateway. If Discord asks to slow down, the same request waits longer each time, and after three refusals in a row that server stops asking for the rest of the session.

**Tabs**
- Saved tab sets: keep groups of tabs like "work" or "games" and switch between them at once. Right-click the tab bar (or use the command palette) to save the open tabs as a set, switch, rename, delete or leave it. While a set is in use, the tabs you open, close or switch to are saved in it, along with the split view, and its name shows before the tabs. Switching only loads the channel on screen; the other tabs load when you open them, so a set with 10 tabs doesn't send 10 requests to Discord. A channel you can no longer see is left out with a short notice. Sets are saved per account, only on this computer, and the one in use comes back when the app opens. Ctrl+Shift+PageDown goes to the next set (changeable in Settings → Keybinds).

**Servers**
- Server profiles, from helpik1's request (#19): in a server, people show the nickname and picture they set for that server instead of the global ones, wherever they appear: messages, replies and mentions, the member list, the voice channel list and the call mixer, the @ list in the message box (it finds people by either name), and the profile card, which shows the server nickname with the global name smaller underneath, plus the server bio, pronouns and banner when they set them. DMs and groups keep the global name and picture.

**Calls**
- The mute state follows you across sessions: leave a call muted (even by force-closing the app) and the next one starts muted; leave unmuted and it starts unmuted, from ryokky3 (#27).
- Call screen, the other half of helpik1's request (#19): clicking a voice channel now opens the call in the chat area, one tile per person with their server picture and nickname, a green ring while they talk, their mic and sound when they're off, what they're playing, and a LIVE badge when they're streaming. Click a tile for that person's menu (volume, mute for me). Your mic, sound, mixer and leave buttons sit where the message box was. Esc, "Back to chat", switching tabs or a text channel take you back, and clicking the call status on the voice bar opens it again. DM and group calls get the same grid above the conversation. Terminal themes show it as text. No camera or screen share, as before.
- The call screen follows the theme: each tile uses the theme's colors, corners and card style (glass in vidro, paper in papel, a clipping in editorial…) with just a touch of each person's photo color, and the text switches color when it would be hard to read. Theme authors pick this with `call-style` and `call-tint` on the `messages` component (see the theme guide). Alone in a call, your tile gets smaller and below it the mascot naps next to "Just you here" and an "Invite people" button. The buttons sit in a bar with the call time, and hovering your own tile shows your mic level with the voice detection threshold mark (only then does it cost anything).
- In the call mixer, each person now has "Remove noise" and "Even out volume", both off by default and only for that person. Remove noise runs the same noise suppression as your microphone on their sound (it uses a little CPU while they talk, so it's per person). Even out volume raises a quiet voice and lowers a loud one toward everyone else's level, without lifting the background hiss in their pauses. Your choices are saved and apply to every call.

**Keybinds**
- Keybinds can be changed, from ShuyaGit's request (#18). In Settings → Keybinds, click a shortcut and press the new keys. Combinations already in use, fixed ones (copy, paste, new line, moving through text), plain letters and Ctrl+Alt with a letter (AltGr on many keyboards) are refused with the reason; "Default" puts one back. Tips that mention a shortcut show your current keys.

**Text in any language**
- "Online", "Offline", "Proxy" and other words that were missing from the translation files now show in Japanese and Russian, and so do the descriptions and options of the built-in themes, the status duration submenu, the message box tips and the image actions, from DivannKokos's report (#20). The theme card shows the whole description, in up to two lines, with the rest on hover.
- Translated text no longer gets cut off in Russian and Japanese: About, the wait notice when joining servers, the focus mode note and "N mentions in <server>" with a long server name. Buttons and notes in Settings no longer run past their edge either. From DivannKokos's report (#22).
- Russian uses ё where it belongs, from DivannKokos (#21).
- Japanese, Chinese and Korean input shows while you're converting it in the message box, with the underline, instead of appearing only after you pick the candidate, from ryokky3 (#23). In the other text fields (search, the command palette, Settings) it shows in a small box at the cursor.
- With Arabic or Hebrew at the bottom of the conversation, the jump-to-present button moves to the left corner instead of covering the start of those lines.

**Lighter**
- larperCord now opens straight into your servers, channels and recent conversations from what it saved last time, without waiting for Discord: in our tests the first usable screen went from about 1.6 s to about 0.1 s. While it connects, the message box says you can send once connected, and nothing jumps when the live data arrives; your active tab set comes back too. It follows Settings → Privacy → "Keep messages on disk", and Clear cache removes it.
- On Linux, memory no longer piles up after hours of use: freed image buffers go back to the system instead of staying inside glibc's per-thread arenas. On the developer's account, after 4.5 hours, that was about 190 MB held for nothing.
- Settings → Performance lets you pick the renderer: Automatic or one of the ones SDL has on your computer (Vulkan, OpenGL, Direct3D…). It applies the next time the app opens; if the chosen one doesn't open, the app starts with the automatic one and says so. Handy when one of them misbehaves with your graphics driver.

**Install**
- `install.sh --purge` and `install.ps1 -Purge` also delete the settings, the cache, the downloaded FFmpeg, your sounds and the saved accounts, from DivannKokos's request (#12). Uninstalling without it still keeps your settings.
- Settings → Advanced → "Delete all data…" does the same from inside the app, without uninstalling it: after you confirm, it deletes the settings, your themes, mascots, sounds and plugins, drafts and saved messages, the conversation cache, the downloaded FFmpeg, the debug logs and the saved accounts with their tokens in the keyring (Windows Credential Manager), then closes. Nothing gets written back on the way out.

**Site and docs**
- Theme builder: a divider between the dark and light previews gives one of them more width; double click puts it back in the middle.

## 0.6.4

**Conversations**
- The DM list keeps the most recent conversation on top, live: a message you get or send moves its DM up right away.
- A new DM shows up at the top, even when only its message arrives, and a DM you closed comes back when a new message arrives in it.

**Messages**
- After you pick an emoji, from the picker or the `:` list, the cursor stays right after it instead of jumping to the start of the box.
- Reaction emoji sit in the middle of their chip, with any emoji font.
- Backslash escapes are hidden like in Discord: `\.`, `\*`, `\_`, `\~` and `\\` show just the character, outside code, in messages and embeds.
- "1. Hello" keeps its space after the number.
- In the bubble layout (Bolhas, Cupertino), "(deleted)" from the message log no longer covers right-aligned text.

**Media and GIFs**
- Long GIFs, like Klipy's, play on their own again, not only while the mouse is over them. This broke in 0.6.2.
- Embed images that Discord's media proxy won't resize, like X/Twitter card images, now load from the original. With the debug log on, it says why an image failed.
- GIFs and animated emoji stop while the larperCord window isn't focused, like Discord, so a window left open on another monitor or behind a game doesn't keep redrawing for them. Hovering one still plays it. Images and thumbnails in link embeds now follow "Automatically play GIFs" too; before, they always played.

**Calls**
- Voice channels with a call show how long it has been going, like Discord (`16:42:14`). Pick the format, or turn it off, in Settings → Appearance → Voice channels. You can also write your own with `{H}`, `{mm}`, `{ss}` and the other fields. The app only wakes up for it while a timer is on screen, and only when the text changes: once a second with seconds, at most once a minute without.
- The right-click menu of someone in your call has a User Volume slider, from 0 to 200% (100% is normal), and Mute for Me, from mdvtnk's request (#17). It shows wherever the person appears: the voice channel, the member list, a message, a DM call. It's the same setting as the call mixer, so the two stay in sync and it's saved. Muting keeps their volume, so unmuting brings back the same level, in the menu and in the mixer.
- In the terminal-style themes (Terminal, Subsolo), [mixer] and [leave] in the voice bar now react where they're written. The clickable area used to sit at a fixed spot near the right edge, so it moved with the channel name and the font size.
- Someone you muted with the old mixer button (volume at zero) now shows as Mute for Me, and unmuting brings them back at the normal volume.

**Voice**
- On Windows, push-to-talk works while another window is focused, like a game, from helpik1's request (#14). The app reads the key without a keyboard hook, and the other app still gets it. On Linux it still needs the larperCord window focused.

**Tray**
- On KDE and GNOME with Wayland, clicking the tray icon brings the window to the front when it's behind another window or minimized. Before, KDE only marked it as wanting attention and GNOME showed an "is ready" notice.

**Text in any language**
- Russian interface, translated by pIat0n (#15, #16). Pick "Русский" in Settings → Language, or the app follows a Russian system. Dates use Russian month and weekday names.
- Discord timestamps show in Japanese and Russian, including relative ones like "3日前" and "3 дня назад", with Russian plural forms. Before they came out in English.
- In Japanese, dates are in the right order again (some showed day/month or year/day/month), and the `has:` and `before:` search suggestions work in Japanese and Russian.
- More Arabic and Hebrew fixes, from majd-tqe's report (#9). Embed titles, authors and field names that start in Arabic or Hebrew end at the right edge of the card, like the description.
- A line that starts with a number, like "1." or "12-", is right to left, with the number and its dot or dash in the right order.
- Brackets are mirrored, and "؟" and other punctuation land in the right place when the sentence has English in it.
- Bullet and numbered list markers sit on the right.
- The extra space before some emoji, like ⚠️ and ✔️, is gone.
- The Urdu letter ہ shows instead of `?`, and Settings no longer lists Arabic as missing a font when DejaVu Sans has it.
- The England, Scotland and Wales flags, and a few rare invisible characters, no longer cost about 5.5 MB of memory for each font and size.

**Known limitations**
- Arabic and Hebrew you type in the message box still go left to right. The message shows correctly once it's sent.
- Scripts that need shaping, like Devanagari, Bengali, Thai or Khmer, show their real letters one by one, without conjuncts or reordered vowel signs.
- The single Windows `.exe` is opt-in, for people who build it with `-Dsingle-exe=true`. Releases still ship the `.exe` with its DLLs.
- App commands in the right-click menu, files in bot forms and recording voice messages aren't supported yet.

## 0.6.3

**Calls**
- Being moved to another voice channel no longer drops you from the call: larperCord follows you to the new channel.

**Project**
- Every file in a release is now built on GitHub, each with an attestation that it came from this code.

## 0.6.2

**Calls**
- Call from any DM or group DM with the phone button in its header, in every theme. An incoming call shows a card with Accept and Decline and rings until you answer. It also sends a system notification and flashes the taskbar, even with the app in the tray.
- In Do Not Disturb, or in a muted DM or group, the card shows up without the ringtone. Ringing stops when you answer on another device or the caller hangs up.
- Settings → Voice → Sounds picks each call sound: Off, Classic, Soft, Crystal, Retro or your own WAV or Ogg Opus file, with a preview and a volume. Someone joining or leaving your call has a sound too, off by default.
- Right-click the microphone or headphone button to switch the device and its volume, mid-call too. Ctrl+Shift+M mutes and Ctrl+Shift+D deafens.
- The start of a word after someone's short pause no longer stutters. Their silence frames are played now, so the buffer is still there when they talk again.

**Bots and apps**
- Buttons and select menus in bot messages work. A bot that doesn't answer shows "This interaction failed", and replies only you can see can be dismissed.
- Bot forms (modals) open in the app, with text fields, selects, and radio and checkbox groups.
- Typing `/` lists the slash commands of the server's bots and of your apps. A panel fills in subcommands, options, choices, suggestions as you type, and files.
- A click that waited more than 12 s, during a reconnect for example, is dropped instead of reaching the bot late.

**Messages**
- While replying, "@ ON / @ OFF" in the reply bar chooses whether the author gets pinged.
- A button next to GIF sends the next message silently (or start it with `@silent `), without link previews, or without pinging anyone.
- Each file in the upload tray can be marked as a spoiler and get alt text.
- Vote in polls, remove your vote or see the results first. Counts update live, and clicking an answer shows who voted for it.
- Right-click a reaction, or use View Reactions in the message menu, to see who reacted, with Super Reactions apart.
- The pinned messages panel loads more than 50 pins.
- A reply to a message with no text shows what it had: the file name, the sticker, a voice message, the poll question or the embed title.
- Mentions are highlighted by Discord's rule: you, replies that ping you, your roles, @everyone and @here, following the server's suppress settings. Unread counts, the inbox and notifications use the same rule, and the highlight shows in every theme.

**Media and GIFs**
- Spoilers and media that Discord marks as sensitive stay behind a cover until you click, and nothing downloads before that.
- Images whose Discord link expired are refreshed on their own, only the ones on screen.
- Voice messages have a player: play, pause, a waveform to seek and the length.
- The GIF picker has a Stickers tab with this server's stickers, your other servers' and Discord's own. One click sends.
- Hover a GIF, in a message or in the picker, and click the star to add it to your favorites or take it out.
- Long GIFs play every frame at their real speed. In a 16 s test, 0.6.1 kept 25 of 400 frames; now all of them play, in about 8 MB.
- Settings → Chat → Videos has Choose FFmpeg folder… for a "shared" FFmpeg 7, 8 or 9 you already have: the app checks the folder has the whole set and looks there first. When FFmpeg isn't found, the page says why: the file names it looked for, an `ffmpeg` on PATH that's a static build without the libraries (what winget, choco and gyan.dev install), a version the app doesn't use, or a library that's there but didn't load, with the system's reason. On Windows the app also looks for the DLLs in every PATH folder. From DivannKokos's report (#10).

**Your account**
- Block and unblock from a person's menu or full profile.
- Ignore is saved to your Discord account. People you ignored before stay ignored on this computer, and Settings → Alerts & Filters lists both.
- Add Friend in profiles and in the person menu, plus an Add Friend tab on the Friends page that takes a username. Outgoing requests can be cancelled on the Pending tab.
- Mute and notification levels sync with your account, for servers, categories, channels and DMs, and changes made on your phone show up right away.
- Changing your status saves it to your account, so leaving Invisible works. Idle, Do Not Disturb and Invisible can last from 15 minutes to 3 days, and the app opens with the status your account has.
- Click your name to set a custom status, with text, an emoji and when it clears.
- Settings → My Account edits your display name, pronouns and About me.
- Rich Presence: games and apps that support it can show what you're playing. It's off by default, in Settings → Privacy, and while it's off nothing listens.

**Conversations**
- DMs from people who aren't your friends go to Message Requests under Friends, with a Spam tab, Accept and Decline. They don't notify.
- Right-click a group → Group Members… to add friends or, if the group is yours, remove someone. Leaving asks first.
- Edit a thread from its menu or by clicking its title: name, forum tags and auto-archive. Archiving and locking are one click.
- The threads panel has a Private tab with the archived private threads.

**Servers**
- Kick, ban, time out, and server mute or deafen from a person's menu, only when you're allowed to. Kick, ban and timeout ask first and take a reason for the audit log. Bans, in the server menu, lists banned people and unbans them.
- Joining from an invite warns first: joining or leaving many servers quickly is the most common reason third-party client accounts get locked.
- If a server asks you to accept its rules, the message box says so and opens them, and you answer every item yourself. Servers with onboarding have it in their menu.
- The message box shows slowmode with a countdown, and says why you can't send: no permission, a locked thread, a timeout or an AutoMod quarantine.
- If Discord refuses a message for coming too fast, you see how long to wait, and the message stays there to resend.

**Text in any language**
- Arabic and Hebrew display correctly, from majd-tqe's report (#9). Arabic letters are joined, and right-to-left text comes in the right order in messages, embeds and user, channel and server names. Right-to-left paragraphs are right-aligned in messages and embeds, each paragraph on its own when a message mixes languages. Copying still gives exactly what was written.
- A letter the theme's font lacks, in any script (Thai, Devanagari, Ethiopic, Georgian, Armenian, Tibetan…), comes from a system font that has it instead of `?`. Each block is looked up once, only when such text appears.
- The whole interface is in Japanese now, building on nakayama900's translation. Translations live in one file per language (`i18n/ja.kdl`, English text then the translation), so anyone can fix a line or start a new language without touching the code; a copy in the settings folder overrides the built-in one.

**Themes**
- Zen's footer shows your status and the mute and deafen buttons, and its server rail gets a background when it slides in.
- Terminal, Subsolo, Orbital and Editorial show [mic] [audio] buttons, struck through when on. Editorial's masthead shrinks to one line in short windows.
- Papel has search, a members button and a "Roll call" column, and the minimal header (Zen, Cupertino, Bolhas, Orbital, Editorial, Papel) has a search button.
- For theme authors: `hide-below-height=`, `only-below-height=` and the `me`, `mic` and `deaf` status bar items.

**Network and privacy**
- The proxy has its own page, Settings → Network, with separate fields: type (HTTP, HTTPS, SOCKS5, SOCKS5h for Tor), address, port, login and password, which can hold any character. Pasting a full URL fills them all, and the saved proxy carries over. The sign-in screen has the same form ("Connect through a proxy"), which covers signing in too, and when signing in can't reach Discord it says why and asks "Can't reach Discord — try a proxy?". A changed proxy is used on the next connection attempt right away. From degger80's report in #6, with DivannKokos's suggestions.
- Voice calls always connect directly, even with "Use the proxy for everything", and the setting now says so.
- Settings → Advanced → Debug counts how often Discord asked for a captcha, asked to verify the account or refused the session.
- Every connection to Discord, voice and its image servers included, uses the same web client headers, only over https and wss, and always checks the certificate.

**Lighter**
- The Linux download went from 15.36 to 14.25 MB and exports no symbols (0.6.1 exported 4,988). OpenSSL is now built with only what the app uses, and SDL3 and curl leave out the rest.
- A frame is about 7% faster, and the first conversation shows up about 10% sooner: on Linux, fontconfig gets ready while the window opens. Memory and idle CPU stayed the same.
- The Windows zip grew about 4% with this version's features.

**Linux and Windows**
- On a Wayland desktop the app runs natively, with X11 as the fallback, from Kainoa Kanter (ThatOneCalculator) in #1.
- With Close to tray on, as it is by default, the tray icon stays from launch until you quit, like in the official app: Open and Quit in its menu work with the window open, and a left click on the icon shows or hides the window, on Windows and on Linux. Turned off, there's no icon and closing quits. On Linux the icon is a small separate process that speaks the tray protocol over D-Bus itself, without GTK: about 6 MB and no wake-ups while idle, down from about 14 MB and 20 wake-ups a second with libappindicator. It comes back on its own if it dies. From DivannKokos's request (#11).
- An update replaces the file you actually run, whatever its name, and reopens it. Before, the Linux download kept the old version and Restart could open nothing.
- The app opens on a system with no fonts at all, such as a Windows or wine install without `C:\Windows\Fonts`, with the font built into Dear ImGui.
- On Windows, the app's hints name the Windows folders and Credential Manager, and OpenSSL no longer reads an `openssl.cnf` from a folder another user could create.
- `larpercord --version` prints the version, for scripts and packages.

**Site and docs**
- The site has a theme builder with a live preview, a contrast check and a `.kdl` to download. It also takes the colors of a BetterDiscord or Vencord theme.
- A community theme gallery, checked on every build: preview a theme, open it in the builder or download it.
- Try it in the browser: the real app in demo mode, compiled to WebAssembly, with no account and no network.
- New pages for what larperCord has that Discord doesn't, for every keyboard shortcut, and a plugin directory with a starter that writes a Lua plugin for you.
- The download section picks your system (AUR, install script or zip), and the docs cover Windows next to Linux.

**Fixes**
- Joining, leaving, mute and deafen are no longer lost when the connection drops at that moment. They go out again when the session resumes.
- After a restart, the memory limits for images, each GIF and messages dropped to their minimums, which made GIFs choppy. They load as saved now, a 0.6.1 settings file is repaired, and each GIF can use 32 MB again.
- Offline members' names are readable again in every theme.
- Context menus stop at the window's height and scroll.
- Holding Ctrl+Tab switches tabs once per press, and flipping quickly through channels only asks Discord for the member list of the one you stop on.
- On Windows, the debug log can be opened, copied or attached while it's on. Before, no other program could read the file until you turned it off.

**Known limitations**
- Arabic and Hebrew you type in the message box still go left to right. The message shows correctly once it's sent.
- Scripts that need shaping, like Devanagari, Bengali, Thai or Khmer, show their real letters one by one, without conjuncts or reordered vowel signs.
- The single Windows `.exe` is opt-in, for people who build it with `-Dsingle-exe=true`. Releases still ship the `.exe` with its DLLs.
- App commands in the right-click menu, files in bot forms and recording voice messages aren't supported yet.

## 0.6.1

**More languages and screens**
- The interface is available in Japanese, from nakayama900. Text with no translation yet appears in English.
- Japanese, Korean and Chinese text now shows up. The fonts only load the first time a letter needs them, and the interface language picks the letter forms.
- The interface follows the display scale on Windows and X11, from Davyd Khanin. It no longer comes out tiny at 125% or 150%.
- Settings → Appearance has an interface size from 75 to 200%, and Ctrl + , Ctrl - and Ctrl 0 change it from anywhere.
- F11 and Alt+Enter turn fullscreen on and off.
- Channel and user names in stylized letters (𝗠𝗲𝗺𝗲𝘀, ʀᴇɢʀᴀs) show as normal letters when no font has them, instead of `??????`. Settings → Advanced lists any writing systems that still have no font.

**Sharper**
- Small text is sharp. Sizes like 13.5 were generated at 14 and then shrunk like an image, which blurred almost all gray text.
- Text also lines up with screen pixels at sizes like 125%.
- Secondary text has a minimum contrast in every theme, including community themes.
- Settings → Advanced → Text changes the weight of the text and how letters fit the pixel grid, live.
- Avatars, icons and images are stored at the size they appear and reduced with a better filter. Before, a 128 px photo was shrunk by the graphics card without filtering, which made it jagged. It also uses less memory.
- Images no longer come out stretched or cropped in messages, embeds and the full-screen viewer, including after resizing the window.

**Calls**
- Fixed the bursts of loud noise, from Davyd Khanin. Some voice packets carry padding, and the app sent those to the decoder still encrypted.
- The start of a sentence after a pause no longer comes out louder than it should. Silence frames now go through the decoder, and it starts fresh after a pause or a large gap.
- Settings → Advanced has a debug log: turn it on, make the problem happen and send the file, with no terminal. It also records volume jumps and how many packets had padding.

**New**
- Search has a side panel with filters, sort order and pages. It searches this computer as you type, and Discord when you press Enter.
- Forward a message to another channel.
- Join a server from a link or code, and create and edit invites from the server and channel menus.
- GIF picker next to the emoji button: trending, search and your favorites from Discord. A GIF plays when you hover it.
- Copy an image from the full-screen viewer, and zoom in it with the mouse wheel. Ctrl+V pastes PNG, BMP, JPEG, GIF and WebP.
- Leave a server from its menu, with a confirmation.
- The pinned messages panel shows images, videos and link previews.
- Settings → Chat can download FFmpeg on Windows so videos play inside the app, with a warning first and a checked SHA-256.
- Settings → Performance has limits for images, each GIF and messages in memory.

**Fixes**
- While invisible you no longer appear online for a moment when the app opens. Your status now goes out with the first connection.
- Reconnecting is calmer: a connection only counts as good after a minute. A server that accepts and then drops the connection no longer means a new login attempt every few seconds.
- Holding Shift+J or Shift+K in Vim mode no longer sweeps through channels.
- Dragging the message scrollbar no longer gets stuck when the mouse drifts off it or older messages load.
- A GIF that declares a huge size is refused before decoding, from svindler, so a small file can't use up your memory.
- Themes with no user panel, like Zen, have a settings button in the header.
- Installed through a package manager, the app tells you to update through it.

**Project**
- larperCord is now licensed under GPL-3.0.

## 0.6.0

**Plugins**
- Translate has options now: target and source language on its card in Settings → Plugins, and "Translate to…" on the right-click menu for one message. A 🌐 on the message toolbar, and `/tr es hello` puts a translation in the message box.
- Scam guard marks in red the classic Discord scams in other people's messages: addresses that imitate Discord or Steam, fake free Nitro with a link, shortened links with bait. It runs on your computer, with no network, and official addresses are never marked.
- CVE radar finds `CVE-2021-44228` in messages and shows the severity, the CVSS score and a summary under it, from the official record. Each number is asked once, and only after you approve the host.
- GitHub cards put the title, the state and the stars under `owner/repo#123` and GitHub links.
- What did I miss sums up the unread messages in a channel: how many from each person, mentions of you, unanswered questions, links and files, with a click to each one.
- Also new: Clean links removes tracking from the links you send, and Links and files lists what was shared in the channel.
- Reminders understand times and dates (`/remind tomorrow 9am`, `/remind every day 8:30`), have a second list on the right-click menu, and what already fired can come back in 10 minutes.
- Highlights shows how many you haven't seen, can mute a channel, follows edits, and can use desktop notifications.
- Bookmarks, the word filter, snippets, timestamps, stats and the demo plugins no longer come with the app: the first two became built-in features. If you have them they keep working, and a button archives them to `plugins/antigos/`. Nothing is deleted.
- A bundled plugin with a newer version shows an update button on its card, and keeps your file as `.bak`.
- New for plugin authors: options on the card (`larper.settings`, `select`, `toggle`), second lists and toolbar buttons on menus, suggestions in the message box (`larper.completions`), rules for what you send (`larper.rewrite`), `larper.copy`, `larper.open`, a number on the panel tab, red notes, the `edit`, `dismiss` and `hosts` events, a `contains` filter that keeps messages away from Lua, and attachments, replies, mentions and the read position in `larper.messages`.
- A plugin that falls behind loses messages instead of holding up the others, and its card says so. Each plugin has its own limit of desktop notifications, so a noisy one doesn't eat a reminder's.
- The card warns about a plugin that reads messages and can also send something out.
- Closing a translation with its × no longer makes the next "Translate" do nothing.

**Messages**
- `<t:…>` times appear as a date or "in 2 hours", in your time zone, instead of the raw code.
- Over a link, the mouse cursor turns into a hand. Text selection was overriding it.
- Dragging the message scrollbar no longer selects text, and the resize handle no longer covers the scrollbar.
- Mark as read and mark as unread always reach Discord now. While invisible they stayed on your computer only and came back the next time you connected. Your status no longer stops read confirmations; an unfocused window still doesn't confirm on its own.

**Lighter**
- A frame that comes out the same as the last one isn't drawn again, so network events that change nothing on screen cost less.
- Moving the mouse with no button pressed asks for fewer frames.
- After a minute in the tray or minimized, images leave memory, except small ones that were on screen.
- Settings → Performance shows where the memory goes: images, messages, people, servers, fonts, driver and libraries.

**Accounts**
- The sign-in screen lists every saved account as a button, however you got there, with a warning to use a secondary account before you paste a token.
- When Discord refuses a token, the app forgets it instead of trying it again every time it opens. If the session ends with the app open, it goes back to the sign-in screen.

**Install**
- The Linux download runs on distros from about 2022 onward (glibc 2.34), and no longer needs a very recent one. SDL3, libcurl and OpenSSL now come inside it, so the file went from about 7 MB to about 15 MB.
- GitHub Actions builds the Linux file, opens it on Ubuntu, Debian, Fedora, openSUSE and Arch, and publishes an attestation you can check with `gh attestation verify`.
- The Linux installer names its shortcut after the window's app ID, so taskbars that look up the icon that way can find it. Running it again replaces the old shortcut.

## 0.5.0

**Windows**
- larperCord now runs on Windows 10 and 11, built from the same code.
- Tokens stay in Windows Credential Manager.

**Updates**
- Checks for a new version when opening or from Settings → Updates.
- One button downloads, installs and restarts. Updates are signed, and a version without the right signature isn't installed.
- Restart button in Settings, and this page.

**Voice**
- Microphone noise suppression with RNNoise, on by default and switchable mid-call. It doesn't run with the push-to-talk key released.
- Less stutter and no more clicks when packets are lost or arrive out of order; the audio buffer grows when the network hiccups.
- When the network stalls, the voice fades out instead of cutting off mid-word, and comes back without a pop.
- A pause from someone's noise gate is no longer treated as a bad network, which kept the audio delay low.
- Noise suppression uses less CPU in the published builds: it picks the faster path for your processor when it runs.
- People no longer cut out for a moment when someone joins or leaves the call.

**Tray**
- Closing and reopening no longer stacks up tray icons. On Linux the icon lives in a small separate process that only exists while the window is hidden, so GTK stays out of the app.

**Layout**
- Drag the edge of the channel list, the member list or the panes of a split view to resize them. A double-click goes back to the theme's width, and your choice is saved and follows you between themes.
- A narrow conversation keeps working: the search box steps aside before the buttons do.

**Messages**
- A BOT tag next to the name of bots and webhooks, with a check mark for verified bots, in messages, the member list, DMs and profiles.
- Webhook messages keep the name and picture each one was sent with.
- Bot messages in the newer component format, which used to appear blank. Forwarded messages and polls appear as cards.
- Text in embeds can be selected and copied.
- Discord markdown: headings, small text, quotes, lists and `[text](url)` links. Line numbers in code blocks.
- Selecting text inside a code block is visible now.
- Esc cancels editing a message.
- Right-clicking or middle-clicking a button no longer also triggers its normal click. In the message toolbar, for example, it used to add the reaction.
- Optional code diagnostics while typing a code block, from a language server you choose.

**Servers and groups**
- Edit a server (name, description, icon, banner) or a group DM (name, icon).
- Delete threads.
- Server banners at the top of the channel list and on invite cards.
- Click a server banner to see it in full, and the same for a profile banner. Server and user menus can open the icon or picture too.
- Friends, group and pin icons redrawn.

**Plugins**
- Plugins now run on a thread of their own: a slow or stuck one can't make the interface stutter, and it's stopped with the error on its card. With no plugin on, the thread doesn't exist and no Lua is loaded.
- New plugins that come with the app: bookmarks, reminders, highlights, local filter, snippets, translate and channel stats. Settings → Plugins installs them, without touching your files.
- Settings → Plugins shows a card for each plugin, from a manifest at the top of the file: name, description, version, what it asks for, errors and a way to open its panel, even when it's off.
- What plugins can do now: panels in a side panel you dock on either side, right-click entries on messages and people, badges, notes and collapsing with "show" under messages, their own storage, timers, desktop notifications, loaded messages, jumping to a message and inserting text in the message box.
- Optional HTTPS for plugins, only to hosts you approve one by one, with no cookies, token or Discord headers.
- Files in the plugin folder from before keep working, and the examples that came with the old versions aren't removed.

**Lighter**
- Smaller executable, faster opening and less memory.

## 0.4.0

First public version: real Discord connection, voice with end-to-end encryption, threads and forums, read state, search, Lua plugins and 11 themes.

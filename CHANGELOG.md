# What changed in each version

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

**Messages**
- Arabic and Hebrew in the message box now show in the right order and line up to the right, like in sent messages, from majd-tqe's report (#9). The cursor, clicking, selecting and Backspace follow the text on screen, and ← and → move across the screen instead of through the text.

**Servers**
- Server profiles, from helpik1's request (#19): in a server, people show the nickname and picture they set for that server instead of the global ones, wherever they appear: messages, replies and mentions, the member list, the voice channel list and the call mixer, the @ list in the message box (it finds people by either name), and the profile card, which shows the server nickname with the global name smaller underneath, plus the server bio, pronouns and banner when they set them. DMs and groups keep the global name and picture.

**Calls**
- Call screen, the other half of helpik1's request (#19): clicking a voice channel now opens the call in the chat area, one tile per person with their server picture and nickname, a green ring while they talk, their mic and sound when they're off, what they're playing, and a LIVE badge when they're streaming. Click a tile for that person's menu (volume, mute for me). Your mic, sound, mixer and leave buttons sit where the message box was. Esc, "Back to chat", switching tabs or a text channel take you back, and clicking the call status on the voice bar opens it again. DM and group calls get the same grid above the conversation. Terminal themes show it as text. No camera or screen share, as before.
- In the call mixer, each person now has "Remove noise" and "Even out volume", both off by default and only for that person. Remove noise runs the same noise suppression as your microphone on their sound (it uses a little CPU while they talk, so it's per person). Even out volume raises a quiet voice and lowers a loud one toward everyone else's level, without lifting the background hiss in their pauses. Your choices are saved and apply to every call.

**Keybinds**
- Keybinds can be changed, from ShuyaGit's request (#18). In Settings → Keybinds, click a shortcut and press the new keys. Combinations already in use, fixed ones (copy, paste, new line) and plain letters are refused with the reason; "Default" puts one back. The mute and deafen button tips show your current keys.

**Text in any language**
- "Online", "Offline", "Proxy" and other words that were missing from the translation files now show in Japanese and Russian, and so do the descriptions and options of the built-in themes, the status duration submenu, the message box tips and the image actions, from DivannKokos's report (#20). The theme card shows the whole description, in up to two lines, with the rest on hover.
- Translated text no longer gets cut off in Russian and Japanese: About, the wait notice when joining servers, the focus mode note and "N mentions in <server>" with a long server name. Buttons and notes in Settings no longer run past their edge either. From DivannKokos's report (#22).
- Russian uses ё where it belongs, from DivannKokos (#21).
- With Arabic or Hebrew at the bottom of the conversation, the jump-to-present button moves to the left corner instead of covering the start of those lines.

**Lighter**
- On Linux, memory no longer piles up after hours of use: freed image buffers go back to the system instead of staying inside glibc's per-thread arenas. On the developer's account, after 4.5 hours, that was about 190 MB held for nothing.
- Settings → Performance lets you pick the renderer: Automatic or one of the ones SDL has on your computer (Vulkan, OpenGL, Direct3D…). It applies the next time the app opens; if the chosen one doesn't open, the app starts with the automatic one and says so. Handy when one of them misbehaves with your graphics driver.

**Install**
- `install.sh --purge` and `install.ps1 -Purge` also delete the settings, the cache, the downloaded FFmpeg, your sounds and the saved accounts, from DivannKokos's request (#12). Uninstalling without it still keeps your settings.

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

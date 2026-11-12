# Voice calls

larperCord joins real Discord voice channels and calls in DMs and groups, with end-to-end encryption. Everything voice-related runs on its own thread, created only when you join a call. Outside a call, the module uses no CPU and the app doesn't initialize audio, unless you open Settings → Voice, which reads the microphone for its level meter while it's open.

## Using it

Click a voice channel to join. The panel above your user shows the call, with mute, deafen and disconnect. You can also leave through "Leave call" when you right-click the voice channel. Whoever is talking gets a ring around their avatar. If someone moves you to another voice channel, larperCord follows you there.

Voice channels with a call show how long it has been going, like Discord (`16:42:14`). Settings → Appearance → **Voice channels** picks the format or turns it off, and you can write your own with `{H}`, `{mm}`, `{ss}` and the other fields. The app only wakes up for it while a timer is on screen, and only when the text changes: once a second with seconds, at most once a minute without.

In a DM or group DM, the phone button in the header starts a call; terminal themes show `[call]`. The header shows who's in the call and who's still being rung. An incoming call shows a card with **Accept** and **Decline** and rings until you answer, with a system notification and a taskbar flash, even with the app in the tray. In Do Not Disturb, or in a muted conversation, the card comes without the ringtone. Ringing stops when you answer on another device or the caller hangs up.

Right-click the microphone or headphone button, or the small arrow that shows on hover, to switch the device and its volume, mid-call too; during a call, right-clicking the voice panel shows both. `Ctrl+Shift+M` mutes and `Ctrl+Shift+D` deafens, and both keys can be changed in [Settings → Keybinds](page:shortcuts#changing-a-shortcut).

## The call screen

Clicking a voice channel opens the call in the chat area: one tile per person, with their picture and name (in a server, the ones they set for it), a green ring while they talk, their mic and sound when they're off, what they're playing, and a **LIVE** badge when they're streaming. Click a tile for that person's menu. Your mic, sound, mixer and leave buttons sit in a bar with the call time, where the message box was. Hover your own tile to see your mic level with the voice detection threshold mark; only then does that meter cost anything.

![The call screen in a server voice channel](shot:f-call)

`Esc`, **Back to chat**, switching tabs or opening a text channel take you back to the conversation, and clicking the call status on the voice panel opens the call screen again. DM and group calls get the same grid above the conversation. Terminal themes show it as text.

Alone in a call, your tile gets smaller, and below it the mascot naps next to "Just you here" and an **Invite people** button.

![Alone in a call](shot:f-call-sozinho)

The tiles follow the theme: its colors, corners and card style (glass in `vidro`, paper in `papel`, a clipping in `editorial`…), with a touch of each person's photo color, and the text switches color when it would be hard to read. Theme authors pick this with `call-style` and `call-tint` on the `messages` component; see [The call screen](page:themes#the-call-screen) in the theme guide. There's no camera or screen sharing.

## Volume per person

The **mixer** gives each person their own volume, plus two switches that are off by default and only touch that person:

- **Remove noise** runs the same noise suppression as your microphone (RNNoise) on their sound. It uses a little CPU while they talk, which is why it's per person, and it only exists while the switch is on.
- **Even out volume** raises a quiet voice and lowers a loud one toward everyone else's level, without lifting the background hiss in their pauses. It stays between a quarter and four times the original volume.

Your choices are saved and apply to every call.

![The call mixer, with Remove noise and Even out volume for each person](shot:f-voz)

Right-click someone in your call, wherever they appear (the voice channel, the member list, a message, a DM call), for **User Volume**, from 0 to 200% (100% is normal), and **Mute for Me**. It's the same setting as the mixer, so the two stay in sync. Muting keeps their volume, so unmuting brings back the same level.

## The voice panel

The voice panel shows your ping, the connection quality by color and when you're transmitting, and it warns you if the microphone doesn't open or if the server muted or deafened you. Other people's mute and deafen show in the call list.

Channels where you lack the permission to connect are shown with a padlock, and the app doesn't try.

## Settings → Voice

- **Microphone and output**: remembered by name, back to the default if they disappear, and you can switch in the middle of a call.
- **Volumes, a live microphone level** and **Test microphone**, which plays back what you say, with the filters on. Use headphones.
- **Voice activity**: an adjustable threshold on the meter, or **Automatic sensitivity**, which learns your background noise.
- **Push to talk**: a key or mouse button. Sending continues for a moment after you release, so the last word isn't cut. On Linux it only works while the window is focused. On Windows it also works while another window is focused, like a game, and that app still gets the key: the app reads it without a keyboard hook. That covers most keys (letters, `F13` to `F24`, the side mouse buttons…), and the page says when the one you picked only works with the window focused.
- **Filters**: a high-pass that removes rumble below 90 Hz and a noise gate. Each one can be turned off.
- **Noise suppression**: Off or RNNoise, on by default and switchable mid-call. It runs on your computer, delays your mic by 20 ms and costs about 2% to 3.5% of a core on a 2011 Core i5 while the mic is open, and less on newer processors. Off, muted or with the push-to-talk key released, it costs nothing.
- **Sounds**: one row per event (you join or leave, someone joins or leaves your call, mute, unmute, deafen, undeafen and the ringtone). Each can be Off, Classic, Soft, Crystal, Retro or your own WAV or Ogg Opus file (up to 2 MB and 5 s, 15 s for the ringtone), with a preview and a volume. **Call sounds** still turns all the short ones on or off.

![The voice settings page](shot:f-vozcfg)

## How it works

| Layer | What it uses |
|---|---|
| Signaling | Voice gateway v8 over WebSocket, with heartbeat (`seq_ack`) and RESUME when the connection drops |
| Connection | IP discovery (74-byte packet) and Select Protocol over UDP |
| Transport encryption | RTP with `aead_xchacha20_poly1305_rtpsize` |
| End-to-end encryption | DAVE over MLS, through libdave and MLSpp |
| Codec | Opus at 48 kHz stereo, 20 ms per packet. Lost packets become Opus packet-loss concealment |
| Audio | SDL3 mixes. Each person is one `SDL_AudioStream` on the same output device, and their volume is the stream's gain. The microphone is a stream read every 20 ms |
| Per person, when switched on | **Remove noise** passes their sound through RNNoise every 20 ms; turning it off fades back to the raw sound over a few frames. **Even out volume** measures speech only (silence and hiss don't count), goes down fast and up slowly, ramps within each frame and has a peak limiter |

A few details that took work to get right:

- The "speaking" opcode (op 5) goes out once when the session opens, and again on resume. It doesn't toggle on every sentence, since the server dropped the start of each one that way.
- The RTP clock keeps moving with real time while you're silent, so receivers don't drop your packets after a pause.
- Jitter margin applies only at the start of each talk spurt and inside a speaker's own pauses. Applying it whenever the queue emptied caused audible gaps.
- The RTP clock tells a speaker's pause from a late packet: the sequence number only moves with a packet, the clock always moves. A noise gate closing isn't a bad network.
- When a queue is about to run dry, Opus concealment fills in and fades to zero, so a stall never cuts mid-wave. Audio that doesn't continue from where it stopped starts from the last value played.
- `zig build voz-rede` runs real Opus through simulated bad networks and compares the playback logic, counting gaps and clicks. `LARPER_VOZ_FALA` picks a speech file and `LARPER_VOZ_WAV` saves the output to listen to.
- People already in a call can arrive before DAVE exists, so they're kept and added when it starts.

## Limits today

- On Linux, push-to-talk only works while the window is focused, because SDL has no portable global shortcut. On Windows it works from any window.
- Noise suppression targets steady noise. Typing and bangs may get through, and other voices stay.
- No screen sharing, camera or streaming.
- No automated test for a real call. QA covers the UI and the settings, with a fake audio device.

## Debugging

On Linux, start it from a terminal (quit it first if it's open in the tray) with:

```bash
LARPER_VOICE_DEBUG=1 larpercord
```

On Windows, or without a terminal, turn on Settings → Advanced → **Save debug log** before joining the call, then use **Open the log folder**. The file is `%LOCALAPPDATA%\larpercord\debug.log` on Windows and `~/.cache/larpercord/debug.log` on Linux.

Either way you get opcodes, close codes and DAVE events, and microphone level and frames sent. It never contains the token or any keys.

To test only the connection, `--voice-test` joins a channel for 25 seconds, **always muted**:

```bash
LARPER_TOKEN=... larpercord --voice-test GUILD_ID CHANNEL_ID
```

On Windows it only takes the token from `LARPER_TOKEN`, and its text has to go to a file, since there's no console:

```powershell
$env:LARPER_TOKEN = [Net.NetworkCredential]::new('', (Read-Host 'Token' -AsSecureString)).Password
Start-Process "$env:LOCALAPPDATA\Programs\larperCord\larpercord.exe" -ArgumentList '--voice-test','GUILD_ID','CHANNEL_ID' -NoNewWindow -Wait -RedirectStandardError voice.txt; Get-Content voice.txt
Remove-Item Env:LARPER_TOKEN
```

The protocol follows Discord's voice documentation and the [DAVE protocol documentation](https://daveprotocol.com).

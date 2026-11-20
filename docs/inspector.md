# Inspector

**English** · [Português](inspector.pt-BR.md)

larperCord's developer tools. Press **F12** (or **Ctrl+Shift+I**) to open it, or **Ctrl+Shift+E** to go straight to picking an element on screen. Both shortcuts can be changed in Settings → Keyboard shortcuts. It's also in the command palette and in Settings → Advanced.

It docks to the right or to the bottom, and the app fits in the rest of the window. It can also float over the app. Drag its edge to resize it.

Closed and never opened, it costs nothing: no memory and no extra work per frame. Everything it records stays in memory and goes away when you close the app. It never records your token: the `Authorization` header isn't kept, the `token` in IDENTIFY, RESUME and the voice gateway shows as asterisks, and anything shaped like a token is masked.

## Tabs

- **Elements**: the current frame as a tree. First come the theme's layout pieces (`row`, `column`, each component), and inside each piece what it drew: boxes, text, images and clickable areas. Hover a row and the element lights up on screen. Pick a piece and you see:
  - the file and line of the `.kdl` node that draws it, with all its properties;
  - the theme part it belongs to, with its states right now (`channel.item:hover:selected`), the name a theme's
    `parts` block uses ([Parts and states](../themes/README.md#parts-and-states));
  - each color with its theme name (`accent`, `muted`, `sidebar 50%`…) and its hex;
  - the font, size and contrast of a text against the background under it (WCAG AA/AAA);
  - the Dear ImGui id, label and status of a clickable item, and the QA mark name in builds with the QA robot;
  - how many microseconds that component took to draw.

  The search box finds elements by text, component, color or QA mark.
- **Console**: the app's log lines (the same ones as the debug log, without turning it on), filtered by level and text, with warnings and errors highlighted. At the bottom is a command line; `help` lists the commands.
- **Network**: every HTTP request: the Discord API, images and videos, plugins. Each row has its status, time, size and how long it waited on the rate limit. Pick one to see the headers (the rate-limit ones get their own section), what was sent, the response as a JSON tree, and how long each phase took (DNS, connect, TLS, first byte). **Copy as curl** puts `$LARPER_TOKEN` where the token would go.
- **Gateway**: every frame of Discord's WebSocket and of the voice gateway, with its direction, op name (the event name for Dispatch), sequence and size. Heartbeats are hidden by default. Pick one to open its content as a tree. With nothing picked, it shows a count of each event type, the bytes in and out and the heartbeat latency.
- **Events**: what the interface asked the app (actions), what the app asked the network (commands) and what the network delivered (events), in the order they happened.
- **Performance**: the CPU time of the last 300 frames as a graph, how many came out the same and weren't drawn, each component's cost, what goes to the GPU (draw lists, commands, vertices), memory and the process CPU.
- **State**: the session, the open conversation, the theme's colors (click to copy the hex) and the window (size, scale, renderer).

## Commands

The Console command line and `larpercord ctl inspect …` take the same commands:

```
help                     the list
find <text>              elements with that text (or QA mark, component, color)
tree [component]         the frame's tree, with what each piece drew
el <selector>            everything about an element, as JSON
click <selector>         clicks its center (rclick, dclick and hover too)
type <text>              types into the focused field
key <key>                presses a key: enter, esc, tab, ctrl+k, ctrl+shift+e…
net [filter] [n]         the latest HTTP requests
gw [filter] [n]          the latest gateway frames (op 1 and 11 only with "hb")
log [filter] [n]         the latest log lines
ev [filter] [n]          the latest internal events
perf                     performance numbers
state                    the session, the open conversation and the theme
theme [name|reload]      switches or reloads the theme
open <channel id>        opens a conversation
shot <file.png>          screenshot of the window
record on|off            record network, log and events even with the Inspector closed
clear [net|gw|log|ev]    clears the lists
inspector open|close|<tab>
```

Selectors: `qa:name` (a QA mark, in builds with the robot), `comp:name` (a layout piece), `id:0x1a2b` (a Dear ImGui id), `@x,y` (whatever is at that point), `#n` (the n-th element of the frame), or plain text (the element whose text, or the text inside it, matches).

Clicking and typing go through Dear ImGui's input queue, one step per frame, the same way the QA robot does it. **Through `ctl`**, clicking and typing only work in demo mode or after you turn on **Let ctl click and type** in the Console. Any program running as your user can talk to `ctl`, so acting on your real account is something you turn on knowingly, and it stays on only until you close the app.

## Starting with it open

`larpercord --inspect` (or `LARPER_INSPECT=1`) opens with the Inspector open and recording from the start, so the requests made while the app opens show up too.

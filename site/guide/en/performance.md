# Performance

## The numbers

| | RAM (PSS) | Idle CPU | Binary |
|---|---|---|---|
| Vesktop (Electron) | 1,279 MB | 12–47% ¹ | 287 MB |
| Discord Phoenix (Rust) ² | ~290 MB | 0.1% | not released |
| **larperCord**, real account ³ | **~130 MB** | **0–0.4%** ⁴ | **~14 MB** |

¹ Average since launch, measured with `ps`. Arch Linux, Hyprland, GTX 1050 Ti, a 1280×800 window, `ReleaseFast` build.

² Not measured by us and not a side-by-side test. It's an early Windows 11 build, from a Task Manager screenshot [posted by Discord's CTO](https://x.com/svishnevskiy/status/2118081920194203799) ([coverage](https://www.windowslatest.com/2026/11/05/discord-is-killing-its-electron-app-that-can-eat-4gb-of-ram-on-windows-11-and-the-rust-rebuild-uses-just-290mb/)). The app isn't out yet, and that screenshot says little about normal use.

³ 125–140 MB in one account's normal use on the same PC, with an i5-2400S, and about 70 MB right after opening. Yours depends on your servers, members and images. Settings → Performance shows where it goes.

⁴ Measured across all 11 themes with demo data, a real GPU, a real window on a hidden Hyprland workspace and GIF autoplay off. A window you're looking at can measure differently.

Read these with the right caveats:

- **A real account uses more** than demo data. More servers, more members, more images.
- **Idle means nothing is moving.** An animated GIF on screen costs about 2.5% CPU. The demo's first channel has one, so the measurement turns autoplay off.
- **A good part of PSS isn't the app.** It's the NVIDIA driver and system libraries such as libcurl and OpenSSL. In one measurement across the themes, anonymous memory was about 25 MB.
- **The published Linux file carries SDL3, libcurl and OpenSSL inside**, so it runs on more distros, built with only the parts the app uses. Built against the system's copies it's about 8 MB. These RAM figures come from that kind of build; side by side in demo, the published file used about 2 MB more.
- **The mascot only moves while the window is focused.** Its life of its own costs about half a percent of one core while it's awake, and nothing once it falls asleep after a few idle minutes. The window measured here had no focus, so these numbers don't include it. See [The mascot](page:mascot#what-it-costs).
- The Vesktop figures come from a single earlier run on the same machine.

## Measure it yourself

```bash
tools/membench.sh 60
```

For each theme, it opens the app in demo mode with clean settings and GIF autoplay off, waits, measures idle CPU over 5 seconds, reads PSS from `/proc/<pid>/smaps_rollup`, and fails if any theme goes over the budget in MB. Because of that variation, `terminal` sometimes fails at 60.

`tools/membench.sh` is a Linux script, since it reads `/proc`. On Windows, use Settings → Performance: there the RAM figure is the process's private memory (Task Manager's "Commit size"), not PSS, so it doesn't compare directly with the numbers above.

The Performance page in settings shows live numbers, including where the memory goes on your account, and `--stats` prints the opening timeline and the cost of each frame. If a render backend misbehaves with your graphics driver, the same page picks another one under **Renderer**.

## Ten decisions

1. **It sleeps when nothing happens.** The loop waits in `SDL_WaitEvent`. Network, file changes (inotify on Linux, folder notifications on Windows) and the clock wake the app through events. No animation, no redraw. A frame that comes out the same as the last one never reaches the GPU, and a mouse just moving asks for fewer frames.
2. **No browser.** Everything is drawn with Dear ImGui's `ImDrawList` on SDL_Renderer.
3. **Fonts are mapped, not copied.** Each font file is one memory map (`mmap` on Linux, `MapViewOfFile` on Windows) used by every weight and family, so only the pages read stay in RAM. Loading 4 weights of Inter plus emoji the naive way cost about 90 MB.
4. **Only the video driver it needs.** On Linux machines with only an NVIDIA GPU, glvnd also loaded Mesa and LLVM (about 23 MB) for nothing. The app detects that and avoids it.
5. **Markdown is parsed once**, when the message arrives. The UI only lays out spans, with a height cache per width.
6. **A virtualized list.** Binary search for the first visible item, then draw only the screen.
7. **Memory has ceilings.** 1,500 messages per channel and, by default, 2,000 in total, after which the conversation seen longest ago is unloaded. Images get 32 MB by default, and any single download stops at 32 MB. Settings → Performance moves those limits: 500 to 5,000 messages, 16 to 128 MB of images and 4 to 32 MB for each GIF. After a minute in the tray or minimized, images leave memory too, except small ones that were on screen.
8. **On Linux, freed memory goes back to the system.** fontconfig gets freed after fonts are resolved (`FcFini` and `malloc_trim`), and large image buffers get their own memory map, so freeing them returns the memory instead of leaving it in glibc's per-thread arenas. Before 0.6.5, after 4.5 hours on the developer's account, about 190 MB sat there for nothing. Windows has no fontconfig: fonts are opened straight from `C:\Windows\Fonts`.
9. **No blinking cursor.** It would keep the CPU awake for nothing.
10. **Things start when you ask.** The voice thread on the first call and FFmpeg on the first video. Off-screen video is released after 30 seconds, and with no plugin on there's no plugin thread, no Lua state and no extra work per message, key or frame.

## The budget in CI

The test suite covers the pure parts, and a separate job builds the whole app and runs the full QA off-screen. See [Contributing](page:contributing).

# @119-svg/dsh-restart

One-click **full restart** for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) Desktop:
press the button and the app closes and reopens itself — **exactly what quitting from the tray and
double-clicking the icon again does**, except it comes back on its own in about 8 seconds.

> 中文说明：[README.md](README.md)

## Why this exists

The official shell exposes **no restart seam to plugins** (the whole `app.asar` has zero hits for
`desktopRuntime` / `requestRestart`; the only real `app.relaunch()` calls live inside the Electron main
process, and the tray's "Restart App and Host" item is dev-build only). So a plugin has to do the
quit-and-relaunch dance itself — and that dance hits several platform traps this package already solves.

## Install

> ⚠️ **Fully quit DSH Desktop (tray included) before installing** — a running host locks the native
> packages in the profile and pnpm fails with `ERR_PNPM_EPERM`.

```sh
dsh plugin --profile desktop add @119-svg/dsh-restart
# or from a local checkout
dsh plugin --profile desktop add /absolute/path/to/dsh-restart
```

After booting, a **⏻** button appears at the bottom of the sidebar (next to Settings).

## Usage

- Click **⏻**, confirm, and the window is back in ~8 s.
- Rehearse without killing anything: `POST /api/dsh-restart/restartApp` with `{"dryRun":true}`
  (the script runs with `-DryRun`).
- Without the plugin at all: double-click `scripts/restart-dsh.cmd`
  (`DSH_RESTART_DRYRUN=1` rehearses).

## How it works

`scripts/restart-dsh.ps1` is one file with three roles:

| Role | Invocation | Job |
|---|---|---|
| phase 1 | no switch | write a `~/.dsh/dsh-restart.pending` marker, launch the next two **through WMI**, exit |
| worker | `-Detached` | wait 1 s, try a graceful window close, `taskkill /T /F` the app tree, wait for zero processes, relaunch, verify the window returns |
| guard | `-Guard` (30 s delay) | safety net: marker still there and no app process ⇒ the worker died mid-flight, relaunch |

**The worker must be created through WMI** (`Win32_Process.Create`) so its parent is `WmiPrvSE.exe`,
**outside DSH's managed subprocess containment**. Otherwise the app dies and never comes back.

### Timing budget (measured)

~1.3 s (response grace + graceful attempt) + ~1.0 s taskkill + 0.5 s lock release + ~5 s app boot
= **about 8 seconds**.

## Four traps worth knowing

1. Node's native `child_process.spawn` **throws EPERM synchronously** inside the host sandbox — use DSH's
   managed `ctx.get('subprocess')` service instead.
2. `subprocess.spawn` requires **`graceMs`** (positive finite, ≤ 2^31-1); omitting it throws
   `subprocess graceMs must be a positive finite number…`.
3. DSH subprocess children live in a **managed containment** that is torn down when the host exits —
   descendants die with it, so the process doing the kill can't survive to do the relaunch. Create it
   through WMI (or Task Scheduler) to escape.
4. `CloseMainWindow()` on the official shell only **hides the window to the tray**; never wait out a fixed
   graceful period — stop as soon as the window disappears and let `taskkill` finish the job.

Two more that apply to any DSH plugin: keep `.cmd` files **ASCII + CRLF** (cmd.exe parses them with the OEM
code page), and remember that cordis's `fiber.restart()` **does not pick up host-side code changes**.

## Troubleshooting

Everything is appended to `~/.dsh/dsh-restart.log`, one line per step. Rehearse safely with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\restart-dsh.ps1 -DryRun
```

## Limitations

- **Windows only** for now (WMI + `taskkill`); macOS would need `launchctl`/`open`.
- Assumes the official DSH Desktop install path; edit `$exe` in the script otherwise.
- A full restart interrupts the running conversation and tasks — inherent to what "restart" means.

## License

MIT © 2026 119-svg

# OpenMacBattery

**Open source per-app battery monitor for macOS.** Find out which app is draining your MacBook's battery — *looking back, not just right now*.

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%203.0-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-orange.svg)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-success.svg)](#requirements)
[![Languages: 9](https://img.shields.io/badge/i18n-9%20languages-green.svg)](Sources/OpenMacBatteryApp/Resources)

> Activity Monitor only knows the present moment. macOS's built-in Battery panel only shows the last 12 hours.
> **OpenMacBattery remembers the past 30 days, per app.**

![OpenMacBattery — main window with live wattage, hero card, app sidebar](docs/screenshot.png)

## What it does

Asks the question: **"My battery dropped 40% between 02:00 and 08:00 — which app was responsible?"**

- Samples every running process every 60 seconds via `proc_pid_rusage` (no sudo needed).
- Stores per-app energy/CPU/wakeup deltas in a local SQLite database.
- Shows live system wattage, per-app share, battery life estimate, sleep periods.
- Right-click any app → quit / force-quit / show in Activity Monitor.
- Compares current period vs previous (anomaly detection).
- Available in 9 languages.

## About this project

I'm a MacBook user — not a professional software developer. I built OpenMacBattery because I wanted to answer a simple question macOS refuses to answer: *"My battery dropped 40% overnight — which app was responsible?"* Activity Monitor only knows the present moment, the built-in Battery panel only shows the last 12 hours, and the polished paid alternatives didn't quite fit what I needed.

So I built it for myself, **substantially with the help of AI coding assistants** — I want to be upfront about that. Every product decision, UX choice, and honest caveat in this README came from me; the AI did the heavy lifting on Swift, SwiftUI, IOKit, and SQLite. The result is real, working software that I run on my own MacBook every day.

I'm releasing it because once it worked for me, there was no reason to keep it private. If you're a Mac user who wants to know what's draining your battery — please use it. If you're a Swift / macOS developer who spots code that could be written better, or a native speaker who can improve one of the non-English translations, **please open an issue or pull request**. I'd much rather hear *"here's a better way to do X"* than discover it later in a crash report. That's the whole point of putting this out in public.

— Murat Dugan

## Current source vs v0.1

The original `v0.1` tag is the initial prototype. The current source has since become a more accurate, safer, and lower-overhead release candidate:

| Area | Current source |
| --- | --- |
| Energy | Uses macOS's native `ri_energy_nj` process counter; processor energy is shown in joules and is kept separate from total battery drain. |
| Attribution | Fixes PID enumeration, PID-reuse identity (including microseconds), current-user filtering, permission gaps, timestamp gaps, and native-energy fallbacks. |
| Battery reporting | Adds battery-only filtering throughout the UI, battery/AC duration scaling, charge-limit and adapter details, remaining-time correction, brightness detection, and clearly labeled display-power estimates. |
| Data integrity | Failed SQLite writes surface errors, sampler baselines commit only after successful writes, migrations are retry-safe, and hourly aggregation is gap-aware and idempotent. |
| Retention | Keeps 30 days of raw samples and 180 days of hourly aggregates, with progress tracking for aggregation. |
| GUI performance | Database work runs off the main actor, inactive polling stops, live and history state are separated, charts use stable IDs, detail content is lazy, live values refresh every 60 seconds, and history refreshes every 5 minutes. |
| UI and localization | Adds per-app processor-energy values in joules, comparison/anomaly explanations, ⌘, Settings, and updated translations in all 9 locales. |
| CLI and packaging | Adds input validation, safe JSON escaping, clearer diagnostics, a self-contained signed `.app`, and a drag-to-install DMG build. |

The release DMG is built directly from the current source tree; it is not the old `v0.1` prototype.

## Privacy

- **Zero network code.** No telemetry, no analytics, no cloud sync. Verify yourself: `grep -r "URLSession\|http\|socket" Sources/`.
- Database lives at `~/Library/Application Support/OpenMacBattery/data.db` with 600 permissions (only you can read).
- Logs at `~/Library/Logs/openmacbattery.log` also 600.

## Requirements

- macOS 14+ (Sonoma / Sequoia / later)
- Apple Silicon (M-series) — uses macOS's native `ri_energy_nj` process-energy counter
- For building from source: Xcode Command Line Tools (`xcode-select --install`)

## Download

**[⬇ Latest release (DMG)](https://github.com/Super-Matter/openmacbattery/releases/latest)**

1. Download `OpenMacBattery-x.y.dmg`
2. Open it, drag **OpenMacBattery** onto **Applications**
3. Launch from Spotlight or Launchpad
4. On first launch macOS may say *"unidentified developer"* — right-click the app → **Open** → **Open**. macOS remembers this.
5. Click **Enable background tracking** in the welcome sheet

Done. Data starts accumulating within 1–2 minutes.

## Build from source

If you'd rather compile yourself:

```bash
git clone https://github.com/Super-Matter/openmacbattery.git
cd openmacbattery
./scripts/make-app.sh --install   # builds and installs to /Applications
# or
./scripts/make-dmg.sh              # produces build/OpenMacBattery-x.y.dmg
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## How it works

Three pieces, one binary:

1. **Sampler daemon** (`openmacbattery daemon run`) — runs in background via user LaunchAgent. Every 60 seconds, calls `proc_pid_rusage(RUSAGE_INFO_V6)` for every accessible process and writes deltas to SQLite. Self-throttles to 120s if a sample tick exceeds 500 ms (with hysteresis to recover when fast).
2. **GUI** (SwiftUI) — reads the same SQLite database read-only. Live wattage from `AppleSmartBattery` IORegistry entry. App icons from `NSWorkspace`.
3. **CLI query commands** — `openmacbattery top`, `app`, `timeline`, `export`, `stats`, `prune`, `calibrate`.

The SQLite database uses WAL mode + `auto_vacuum=INCREMENTAL`. Hourly aggregates are rolled up automatically; raw samples older than 30 days and aggregates older than 180 days are pruned daily at ~03:00.

## Battery impact

OpenMacBattery is deliberately quiet when idle:

- The background sampler runs at low priority every 60 seconds, samples only the current user's processes, batches SQLite writes in a transaction, and self-throttles to 120 seconds if a sample takes too long.
- The GUI refreshes live wattage and battery state every 60 seconds; the heavier history/chart reload runs every 5 minutes.
- GUI polling stops while the app is inactive, and live state is separated from history state so live changes do not invalidate history charts.
- Chart points keep stable identities and detail content is lazy, avoiding needless chart teardown and off-screen work.
- Brightness and display power remain estimates because macOS does not expose a public watt meter.

A representative idle measurement on an M1 MacBook Air using `powermetrics` showed the GUI at `0.33 CPU ms/s` with `0.01` Energy Impact and the daemon at `0.01 CPU ms/s` with `0.00` Energy Impact. A pre-optimization sample showed `211.20 CPU ms/s` and `32.35` Energy Impact for the GUI. These are device- and workload-dependent samples, not guarantees.

## Honest caveats

- **`ri_energy_nj` is process energy, not battery energy.** It is a native macOS counter in nanojoules and represents a processor/task estimate; it does not measure the complete battery drain or display power.
- **System daemons may be invisible.** `proc_pid_rusage` returns `EPERM` for processes you don't own (kernel_task, WindowServer, root daemons). On a single-user Mac, the gap is small.
- **Sub-60 s processes are missed** — if a process lives less than one sample interval, it never appears.
- **Self-consumption is not measured automatically yet.** The sampler is designed to stay below the 20 J/hour target; measure it separately with `powermetrics` before making a device-specific claim.

## CLI usage

```bash
# Top consumers in a window
openmacbattery top --since 24h
openmacbattery top --since 7d --on-battery

# Per-app timeline
openmacbattery app Slack --since 7d
openmacbattery timeline --top 5 --since 24h

# Export
openmacbattery export --format csv --since 30d > out.csv
openmacbattery export --format json --app Slack

# Maintenance
openmacbattery stats
openmacbattery prune
openmacbattery daemon status
```

## Languages

UI is localized in **9 languages**. Native-speaker reviews welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

| Code | Language |
| ------ | ---------- |
| en | English |
| tr | Türkçe |
| zh-Hans | 简体中文 |
| es | Español |
| de | Deutsch |
| fr | Français |
| ja | 日本語 |
| pt-BR | Português (Brasil) |
| ru | Русский |

The app picks up your system language automatically. Switch manually via **Apple menu → Language**.

## Uninstall

```bash
# Stop and remove the LaunchAgent
openmacbattery daemon uninstall

# Remove the .app
rm -rf /Applications/OpenMacBattery.app

# Remove the database (loses your history!)
rm -rf "$HOME/Library/Application Support/OpenMacBattery"
rm -f "$HOME/Library/Logs/openmacbattery.log" \
      "$HOME/Library/Logs/openmacbattery.error.log"
```

## Troubleshooting

| Problem | Fix |
| --------- | ----- |
| **"App can't be opened, unidentified developer"** on first launch | Right-click the `.app` → **Open** → **Open**. macOS remembers this for next time. Standard for ad-hoc signed apps. |
| **Sidebar empty after install** | Daemon needs ≥ 2 minutes to compute the first deltas. Check with `openmacbattery daemon status`. |
| **No data accumulating** | Open **Settings** in the app and confirm *Background tracking* is **On**. If off, toggle it. |
| **GUI looks stale** | Click the refresh button in the toolbar (top right) or press ⌘R. Live wattage updates every 60 s; history updates every 5 minutes. |
| **Energy values look strange** | Energy uses macOS's native `ri_energy_nj` counter on supported Apple Silicon Macs. Restart sampling after an update and allow at least two samples for new data. |
| **Can't quit a system service from the right-click menu** | By design — system services (root-owned, sandboxed Apple daemons) can't be terminated by user-level processes. Use Activity Monitor with admin privileges if you really need to. |
| **Reset everything** | Remove the database at `~/Library/Application Support/OpenMacBattery/data.db` and restart the daemon. |

Logs:

- `~/Library/Logs/openmacbattery.log` — sampler heartbeat
- `~/Library/Logs/openmacbattery.error.log` — errors and lifecycle events

When opening an issue, attach the **error log** (not the main log) and your macOS version (`sw_vers`).

## Disclaimer

OpenMacBattery is provided **"as is", with no warranty of any kind**, express or implied. The author is not liable for any damage, data loss, or system issues arising from use of this software. Use at your own risk.

A few specific things to know before installing:

- **The .app is ad-hoc signed**, not notarized by Apple. On first launch macOS will warn you ("unidentified developer"); right-click → Open → Open to bypass. This is normal for indie open-source apps.
- The installer adds a **user-level LaunchAgent** at `~/Library/LaunchAgents/com.openmacbattery.plist` so the sampler runs in the background. No `sudo` is required and no system-level changes are made — you can remove it any time with `openmacbattery daemon uninstall`.
- The **force-quit** feature uses `NSRunningApplication.forceTerminate()`. Like Activity Monitor's Force Quit, it can cause unsaved-changes loss in target apps. A confirmation dialog is shown for that reason.
- **Energy values are estimates**, not authoritative battery measurements. Apple's `ri_energy_nj` counter reports processor/task energy in nanojoules; system daemons, display power, and other shared costs are separate. Use the percentages and rankings, not absolute joule numbers, for decisions.
- The database (`~/Library/Application Support/OpenMacBattery/data.db`) contains a record of which apps you ran and when — **don't share it publicly** without redacting. Logs (`~/Library/Logs/openmacbattery.log`) are similar.
- This is a **personal project**, not a commercial product. Issues and pull requests are welcome but there's no SLA or guaranteed response time.

If something goes wrong, see [Troubleshooting](#troubleshooting) below or open an issue with your `~/Library/Logs/openmacbattery.error.log`.

## License

[AGPL-3.0](LICENSE) — open source for personal, educational, and free-software use. Commercial vendors who modify and redistribute (or run as a SaaS service) must release their changes under the same license. This is intentional — see the [project philosophy](#why-agpl-30).

### Why AGPL-3.0?

OpenMacBattery exists because Apple's tools cost ~$0 to write and macOS has plenty of paid utilities for similar work. The license is designed to keep this tool **freely available to humans** while making it **uneconomic for closed-source vendors** to adopt and resell. If you build commercial software on top, the AGPL forces you to open your modifications — most vendors then choose not to use it. This is by design.

## Acknowledgments

Inspired by [Stats](https://github.com/exelban/stats), [htop](https://htop.dev/), and Apple's `darwintests/proc_info`. Built with Swift, SwiftUI, and Charts framework.

## Status

**v0.2.0 — early preview.** The data layer, daemon, GUI, and i18n are functional. Needs more testing on diverse Mac configurations and native-speaker review of translations.

# Focus Guard

A macOS app that makes you say what you are about to do before it lets you use your Mac.

Most focus tools are opt-in: you remember to start them, and you can stop them the moment
they become inconvenient. Focus Guard inverts that. There is no idle state — you are either
in a session you declared, or you are at the gate. Unlocking, waking, or coming back from
ten minutes away puts the gate back up.

> Personal project, built for my own machine. It deliberately makes your Mac harder to use.
> Read [Holding the line](#holding-the-line) before installing it anywhere you care about.

## The gate

A full-screen terminal, above everything, on every display. You type what you're doing and
press return:

```
> write the physics lab report
> /add safari notes
> /time 50
> /start
```

Bare text is your goal, so the fastest path is just to type it. Everything else is a command:

| Command | What it does |
| --- | --- |
| `<goal>` | set the goal by typing it |
| `/add <apps>` | add apps by name: `/add xcode terminal` |
| `/apps <apps>` | replace the app list |
| `/time <minutes>` | set how long |
| `/sites <domains>` | limit the browser; `/sites` alone allows everything not blocklisted |
| `/pin <url>` | allow one exact page, even on a blocked domain |
| `/quick <goal>` | five-minute open session, any app |
| `/save <name>` | save the current apps, sites and time as a preset |
| `/<preset> [goal]` | run a preset by name: `/deepwork ship the reducer` |
| `/status` | today's numbers |
| `/override` | emergency override |
| `/sleep` | you're done: sleep the Mac |

Presets become their own commands, and the gate learns them: after you run the same shape of
session a few times it offers to save it for you. Tab completes.

## Two kinds of session

**Full** — a goal, an explicit list of apps, optional site rules, and a deadline. Everything
outside the list is closed off. The deadline is wall-clock, so sleeping the Mac doesn't buy
you extra time.

**Open** — five minutes, any app, no goal needed. For the times you genuinely just need to
check something. The blocklist still applies. You can extend it once, and the extension is
measured from the original end, so answering the panel late doesn't earn you more. If you
keep starting open sessions back to back, an optional countdown makes each one slower to
begin than the last.

An open session can grow into a full one without losing the clock you've already run.

## Enforcement

Leaving the session raises a violation and an intervention panel — over whatever you're
actually looking at, on the current Space, full-screen apps included. Three ways out: go
back, add the app or site **with a written reason**, or end the session and face the review.

Browser tabs count. Focus Guard polls the frontmost browser's address and checks it against
the session's rules and your blocklist. The interesting part is what happens when it *can't*
read the address: it fails closed. A browser whose URL is unreadable for several polls in a
row is a violation, not a free pass. Firefox has no AppleScript URL support so it's read
through the accessibility tree, which is flakier, so it gets a higher threshold before it
counts against you.

Blocked domains can never be added mid-session, and an unreadable page can't be added either
— the fix there is the permission, not the allowlist.

## Holding the line

The gate is only worth something if it can't be waved away. Most of the design weight is here:

- **The review can't be skipped.** When time runs out, the review arrives on the shield.
  There's no dismiss.
- **Loosening waits 24 hours.** Any settings change that gives you more freedom is stored as
  pending and applies tomorrow. Changes that tighten apply at once — including new defaults
  picked up on upgrade.
- **The override is deliberately slow.** A written reason, an exact phrase typed out in full
  (pasting is refused), and a countdown. It suspends enforcement but not your commitment: the
  session keeps running underneath. Every use goes to the top of your daily review.
- **One instance only**, held with `flock(2)`. The kernel drops the lock if the process dies,
  so a crashed copy can never lock out the next one.
- **Quitting doesn't help.** A `KeepAlive` LaunchAgent brings it back in about nine seconds
  and resumes the session.
- **Command-Q isn't a way out**, and neither is restarting: the app knows how long the machine
  has been up.
- **Tampering is visible, not prevented.** Crashes, kills, hangs caught by a watchdog,
  heartbeat gaps while the app wasn't running, version and code-signature changes, and lost
  permissions all land in the log and show up in the daily review.

The escape hatches that do exist are the ones you need when it genuinely breaks. Three runs in
a row that die within two minutes of starting counts as a crash loop, and the app drops into
safe mode instead of locking you out of your own machine. Holding Control-Option-Command while
it launches, within ten minutes of a boot, skips the gate for that whole launch — it needs the
restart, so it can't be used as a casual way around the gate. Losing Accessibility or
Automation makes noise but never stops the gate from working. And debug builds sit below the
menu bar and auto-dismiss after ninety seconds, so development doesn't trap you.

## The daily review

Folded out of the event log, in this order: what got past the rules, then the numbers, then
the sessions. Overrides and safe-mode entries first, then coverage — what share of the time
you were actually at the Mac was inside a session — then every session with its goal,
violations, additions, apps used and domains visited. Written to
`~/Library/Application Support/FocusGuard/exports/YYYY-MM-DD.json` as well, so you can do your
own counting. Nothing leaves the machine; there is no network code in this app.

## Architecture

```
Sources/FocusGuardCore/   pure logic, no AppKit, no I/O, no clock
Sources/FocusGuardApp/    AppKit + SwiftUI: turns the OS into events, runs effects
Tests/FocusGuardCoreTests/
```

The whole state machine is one function:

```swift
(AppState, AppEvent) -> (AppState, [Effect])
```

The app layer translates notifications, timers and clicks into `AppEvent`s and executes the
`Effect`s it gets back. Time and UUIDs are injected, so the core is fully deterministic under
test — every rule above is a unit test with a fixed clock rather than a thing you have to sit
and wait for. `FocusGuardCore` builds with SwiftPM alone; the Xcode project compiles both
directories into the app.

State is an append-only JSONL event log plus a small set of state files, not `UserDefaults`.

## Build

Requires macOS 14+ and Xcode.

```sh
./scripts/build-xcode-app.sh      # -> dist/FocusGuard.app
```

The build is signed with a real Apple Development identity on purpose. macOS keys
Accessibility and Automation grants to the code signature, so an ad-hoc build — a new hash
every time — makes you re-grant permissions on every rebuild. Override the team with
`FOCUSGUARD_TEAM_ID=...`, or force the unsigned path with `FOCUSGUARD_ADHOC=1`.

Copy the app to `/Applications` and launch it from there. Accessibility grants are bound to
the bundle path, so running a copy from `dist/` means granting permissions twice.

## Development

```sh
swift test                                                    # the core
FOCUSGUARD_SELFCHECK=1 FOCUSGUARD_DATA_DIR=/tmp/fg-check \
  ./path/to/debug/FocusGuard                                  # drives the real app, exits non-zero on failure
```

The self-check runs every flow against a controllable clock and a scratch data directory —
real windows, real persistence, real event log. It's worth more than the unit tests for
anything involving AppKit, and it is blind to anything about pixels or discoverability.

To look at the gate without granting anything, render it offscreen:

```sh
FOCUSGUARD_RENDER_GATE=/tmp/gate.png FOCUSGUARD_RENDER_DEMO=1 ./path/to/debug/FocusGuard
```

`FOCUSGUARD_SIMULATE_CRASH`, `_HANG`, `_QUIT` and `_RESTART_ESCAPE` exercise the safety net.

## Where things live

```
~/Library/Application Support/FocusGuard/
  events/YYYY-MM.jsonl     append-only event log
  state/                   active session, settings, presets, pending changes, launch records
  exports/YYYY-MM-DD.json  daily review
```

Set `FOCUSGUARD_DATA_DIR` to point all of it somewhere else.

## Permissions

- **Accessibility** — to see which app is frontmost and to read Firefox's address bar.
- **Automation** — to ask Safari and Chrome for the active tab's URL.

Both are asked for in the app. Neither is optional if you want the browser rules to mean
anything, and losing either is reported loudly rather than silently ignored.

## Status

Working and in daily use on my own machine. Not notarized, not distributed, no installer.

One caveat worth stating plainly: `/exit` is still compiled in behind
`FocusGuardConfig.testingExitCommandEnabled`. It quits Focus Guard and unregisters the login
agent, bypassing every rule above. It exists for testing the UI. Every use is logged and
counted in the daily review, but it is a hole — turn it off before relying on the gate.

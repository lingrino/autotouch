# Autotouch — maintainer guide

Autotouch is a personal macOS agent for exactly two trackpad gestures, built for an audience
of one. Optimize for, in order: **reliability** (it should
just work, always), **resource use** (idle unless fingers are on a trackpad; a few MB),
**zero dependencies**. There is no UI and no settings, and there should not be: change
code, not configuration.

This is the agent guide for any coding agent. Claude Code reads it natively when there is
no CLAUDE.md, so don't add one.

## Coming back after a break

1. Read this file and `git log --oneline -20`. Check "Open decisions".
2. `sw_vers; swift --version`: after a macOS update, `make status` first. Autotouch relies on
   a private framework (see "What OS updates can break").
3. `make install`, then `make check` (zero-warning build, unit tests, live smoke test).
4. Branch → work → `make check` → `make install` → swipe for real → commit.

## What it does (and deliberately doesn't)

- **Three-finger swipe left** → open Chrome (`com.google.Chrome`): launches it, or brings
  it forward and unhides it, like clicking it in the Dock.
- **Three-finger swipe right** → hide the app owning the window under the pointer (⌘H for
  that app); over no window (the desktop), the frontmost app. macOS ignores an outside hide
  request for the last app with windows on screen (nothing to activate instead), so for
  that one Autotouch activates Finder (the desktop) first, as ⌘H would; a check 0.25 s later
  retries the same way if the app still shows (its other windows on another Space). When
  Finder itself is the last app there is nothing to hand activation to and it stays (⌘H
  works, but sending keys needs Accessibility). `hide()` returns false even when it works:
  outcomes are checked, not return values.
- Built-in trackpad and Magic Trackpads (they come and go: Bluetooth). Not the Magic Mouse.
- Nothing while the screen is locked or another user's session is on screen.
- **Not** in scope: any other gesture, other devices, configurability, a menu bar item.

## User decisions

- 2026-11-18 kickoff: only these two gestures; no settings/config; never visible in the
  Dock or menu bar; always on; reliability first, then performance, then zero deps. Set up
  like the user's other Mac apps (fred: SwiftPM, Makefile, Developer ID signing, CI
  releases to the Homebrew tap; peep: the LaunchAgent pattern).
- 2026-11-19: "needs just slightly too long of a swipe": travel 12 → 9 mm (per finger
  5 → 4 mm), then "swiping feels great now". Hiding the last app on screen didn't work:
  fixed by activating Finder first. Finder itself as the last app on screen stays: the
  user chose to leave it ("Leave Finder as is"). Options that were weighed: hand activation
  to a windowless running app (can't be told apart: every app owns offscreen layer-0
  windows, and one with windows on another Space would switch Spaces); a short-lived
  invisible Autotouch helper taking focus (blank menu bar until the next click); Accessibility
  + ⌘H (no grants, by design). Don't revisit unless the user asks.
- 2026-11-19: swipes sometimes failed "on the first try" because the palm/wrist touches
  the far right of the large trackpad. Recorded it: the resting palm sits in the
  bottom-right corner, still, labelled as not a finger by the driver. Contacts labelled
  6+ are ignored now. Replaying the recording: palm-resting swipes that fire went from
  7 to 28, normal swipes unchanged, four-finger swipes still ignored. The owner confirmed
  "works on first try". The raw recording isn't kept in the repo (no test data).
- Minimum macOS 27.2 (like fred); Apple Silicon only (`depends_on arch: :arm64`).

## How it works

```
 trackpad ──► MultitouchSupport (private framework, its own thread, ~125 Hz while touched)
                 │ onFrame (Trackpads.swift): count fingers down, read 3 positions → mm
                 ▼
              SwipeRecognizer (AutotouchCore, pure, unit-tested) per trackpad, under a lock
                 │ .left / .right, once per touch
                 ▼ main queue
              Actions (Actions.swift): NSWorkspace.openApplication / NSRunningApplication.hide
```

- **One binary, two roles** (`main.swift`). Launched by launchd as the job
  `com.lingrino.autotouch.agent` (`XPC_SERVICE_NAME`), or with `--agent`, it is the agent.
  Launched any other way (opening Autotouch.app, `Autotouch --register`) it writes
  `~/Library/LaunchAgents/com.lingrino.autotouch.agent.plist` if needed, (re)loads it with
  `launchctl bootstrap`, and exits. Only the copy in /Applications registers itself.
- **The agent is not an NSApplication**: a main CFRunLoop serving the touch frames
  (their own thread), IOKit and NSWorkspace notifications, FSEvents and signals.
  `openApplication` (including bringing Chrome forward from the background), `hide()`, and
  the wake and session notifications work without one (checked on 27.2). Anything carried
  by the window server's event stream doesn't: screens waking, display reconfiguration
  (`CGDisplayRegisterReconfigurationCallback`) never arrive. Running a real NSApplication
  would cost ~2.6 MB. ~3.5 MB footprint at start, ~5 MB after the first swipes (one-time
  setup of the window list and app lookups; flat after); 0 wakeups when idle; while
  fingers touch the pad, ~25 µs per frame, mostly the framework.
- **No privacy grants.** MultitouchSupport needs none (verified: the launchd-run agent
  receives frames with nothing granted); opening/hiding apps are LaunchServices requests;
  window owners and bounds (not titles) need no Screen Recording. Empty entitlements,
  hardened runtime. Keep it this way: a grant is a thing that can silently go missing.
- **MultitouchSupport** is looked up with `dlopen`/`dlsym` (`MTAPI`), nothing private is
  linked. The 96-byte `MTTouch` layout Autotouch reads (path id @16, stage @20, normalized x/y
  @32/36) was confirmed against live frames; `onFrame` drops frames that don't fit it and
  logs that once. A contact is a finger (`SwipeRecognizer.isFinger`) when it is touching
  (stage 3 make-touch or 4 touching; hovering and edge contacts are stages 1–2) and the
  driver's finger label (@24) is 0–5: a palm or wrist resting on the pad's edge is labelled
  6–10, so it neither turns a three-finger swipe into four contacts nor keeps the touch
  from ending between swipes (recorded 2026-11-19; the palm tests in
  `SwipeRecognizerTests` reproduce it). Positions are scaled to mm by the device's
  surface size, so thresholds mean the same on every trackpad.
- **SwipeRecognizer** (its doc comment has the rules): exactly three fingers; positions
  measured from when the third came down; ≥ 9 mm average sideways travel, ≥ 1.5× the
  vertical, every finger ≥ 4 mm the same way; fires once per touch; four fingers or a
  vertical start cancel until all fingers lift; more than 10 frames (~80 ms) with fewer
  than three fingers forgets the positions (a finger back after two fingers scrolled a
  while must not fire on stale ones).

## Reliability: what keeps it working

- **launchd KeepAlive**: any exit or crash → restarted (throttled to once per 10 s).
  `ProcessType Interactive`: never throttled. Tested: `kill -9` → back immediately.
- **Trackpads are re-acquired** (`Trackpads.rebuild`: stop, list, start; ~4 ms) on every
  hint the device objects may be stale: IOKit `AppleMultitouchDevice` added/removed (Magic
  Trackpad connects, device re-created), wake from sleep, the login session becoming
  active again, and a start that failed (retried 5 s later, up to 5 times). Hints are
  coalesced: one rebuild at the latest delay asked for, at most 5 s after the first hint,
  and not while fingers are on a pad (a fresh recognizer mid-touch could fire a swipe
  twice). Stale device objects after sleep are the classic way gesture tools stop working.
  None of these paths has run on this Mac yet (no sleep, no Magic Trackpad since the first
  build): after a lid close/open, a Magic Trackpad connecting or a user switch, `make logs`
  should show the rebuild and its reason.
- **MultitouchSupport leaks 16 KB per device start** (a thread stack it never frees,
  measured linear over 200 starts): after 100 rebuilds the agent exits and launchd starts
  it fresh (~35 ms), so at most ~1.6 MB.
- **Session state is read live** (`Session`: `CGSessionCopyCurrentDictionary`), never
  cached: rebuilds don't listen while another user's session is on screen, and swipes do
  nothing while the screen is locked.
- **Upgrades**: the agent watches the folder holding its bundle (FSEvents); when its
  executable is a different file, it exits once the new one is in place and launchd
  starts the new version (tested: ~3 s). `make install` also restarts it directly.
- **One agent per user** (`flock` on `$TMPDIR/com.lingrino.autotouch.lock`): two would both act.
- **Diagnosing "it stopped working"**: `make status` → are trackpads running, are frames
  arriving ("last Ns ago" right after touching the pad), how many swipes fired, rebuilds.
  Then `make logs` while swiping.

## Build, run, test

```
make check       # lint + test + smoke — before every commit
make lint        # debug+release+tests build with -warnings-as-errors (own scratch dir)
make test        # unit tests (swift-testing): the recognizer, synthetic frames
make install     # release build → /Applications/Autotouch.app (in place), restart the agent, status
make smoke       # scripts/smoke.sh: signature, agent loaded/running/current, trackpads, memory
make status      # the agent's status line (SIGINFO → log)
make logs        # follow the agent's log
make release     # what CI publishes (build/release/: zip + cask); not notarized locally
make uninstall   # stop and remove the agent and the app
```

- `scripts/swift.sh` wraps `swift` for the Command Line Tools (this Mac's active developer
  dir) and Xcode alike; copied from fred, see its comments.
- The actions from the real agent, without a trackpad: `pkill -USR1 -x Autotouch` (left: opens
  Chrome), `pkill -USR2 -x Autotouch` (right: hides the app under the pointer). Both change
  what's in front: only when the user expects it.
- Gesture changes need a real swipe on a real trackpad after `make install`, by the user:
  ask them. Watch `make logs` meanwhile; each swipe logs its action.
- `.build/debug/Autotouch --agent` runs an agent in the terminal; stop the installed one first
  (`launchctl bootout gui/$(id -u)/com.lingrino.autotouch.agent`) or the lock keeps it out.

## Signing

Same as fred and peep: local builds sign with the team's Developer ID (no timestamp, not
notarized) from `~/Library/Keychains/developer-id.keychain-db`, which
`scripts/setup-signing.sh` fills (shared by all the maintainer's Mac apps; set up once per
Mac). `AUTOTOUCH_SIGN_IDENTITY=-` builds ad-hoc (CI checks). Bundle id `com.lingrino.autotouch`,
agent label `com.lingrino.autotouch.agent`. The agent is a classic LaunchAgent, not
SMAppService (peep's lesson: SMAppService pins the executable's cdhash).

## CI and releases (`.github/workflows`, copied from fred)

- `validate` on PRs: lint, test + release dry run + `brew style` on the cask, shellcheck +
  actionlint. `release` on every push to main: version 0.0.N (N = commits on main), signed,
  notarized, GitHub release, `Casks/autotouch.rb` in lingrino/homebrew-tap.
- Upgrades swap the bundle; the agent restarts itself. The cask has no `uninstall
  launchctl:` (brew runs it on every upgrade and nothing would re-register the agent);
  `zap` removes the agent. A fresh install needs `open -a Autotouch` once.

## Open decisions

- **Publishing**, step by step like fred and peep. Done: lingrino/infra#3038 created the
  private `lingrino/autotouch` repo (Actions off). Its first apply failed as expected on
  `github_branch` (empty repo) and on the ruleset (403 "Repository has been locked", a new
  repo's first seconds); re-running it after the first push of `main` adds both. Then
  follow-ups like fred's: Actions on, PRs and the `lint`/`test`/`scripts` checks required,
  autotouch in `local.mac_app_repos` (signing, notarization and tap secrets); public with
  secret scanning; `cask 'lingrino/tap/autotouch'` in the dotfiles Brewfiles.
- macOS's own "swipe between full-screen apps" is on three fingers on this Mac
  (`TrackpadThreeFingerHorizSwipeGesture = 2`), so with several desktops or full-screen
  apps a swipe also switches spaces. System
  Settings → Trackpad → More Gestures → four fingers would separate them. Their call.
- Unverified edges: hiding the last app on screen activates Finder, which may switch to
  another Space if Finder's only window is there (activating an app does that when "switch
  to a Space with open windows" is on). The palm filter rests on one recording (right
  hand, built-in pad): a Magic Trackpad or the left hand may label differently, and a
  resting thumb is a finger (label 1), so it still makes four contacts.

## What OS updates can break

- MultitouchSupport is private. If a macOS update renames a symbol, Autotouch logs "MultitouchSupport
  has no …" and idles (it doesn't exit, which would make launchd restart it every 10 s).
  If the touch layout changes, it logs "contact frame doesn't look like…". `make status`
  shows `trackpads 0` or frames that never arrive. Re-check the layout with a probe that
  prints raw frames (offsets above) while touching the pad.
- Magic Mouse is excluded by family ID (112, 113). A new mouse with another ID would be
  listened to; harmless unless three fingers swipe on it.

## Conventions

- The repo is meant to be readable publicly: nothing private, no test data or recordings
  (tests are synthetic), no third-party assets (the icon is drawn by
  `scripts/make-icon.swift`: SF Symbols may not be used in app icons).

- Swift 6 language mode, zero warnings. Main-thread code is `@MainActor`; the frame callback
  runs on MultitouchSupport's thread and touches only `frameState` (an
  `OSAllocatedUnfairLock`), dispatching actions to the main queue.
- The frame callback runs ~125 times a second while touched: no allocation, no logging
  except on a fired swipe or a layout error.
- Logs: `com.lingrino.autotouch`, notice level for everything worth keeping (each swipe's
  action, rebuilds and why, starts). No per-frame logging.

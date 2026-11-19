#!/bin/bash
# Live checks against the installed agent (`make install` first). Never performs a swipe's
# action, so it is safe while the user works; the actions are checked by hand (AGENTS.md).
#
# Catches what unit tests can't: an agent launchd isn't running (or runs from the wrong
# place, or an old build), a signature that isn't the Developer ID, MultitouchSupport no
# longer handing out devices after a macOS update, a footprint that crept up.
# `check && ok || bad …` is safe here: ok always succeeds, so bad runs only on failure.
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
APP=/Applications/Autotouch.app
EXE="$APP/Contents/MacOS/Autotouch"
LABEL=com.lingrino.autotouch.agent
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

[[ -x "$EXE" ]] || { echo "smoke: $APP isn't installed (make install)"; exit 1; }
codesign --verify --strict "$APP" 2>/dev/null && ok || bad "codesign --verify $APP"
codesign -d -r- "$APP" 2>&1 | grep -q 'identifier "com.lingrino.autotouch" and anchor apple generic' \
  && ok || bad "not signed with the Developer ID: $(codesign -d -r- "$APP" 2>&1 | tail -1)"

info="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)"
if [[ -z "$info" ]]; then
  bad "agent $LABEL isn't loaded"
  echo "smoke: $pass passed, $fail failed"
  exit 1
fi
grep -q "state = running" <<<"$info" && ok || bad "agent isn't running: $(grep -m1 'state =' <<<"$info")"
grep -q "program = $EXE" <<<"$info" && ok || bad "agent runs $(grep -m1 'program =' <<<"$info")"
pid="$(awk '$1 == "pid" { print $3; exit }' <<<"$info")"
[[ "$(ps -o comm= -p "${pid:-0}")" == "$EXE" ]] && ok || bad "pid ${pid:-?} isn't $EXE"
# The running agent is the installed build (it restarts itself when the bundle changes).
started="$(LC_ALL=C date -j -f "%a %b %d %T %Y" "$(LC_ALL=C ps -o lstart= -p "${pid:-0}")" +%s 2>/dev/null || echo 0)"
[[ "$(stat -f %m "$EXE")" -le "$started" ]] && ok || bad "the agent started before $EXE was written: stale"

status="$(./scripts/status.sh 2>&1)"
echo "$status"
read -r pads running <<<"$(sed -nE 's/.*trackpads ([0-9]+) \(([0-9]+) running\).*/\1 \2/p' <<<"$status")"
[[ "${pads:-0}" -ge 1 ]] && ok || bad "no trackpads"
[[ "${running:-0}" == "${pads:-x}" ]] && ok || bad "not every trackpad is running"
mem="$(sed -nE 's/.*memory ([0-9.]+) MB.*/\1/p' <<<"$status")"
awk -v m="${mem:-999}" 'BEGIN { exit !(m < 15) }' && ok || bad "memory ${mem:-?} MB (budget 15)"

echo "smoke: $pass passed, $fail failed"
[[ $fail -eq 0 ]]

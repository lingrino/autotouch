#!/bin/bash
# Prints the running agent's status line: it logs one on SIGINFO (Agent.handleSignals).
#   trackpads N (M running)  devices listened to; rebuilds = times they were (re)acquired
#   frames F (last Xs ago)   contact frames received; "never" until a finger touches a trackpad
#   swipes left L right R    actions performed since the agent started
set -euo pipefail
LABEL=com.lingrino.autotouch.agent
pid="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | awk '$1 == "pid" { print $3; exit }' || true)"
if [[ -z "$pid" ]]; then
  echo "autotouch: the agent isn't running (launchctl print gui/$(id -u)/$LABEL)" >&2
  exit 1
fi
kill -INFO "$pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 0.2
  line="$(/usr/bin/log show --last 5s --style compact \
    --predicate "subsystem == \"com.lingrino.autotouch\" AND processID == $pid AND eventMessage BEGINSWITH \"status:\"" \
    2>/dev/null | sed -n 's/.*\] status: /status: /p' | tail -1)"
  if [[ -n "$line" ]]; then
    echo "pid $pid $line"
    exit 0
  fi
done
echo "autotouch: no status line from pid $pid" >&2
exit 1

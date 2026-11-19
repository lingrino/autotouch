# Autotouch build entry points. Everything goes through SwiftPM via scripts/swift.sh (Xcode or
# the Command Line Tools; no Xcode project).
#   make            build release .app into build/Autotouch.app
#   make install    build, update /Applications/Autotouch.app in place, (re)load the agent
#   make test       run unit tests (debug build, all runtime checks on)
#   make lint       release + debug build must produce zero compiler warnings
#   make smoke      live checks against the installed agent (never acts on a swipe)
#   make check      lint + test + smoke: before every commit, and first thing after a break
#   make status     the agent's status line (trackpads, frames, swipes, memory, cpu)
#   make logs       follow the agent's log
#   make release    what CI publishes: build/release/Autotouch-<version>.zip + autotouch.rb (scripts/release.sh)
#   make icon       regenerate Resources/AppIcon.icns (scripts/make-icon.swift)
#   make uninstall  stop and remove the agent and the app (what `brew uninstall --zap` does)

APP        := build/Autotouch.app
INSTALLED  := /Applications/Autotouch.app
LABEL      := com.lingrino.autotouch.agent

.PHONY: all app install uninstall test lint smoke check status logs release icon clean signing

all: app

# Local builds sign with the Developer ID (setup-signing.sh) unless AUTOTOUCH_SIGN_IDENTITY says otherwise.
signing:
	@[ -n "$$AUTOTOUCH_SIGN_IDENTITY" ] || ./scripts/setup-signing.sh --check

app: signing
	./scripts/swift.sh build -c release --product Autotouch
	./scripts/bundle.sh release "$(APP)"

# In place, never delete-and-copy: Background Task Management keeps its record of the app.
# `--register` rewrites the LaunchAgent plist if needed and restarts the agent on the new
# binary.
install: app
	mkdir -p "$(INSTALLED)"
	rsync -a --delete "$(APP)/" "$(INSTALLED)/"
	"$(INSTALLED)/Contents/MacOS/Autotouch" --register
	@sleep 1; ./scripts/status.sh

uninstall:
	-launchctl bootout "gui/$$(id -u)/$(LABEL)"
	rm -f "$(HOME)/Library/LaunchAgents/$(LABEL).plist"
	rm -rf "$(INSTALLED)"

test:
	./scripts/swift.sh test

# Warnings are errors-in-waiting (Swift 6 concurrency diagnostics turn into errors in
# newer language modes). The CLT linker's "search path not found" notes are ignored.
lint:
	@./scripts/lint.sh

smoke:
	@./scripts/smoke.sh

check: lint test smoke

status:
	@./scripts/status.sh

logs:
	/usr/bin/log stream --style compact --level info --predicate 'subsystem == "com.lingrino.autotouch"'

# Locally this signs with the Developer ID but skips notarization (no API key here); CI
# signs, notarizes and publishes.
release: signing
	./scripts/release.sh

icon:
	swift scripts/make-icon.swift .
	rm -rf build/AppIcon.iconset

clean:
	rm -rf .build build

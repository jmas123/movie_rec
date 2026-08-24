#!/usr/bin/env bash
#
# Binged local deploy: build -> unit tests -> install -> launch on the sim.
#
#   ./scripts/deploy.sh              # normal run, keeps your library data
#   ./scripts/deploy.sh --clean      # wipe the app first (after a MediaItem schema change)
#   ./scripts/deploy.sh --no-test    # skip tests, just get it on screen
#
# NOTE: never use `... | grep -q` here. grep -q exits on first match, which
# SIGPIPEs the upstream command, and `set -o pipefail` then reports the whole
# pipeline as failed *because* the match succeeded. Capture into a var instead.
#
set -euo pipefail

SCHEME="Binged"
DEVICE_NAME="iPhone 16"
TEST_PLAN="BingedUnit"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Binged" && pwd)"
DERIVED="$PROJECT_DIR/build/dd"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/$SCHEME.app"

CLEAN=0
RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --clean)   CLEAN=1 ;;
    --no-test) RUN_TESTS=0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

cd "$PROJECT_DIR"

# --- 0. Memory guard (8 GB machine: a build under heavy swap will crawl) ------
FREE_PCT="$(memory_pressure 2>/dev/null | awk '/free percentage/ {print $NF}' | tr -d '%')"
if [[ "$FREE_PCT" =~ ^[0-9]+$ && "$FREE_PCT" -lt 20 ]]; then
  echo "⚠️  Only ${FREE_PCT}% memory free. Close Chrome/VS Code before building."
  echo "    Continuing in 5s (ctrl-C to bail)..."
  sleep 5
fi

# --- 1. Resolve the simulator ------------------------------------------------
DEVICES="$(xcrun simctl list devices available)"
UDID="$(printf '%s\n' "$DEVICES" \
        | grep -E "^[[:space:]]+${DEVICE_NAME} \(" \
        | head -1 | sed -E 's/.*\(([0-9A-Fa-f-]{36})\).*/\1/')"
if [[ -z "$UDID" ]]; then
  echo "❌ No available simulator named '$DEVICE_NAME'." >&2
  exit 1
fi
echo "▸ Simulator: $DEVICE_NAME ($UDID)"
DEST="platform=iOS Simulator,id=$UDID"

# --- 1b. Warn if another session is driving the same device ------------------
OTHER="$(pgrep -fl "xcodebuild.*$UDID" | grep -v "^$$ " || true)"
if [[ -n "$OTHER" ]]; then
  echo "⚠️  Another xcodebuild is already targeting this simulator:"
  printf '    %s\n' "$OTHER"
  echo "    Concurrent runs SIGKILL each other. Continuing in 5s (ctrl-C to bail)..."
  sleep 5
fi

# --- 2. Boot the sim FIRST ---------------------------------------------------
# Order matters: xcodebuild shuts down any simulator *it* booted when the test
# run ends, and that async teardown lands seconds later — killing an app we
# installed in the meantime. Booting first means xcodebuild doesn't own it.
STATE="$(xcrun simctl list devices | grep "$UDID" || true)"
if [[ "$STATE" != *Booted* ]]; then
  echo "▸ Booting simulator..."
  xcrun simctl boot "$UDID"
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null
open -a Simulator

# --- 3. Build ----------------------------------------------------------------
echo "▸ Building..."
set +e
xcodebuild -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
BUILD_RC="${PIPESTATUS[0]}"
set -e
if [[ "$BUILD_RC" -ne 0 ]]; then echo "❌ Build failed."; exit 1; fi

# --- 4. Unit tests (UI tests excluded: they are slow and sim-contended) -------
if [[ "$RUN_TESTS" -eq 1 ]]; then
  echo "▸ Testing ($TEST_PLAN)..."
  set +e
  xcodebuild -scheme "$SCHEME" -destination "$DEST" -derivedDataPath "$DERIVED" \
             -testPlan "$TEST_PLAN" test \
    | grep -E "error:|failed|Executed .* test|TEST (SUCCEEDED|FAILED)"
  TEST_RC="${PIPESTATUS[0]}"
  set -e
  if [[ "$TEST_RC" -ne 0 ]]; then echo "❌ Tests failed."; exit 1; fi
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"

# --- 5. Install (optionally wiping the SwiftData store first) -----------------
# A still-running app, or a leftover UI-test runner from an aborted `test`,
# collides with install/launch and with the XCTest host. Clear both first.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl terminate "$UDID" "${BUNDLE_ID}UITests.xctrunner" 2>/dev/null || true

if [[ "$CLEAN" -eq 1 ]]; then
  echo "▸ Uninstalling (clean)..."
  xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi
echo "▸ Installing $BUNDLE_ID..."
xcrun simctl install "$UDID" "$APP"

# --- 6. Launch and confirm it survived ---------------------------------------
echo "▸ Launching..."
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

alive() {
  local out
  out="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null || true)"
  [[ "$out" == *"UIKitApplication:$BUNDLE_ID"* ]]
}

# Wait for bootstrap (a cold launch here can take well over 3s)...
UP=0
for _ in $(seq 1 15); do
  if alive; then UP=1; break; fi
  sleep 1
done
# ...then re-check a beat later, so an instant crash isn't a false pass.
if [[ "$UP" -eq 1 ]]; then sleep 2; alive || UP=0; fi

FINAL_STATE="$(xcrun simctl list devices | grep "$UDID" || true)"
if [[ "$FINAL_STATE" != *Booted* ]]; then
  echo "❌ The simulator was shut down underneath us (xcodebuild teardown?)."
  echo "   Re-run:  ./scripts/deploy.sh --no-test"
  exit 1
fi

if [[ "$UP" -eq 1 ]]; then
  echo "✅ Running: $BUNDLE_ID on $DEVICE_NAME"
else
  echo "❌ App is not running 15s after launch."
  echo "   If this is a SwiftData schema change, there is no migration plan:"
  echo "   re-run with  ./scripts/deploy.sh --clean"
  exit 1
fi

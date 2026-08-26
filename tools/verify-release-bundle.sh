#!/bin/bash
#
#  verify-release-bundle.sh
#  Binged
#
#  Checks a built .app (or .xcarchive) for the things that are invisible in
#  Xcode and expensive to get wrong: identity, credentials, and the compliance
#  files. Run it after archiving, before uploading.
#
#      tools/verify-release-bundle.sh path/to/Binged.xcarchive
#      tools/verify-release-bundle.sh path/to/Binged.app
#
#  WHY THIS IS A SCRIPT AND NOT A LINE IN A CHECKLIST
#
#  Both hand-rolled commands the docs used to carry were wrong, in opposite
#  and equally quiet directions:
#
#    strings Binged.app/Binged | grep -i supabase
#        Finds nothing on a correctly configured build. The Supabase URL and
#        key are injected through Config/Info.plist and never enter the Mach-O
#        binary, so this reports a healthy build as broken.
#
#    grep -rl "$TOKEN" Binged.app
#        Finds nothing on a build that DOES ship the TMDB token. The built
#        Info.plist is a *binary* plist; BSD grep classifies it as a binary
#        file and returns exit 1 with no output, which is indistinguishable
#        from a clean result. `grep -a` finds it immediately. This one is the
#        dangerous direction: it is the acceptance criterion for Phase 35, and
#        it passes on exactly the build Phase 35 exists to prevent.
#
#  So: ask plutil for plist values rather than grepping bytes, and use `grep -a`
#  for the belt-and-braces sweep. Never print a credential — presence, length
#  and a short prefix are enough to tell configured from unconfigured, and this
#  output ends up pasted into issues and transcripts.
#
#  Exit status is 0 only if every FAIL-level check passes.

set -uo pipefail

TARGET="${1:-}"
ALLOW_TMDB_TOKEN=0
for arg in "$@"; do
  [[ "$arg" == "--allow-tmdb-token" ]] && ALLOW_TMDB_TOKEN=1
done

if [[ -z "$TARGET" || "$TARGET" == -* ]]; then
  echo "usage: $0 <Binged.xcarchive | Binged.app> [--allow-tmdb-token]" >&2
  exit 2
fi

# An .xcarchive holds the app one level down. Accept either so nobody has to
# remember which one the checklist meant.
if [[ "$TARGET" == *.xcarchive ]]; then
  APP=$(find "$TARGET/Products/Applications" -maxdepth 1 -name "*.app" | head -1)
  if [[ -z "$APP" ]]; then
    echo "no .app inside $TARGET/Products/Applications" >&2
    exit 2
  fi
else
  APP="$TARGET"
fi

PLIST="$APP/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "no Info.plist at $PLIST — is that really an app bundle?" >&2
  exit 2
fi

FAILURES=0
BOLD=$'\033[1m'; RESET=$'\033[0m'
GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'

pass() { printf "  ${GREEN}✔${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
fail() { printf "  ${RED}✘${RESET} %s\n" "$1"; FAILURES=$((FAILURES + 1)); }
head_() { printf "\n${BOLD}%s${RESET}\n" "$1"; }

# plutil prints "Could not extract value" to STDOUT, not stderr, so a missing
# key silently becomes its own error message as the "value" unless the exit
# status is checked. That produced a check reporting
# `ITSAppUsesNonExemptEncryption = <the error text>`.
plist_value() {
  local out
  if out=$(plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null); then
    printf '%s' "$out"
  fi
}

printf "${BOLD}Verifying${RESET} %s\n" "$APP"

# MARK: - Identity

head_ "Identity"

BUNDLE_ID=$(plist_value CFBundleIdentifier)
EXPECTED_ID="com.trybinged.Binged"
if [[ "$BUNDLE_ID" == "$EXPECTED_ID" ]]; then
  pass "bundle id $BUNDLE_ID"
else
  fail "bundle id is '$BUNDLE_ID', expected '$EXPECTED_ID'"
fi

# iPhone-only as of 2026-08-26. This is a promise to a reviewer as much as a
# build setting: a bundle claiming iPad gets opened on one, and nothing in the
# app has ever been laid out for that screen.
FAMILY=$(plutil -extract UIDeviceFamily json -o - "$PLIST" 2>/dev/null)
if [[ "$FAMILY" == "[1]" ]]; then
  pass "iPhone only (UIDeviceFamily $FAMILY)"
else
  fail "UIDeviceFamily is $FAMILY, expected [1] — an iPad claim means the reviewer tests on iPad"
fi

VERSION=$(plist_value CFBundleShortVersionString)
BUILD=$(plist_value CFBundleVersion)
if [[ -n "$VERSION" && -n "$BUILD" ]]; then
  pass "version $VERSION ($BUILD)"
  warn "build number must be unique per TestFlight upload — bump CURRENT_PROJECT_VERSION in Base.xcconfig"
else
  fail "missing CFBundleShortVersionString or CFBundleVersion"
fi

# MARK: - Credentials
#
# The whole point of the file. A build can be missing these and look completely
# healthy until somebody taps Sign In.

head_ "Credentials"

SUPABASE_URL=$(plist_value SupabaseURL)
if [[ "$SUPABASE_URL" == https://* ]]; then
  pass "SupabaseURL $SUPABASE_URL"
elif [[ -z "$SUPABASE_URL" ]]; then
  fail "SupabaseURL is empty — the app will have NO accounts, no sync and no feed. Is Config/Secrets.xcconfig present?"
else
  fail "SupabaseURL is '$SUPABASE_URL', which is not an https URL"
fi

ANON_KEY=$(plist_value SupabaseAnonKey)
if [[ -n "$ANON_KEY" ]]; then
  # Public by design (RLS is the security boundary) but still not worth echoing
  # in full into a terminal that gets screenshotted.
  pass "SupabaseAnonKey present — ${#ANON_KEY} chars, starts '${ANON_KEY:0:15}…'"
else
  fail "SupabaseAnonKey is empty — sign-in will fail. Is Config/Secrets.xcconfig present?"
fi

# MARK: - The TMDB token, which must NOT be here
#
# Two checks, because one of them used to be the whole story and was wrong: ask
# the plist directly, then sweep the bundle for anything token-shaped in case it
# reached the build by some route nobody has thought of.

head_ "TMDB token (must be absent from a release build)"

TMDB_TOKEN=$(plist_value TMDBReadToken)
if [[ -z "$TMDB_TOKEN" ]]; then
  pass "TMDBReadToken is empty — the app will use the tmdb-proxy edge function"
elif [[ "$ALLOW_TMDB_TOKEN" == 1 ]]; then
  warn "TMDBReadToken present (${#TMDB_TOKEN} chars) — allowed by --allow-tmdb-token; fine for a dev build, never for an upload"
else
  fail "TMDBReadToken is in the bundle (${#TMDB_TOKEN} chars) and is extractable by anyone with the .ipa. Deploy tmdb-proxy, unset TMDB_READ_TOKEN for release, and ROTATE the token. Pass --allow-tmdb-token for a dev build."
fi

# Belt and braces. -a is load-bearing: without it grep treats the binary plist
# as binary, prints nothing, exits 1, and looks exactly like a clean bundle.
# PlugIns are test bundles and are not part of a release archive.
JWT_HITS=$(grep -ral "eyJhbGci" "$APP" 2>/dev/null | grep -v "/PlugIns/" || true)
if [[ -z "$JWT_HITS" ]]; then
  pass "no JWT-shaped strings anywhere in the bundle"
else
  # A JWT-shaped anon key would land here legitimately; the new sb_publishable_
  # format would not. Report rather than judge.
  warn "JWT-shaped strings found — confirm each is the public anon key, not a TMDB token:"
  while IFS= read -r f; do warn "    ${f#"$APP"/}"; done <<< "$JWT_HITS"
fi

# MARK: - Compliance files

head_ "Compliance"

ENCRYPTION=$(plist_value ITSAppUsesNonExemptEncryption)
if [[ "$ENCRYPTION" == "false" ]]; then
  pass "ITSAppUsesNonExemptEncryption = false — uploads will not stop to ask"
elif [[ -z "$ENCRYPTION" ]]; then
  fail "ITSAppUsesNonExemptEncryption missing — every upload will prompt for export compliance"
else
  warn "ITSAppUsesNonExemptEncryption = $ENCRYPTION (expected false; the app makes only HTTPS calls)"
fi

if [[ -f "$APP/PrivacyInfo.xcprivacy" ]]; then
  pass "PrivacyInfo.xcprivacy present"
else
  fail "PrivacyInfo.xcprivacy missing from the bundle — required for submission"
fi

if [[ -f "$APP/Assets.car" ]] && assetutil --info "$APP/Assets.car" 2>/dev/null | grep -q "AppIcon"; then
  pass "AppIcon present in Assets.car"
else
  fail "no AppIcon found in Assets.car — archive validation rejects an iconless app"
fi

# MARK: - Result

echo
if [[ "$FAILURES" == 0 ]]; then
  printf "${GREEN}${BOLD}OK${RESET} — nothing blocking an upload.\n"
  exit 0
else
  printf "${RED}${BOLD}%d check(s) failed.${RESET}\n" "$FAILURES"
  exit 1
fi

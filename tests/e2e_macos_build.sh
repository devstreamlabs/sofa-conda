#!/usr/bin/env bash
# Opt-in end-to-end test: a real sofa-python3 build through scripts/build-feedstock.sh on a Mac,
# proving the package is produced and the machine outside the work dir is untouched.
# Takes about 15 minutes and downloads miniforge, the macOS SDK and the build dependencies.
#
#   SOFA_E2E=1 tests/e2e_macos_build.sh [work-dir]
set -euo pipefail
[[ "${SOFA_E2E:-}" == 1 ]] || { echo "skipped: set SOFA_E2E=1 to run a real build"; exit 0; }
[[ "$(uname -s)" == Darwin ]] || { echo "skipped: needs macOS"; exit 0; }

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-$HOME/sofa-build/e2e-$(date +%s)}
FS=$WORK/sofa-python3-feedstock
mkdir -p "$WORK"
git clone -q -b sofa-26.06 https://github.com/devstreamlabs/sofa-python3-feedstock "$FS"
CFG=$(cd "$FS/.ci_support" && ls "osx_$( [[ $(uname -m) == arm64 ]] && echo arm64 || echo 64)"_python3.14*.yaml | head -1)

state() { ls -A /usr/local /opt; ls -l /usr/local/bin 2>/dev/null | md5; }
BEFORE=$(state)
rc=0; CI=github_actions "$HERE/../scripts/build-feedstock.sh" "$FS" "${CFG%.yaml}" "$WORK/build" \
  > "$WORK/build.log" 2>&1 || rc=$?
AFTER=$(state)

FAILS=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$3', got '$2'"; FAILS=$((FAILS + 1)); fi; }
check "build exit code (log: $WORK/build.log)" "$rc" 0
check "sofa-python3 package produced" "$(find "$WORK/build/conda-bld" -name 'sofa-python3-*.conda' | wc -l | tr -d ' ')" 1
check "mangle_homebrew not run" "$(grep -c 'Not mangling homebrew as we are not running in CI' "$WORK/build.log")" 1
check "/usr/local and /opt unchanged" "$AFTER" "$BEFORE"
[[ $FAILS == 0 ]] && echo "all passed" || { echo "$FAILS failed"; exit 1; }

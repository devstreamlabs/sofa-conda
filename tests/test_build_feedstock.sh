#!/usr/bin/env bash
# Tests for scripts/build-feedstock.sh. Runs on Linux or macOS, touches nothing outside a
# temporary directory: system paths are simulated through SOFA_BUILD_SYSROOT.
#
#   tests/test_build_feedstock.sh
#
# tests/fixtures/run_osx_build.sh is conda-smithy's script as generated in both SOFA feedstocks
# (sofa-26.06 branch): the one that ran `sudo mangle_homebrew` on 2026-10-04 with CI set.
# SOFA_FEEDSTOCK=<checkout> additionally checks that checkout's current script.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LAUNCHER=$HERE/../scripts/build-feedstock.sh
T=$(mktemp -d "${TMPDIR:-$HOME}/test_build_feedstock.XXXXXX")
trap 'rm -rf "$T"' EXIT
FAILS=0
check() { if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected '$3', got '$2'"; FAILS=$((FAILS + 1)); fi; }

# A feedstock with one config and the given osx and linux build scripts.
feedstock() {
  local d=$T/$1; mkdir -p "$d/.ci_support" "$d/.scripts"
  echo "target_platform: [osx-64]" > "$d/.ci_support/cfg.yaml"
  cp "$2" "$d/.scripts/run_osx_build.sh"; cp "$3" "$d/.scripts/run_docker_build.sh"
  echo "$d"
}
# A simulated machine root; "shared" puts the fleet's service manager in /usr/local/bin.
sysroot() {
  local r=$T/root-$1; mkdir -p "$r/usr/local/bin" "$r/usr/local/share" "$r/opt"
  [[ $2 == shared ]] && touch "$r/usr/local/bin/dsl_sm"
  echo "$r"
}
run() { local rc=0; OUT=$(env "$@" "$LAUNCHER" "${ARGS[@]}" 2>&1) || rc=$?; RC=$rc; }

# conda-forge's CI branch, reduced to what it does to the machine.
cat > "$T/mangles_when_ci.sh" <<'SH'
echo "CI=[${CI:-}] GITHUB_ACTIONS=[${GITHUB_ACTIONS:-}] OSX_SDK_DIR=[${OSX_SDK_DIR:-}]" > "$SEEN"
if [[ "${CI:-}" != "" ]]; then
  mkdir -p "$SOFA_BUILD_SYSROOT/usr/local/conda_mangled"
  mv "$SOFA_BUILD_SYSROOT/usr/local/bin" "$SOFA_BUILD_SYSROOT/usr/local/conda_mangled/"
fi
SH
cat > "$T/mangles_always.sh" <<'SH'
mkdir -p "$SOFA_BUILD_SYSROOT/usr/local/conda_mangled"
SH
sed -e 's|^if \[\[ "\${CI:-}" != "" \]\]; then$|if [[ "${FORCE:-}" != "" ]]; then|' \
  "$HERE/fixtures/run_osx_build.sh" > "$T/ungated_osx_build.sh"
grep -q 'FORCE' "$T/ungated_osx_build.sh" || { echo "FAIL fixture: CI gate not found to remove"; exit 1; }

FS=$(feedstock fs "$HERE/fixtures/run_osx_build.sh" "$T/mangles_when_ci.sh")
FS_UNGATED=$(feedstock fs-ungated "$T/ungated_osx_build.sh" "$T/mangles_when_ci.sh")
FS_RUN=$(feedstock fs-run "$T/mangles_when_ci.sh" "$T/mangles_when_ci.sh")
FS_BAD=$(feedstock fs-bad "$T/mangles_always.sh" "$T/mangles_always.sh")

echo "# macOS (dry run): the conda-forge script is accepted only in its non-mutating mode"
R=$(sysroot a shared); ARGS=(--dry-run "$FS" cfg "$T/work")
run SOFA_BUILD_OS=Darwin SOFA_BUILD_SYSROOT="$R" CI=github_actions GITHUB_ACTIONS=true
check "shared Mac, caller has CI=github_actions: accepted" "$RC" 0
check "build env has CI unset" "$(grep -c "CI in build env: ''" <<<"$OUT")" 1
check "build script has no sudo outside a CI branch" "$(grep -c 'ungated sudo lines: none' <<<"$OUT")" 1
check "build env strips CI and points OSX_SDK_DIR at the work dir" \
  "$(grep -c -- "-u CI .*OSX_SDK_DIR=$T/work/SDKs .*sandbox-exec" <<<"$OUT")" 1

ARGS=(--dry-run "$FS_UNGATED" cfg "$T/work")
run SOFA_BUILD_OS=Darwin SOFA_BUILD_SYSROOT="$R"
check "shared Mac, script runs sudo outside a CI branch: refused" "$RC" 3
check "refusal names the mangle_homebrew line" "$(grep -c 'sudo mangle_homebrew' <<<"$OUT")" 1

R2=$(sysroot b private)
run SOFA_BUILD_OS=Darwin SOFA_BUILD_SYSROOT="$R2"
check "unshared Mac, same script: allowed (CI still stripped)" "$RC" 0

R3=$(sysroot c shared); mkdir -p "$R3/usr/local/conda_mangled"; ARGS=(--dry-run "$FS" cfg "$T/work")
run SOFA_BUILD_OS=Darwin SOFA_BUILD_SYSROOT="$R3"
check "machine already mangled: refused" "$RC" 3
check "refusal prints the restore command" "$(grep -c 'sudo mv /usr/local/conda_mangled/\* /usr/local/' <<<"$OUT")" 1

# Real runs use this host's own wrapping: sandbox-exec on macOS, script(1) for docker on Linux.
OS=$(uname -s); SDK=""; [[ $OS == Darwin ]] && SDK=$T/work/SDKs
echo "# $OS (real run of a stand-in build script)"
R4=$(sysroot d shared); ARGS=("$FS_RUN" cfg "$T/work")
run SOFA_BUILD_SYSROOT="$R4" SEEN="$T/seen" CI=github_actions GITHUB_ACTIONS=true
check "build with caller CI set: succeeds" "$RC" 0
check "build script saw no CI" "$(cat "$T/seen" 2>/dev/null)" "CI=[] GITHUB_ACTIONS=[] OSX_SDK_DIR=[$SDK]"
check "/usr/local/bin/dsl_sm still in place" "$([[ -e $R4/usr/local/bin/dsl_sm ]] && echo yes)" yes

R5=$(sysroot e shared); ARGS=("$FS_BAD" cfg "$T/work")
run SOFA_BUILD_SYSROOT="$R5"
check "build that changes /usr/local anyway: fails with 4" "$RC" 4
check "failure shows what changed" "$(grep -c '> conda_mangled' <<<"$OUT")" 1

if [[ -n "${SOFA_FEEDSTOCK:-}" ]]; then
  echo "# $SOFA_FEEDSTOCK"
  R6=$(sysroot f shared); CFG=$(cd "$SOFA_FEEDSTOCK/.ci_support" && ls osx_*.yaml | head -1)
  ARGS=(--dry-run "$SOFA_FEEDSTOCK" "${CFG%.yaml}" "$T/work")
  run SOFA_BUILD_OS=Darwin SOFA_BUILD_SYSROOT="$R6" CI=github_actions
  check "current feedstock script accepted on a shared Mac" "$RC" 0
fi

[[ $FAILS == 0 ]] && echo "all passed" || { echo "$FAILS failed"; exit 1; }

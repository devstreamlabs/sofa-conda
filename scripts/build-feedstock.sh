#!/usr/bin/env bash
# Build one config of a SOFA conda-forge feedstock without modifying the machine it runs on.
#
#   scripts/build-feedstock.sh [--dry-run] <feedstock-dir> <config> [work-dir]
#
#   feedstock-dir  a checkout of devstreamlabs/sofa-python3-feedstock or
#                  devstreamlabs/sofa-beamadapter-feedstock (branch sofa-26.06)
#   config         a .ci_support/<config>.yaml name, e.g. osx_64_python3.14.____cp314
#   work-dir       miniforge, SDKs and conda-bld go here (default ~/sofa-build/<feedstock>)
#   --dry-run      run every guard, print the build command and its environment, build nothing
#
# Why this exists: conda-forge's generated .scripts/run_osx_build.sh treats a non-empty CI as
# "this is a throwaway hosted runner". With CI set it runs `sudo mangle_homebrew`, which moves
# every entry of /usr/local into /usr/local/conda_mangled, and `sudo mkdir/chown /opt/conda-sdks`;
# run_conda_forge_build_setup may then `plutil -replace` the Xcode platform Info.plist. On
# 2026-10-04 a SofaPython3 build started with CI=github_actions on a shared fleet Mac moved
# /usr/local/bin away, and the service manager installed there (dsl_sm) went with it.
#
# So this launcher, the single supported way to build these feedstocks outside hosted CI:
#   * runs the conda-forge scripts with CI unset (conda-smithy's build-locally path), with
#     MINIFORGE_HOME and OSX_SDK_DIR inside the work dir, so none of those steps run;
#   * refuses to start on a shared builder (/usr/local/bin/dsl_sm present) unless that
#     non-mutating mode provably holds: CI empty in the build's environment, and every sudo
#     line of the feedstock's build script inside a CI-only branch;
#   * on macOS runs the build under sandbox-exec with writes to system paths denied, so a step
#     added by a future re-render cannot move them either (inside it sudo cannot even start);
#   * compares /usr/local and /opt before and after, and fails loudly if either changed.
#
# Exit codes: 2 usage, 3 refused by a guard, 4 the machine changed during the build,
# otherwise the build's own exit code.
#
# Test hooks (tests/test_build_feedstock.sh): SOFA_BUILD_OS overrides `uname -s`,
# SOFA_BUILD_SYSROOT prefixes the system paths that are checked.
set -euo pipefail

die() { echo "build-feedstock: $1" >&2; exit "${2:-3}"; }

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; shift; fi
[[ $# -ge 2 && $# -le 3 ]] || die "usage: $0 [--dry-run] <feedstock-dir> <config> [work-dir]" 2

FEEDSTOCK=$(cd "$1" && pwd) || die "no such feedstock dir: $1" 2
CONFIG=$2
NAME=$(basename "$FEEDSTOCK")
WORK=${3:-$HOME/sofa-build/$NAME}
OS=${SOFA_BUILD_OS:-$(uname -s)}
SYSROOT=${SOFA_BUILD_SYSROOT:-}

[[ -f "$FEEDSTOCK/.ci_support/$CONFIG.yaml" ]] || die "no config $FEEDSTOCK/.ci_support/$CONFIG.yaml" 2
case "$OS" in
  Darwin) SCRIPT=.scripts/run_osx_build.sh ;;
  Linux)  SCRIPT=.scripts/run_docker_build.sh ;;
  *)      die "unsupported OS '$OS' (Windows: run .scripts\\run_win_build.bat with CI unset)" 2 ;;
esac
[[ -f "$FEEDSTOCK/$SCRIPT" ]] || die "missing $FEEDSTOCK/$SCRIPT" 2
[[ $(id -u) -ne 0 ]] || die "refusing to build as root"

# Markers of a machine other services depend on. Any of them makes this a shared builder.
SHARED_MARKERS=("$SYSROOT/usr/local/bin/dsl_sm" "$SYSROOT/opt/dslp" "$SYSROOT/opt/dsl")
SHARED=0
for m in "${SHARED_MARKERS[@]}"; do [[ -e "$m" ]] && SHARED=1 && SHARED_BY=$m && break; done

# An earlier mangle that was never reversed: the machine is already broken, do not build on it.
if [[ -e "$SYSROOT/usr/local/conda_mangled" ]]; then
  die "$SYSROOT/usr/local/conda_mangled exists: a previous conda-forge CI build moved /usr/local. Restore it first:
  sudo mv /usr/local/conda_mangled/* /usr/local/ && sudo rmdir /usr/local/conda_mangled"
fi

# Lines of a conda-forge build script that run sudo outside a CI-only branch. An empty result
# means: with CI unset, the script runs no sudo at all.
ungated_sudo() {
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*if[[:space:]]/ {
      g = "other"
      if ($0 ~ /\$\{CI:-\}"?[[:space:]]*!=[[:space:]]*""/) g = "ci"
      else if ($0 ~ /\$\{CI:-\}"?[[:space:]]*==[[:space:]]*""/) g = "noci"
      stack[++n] = g
    }
    /^[[:space:]]*else([[:space:]]|$)/ && n > 0 {
      if (stack[n] == "ci") stack[n] = "noci"; else if (stack[n] == "noci") stack[n] = "ci"
    }
    /(^|[^[:alnum:]_])sudo([[:space:]]|$)/ {
      gated = 0
      for (i = 1; i <= n; i++) if (stack[i] == "ci") gated = 1
      if (!gated) printf "%s:%d: %s\n", FILENAME, FNR, $0
    }
    /^[[:space:]]*fi([[:space:];]|$)/ && n > 0 { n-- }
  ' "$1"
}

# The build environment: the caller's, minus every variable the conda-forge scripts read as
# "running in hosted CI". CI is the one they branch on; the others identify the CI vendor.
CI_VARS=(CI GITHUB_ACTIONS TF_BUILD BUILD_BUILDID AZURE_HTTP_USER_AGENT CIRCLECI TRAVIS)
ENV_CMD=(env)
for v in "${CI_VARS[@]}"; do ENV_CMD+=(-u "$v"); done
ENV_CMD+=(
  CONFIG="$CONFIG" UPLOAD_PACKAGES=False IS_PR_BUILD=True
  MINIFORGE_HOME="$WORK/miniforge3" CONDA_BLD_PATH="$WORK/conda-bld"
)
[[ "$OS" == Darwin ]] && ENV_CMD+=(OSX_SDK_DIR="$WORK/SDKs")

# Non-mutating mode, proven rather than assumed: the environment the build will actually get
# has no CI, and the script it runs has no sudo outside a CI branch.
CHILD_CI=$("${ENV_CMD[@]}" sh -c 'printf %s "${CI:-}"')
UNGATED=$(ungated_sudo "$FEEDSTOCK/$SCRIPT")
if [[ $SHARED == 1 ]]; then
  [[ -z "$CHILD_CI" ]] || die "shared builder ($SHARED_BY) and the build would see CI='$CHILD_CI'"
  [[ -z "$UNGATED" ]] || die "shared builder ($SHARED_BY) and $SCRIPT runs sudo outside a CI branch:
$UNGATED"
fi

BUILD_CMD=(bash "$SCRIPT")
if [[ "$OS" == Darwin ]]; then
  # Deny writes to system locations for the whole build tree, sudo children included.
  PROFILE='(version 1)(allow default)(deny file-write* (subpath "/usr") (subpath "/opt") (subpath "/Applications") (subpath "/Library") (subpath "/System") (subpath "/etc") (subpath "/private/etc"))'
  BUILD_CMD=(/usr/bin/sandbox-exec -p "$PROFILE" "${BUILD_CMD[@]}")
elif [[ ! -t 0 ]]; then
  # run_docker_build.sh adds `docker run -it` when CI is unset; give it a terminal.
  BUILD_CMD=(script -qefc "$(printf '%q ' "${BUILD_CMD[@]}")" /dev/null)
fi

echo "build-feedstock: $NAME $CONFIG on $OS (shared=$SHARED), work dir $WORK"
echo "build-feedstock: CI in build env: '${CHILD_CI}'; ungated sudo lines: ${UNGATED:-none}"
if [[ $DRY_RUN == 1 ]]; then
  printf 'build-feedstock: would run in %s:\n ' "$FEEDSTOCK"; printf ' %q' "${ENV_CMD[@]}" "${BUILD_CMD[@]}"; echo
  exit 0
fi

snapshot() { for d in "$SYSROOT/usr/local" "$SYSROOT/opt"; do echo "== $d"; ls -A "$d" 2>/dev/null || true; done; }
BEFORE=$(snapshot)
mkdir -p "$WORK/SDKs"
rc=0
(cd "$FEEDSTOCK" && "${ENV_CMD[@]}" "${BUILD_CMD[@]}") || rc=$?
AFTER=$(snapshot)
if [[ "$BEFORE" != "$AFTER" ]]; then
  echo "build-feedstock: THE BUILD CHANGED SYSTEM PATHS. Before vs after:" >&2
  diff <(echo "$BEFORE") <(echo "$AFTER") >&2 || true
  exit 4
fi
exit $rc

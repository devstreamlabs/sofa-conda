# sofa-conda

A conda channel with SOFA 26.06's Python 3.14 bindings, served by GitHub Pages:

    https://devstreamlabs.github.io/sofa-conda

| package | built from |
|---|---|
| `sofa-python3` 26.06 (cp314) | [devstreamlabs/sofa-python3-feedstock](https://github.com/devstreamlabs/sofa-python3-feedstock), branch `sofa-26.06` |
| `sofa-beamadapter` 26.06 | [devstreamlabs/sofa-beamadapter-feedstock](https://github.com/devstreamlabs/sofa-beamadapter-feedstock), branch `sofa-26.06` |

SOFA itself (`libsofa`) comes from conda-forge, so list this channel first and conda-forge
after it:

```toml
[tool.pixi.workspace]
channels = ["https://devstreamlabs.github.io/sofa-conda", "conda-forge"]
```

Platforms: `win-64`. SofaPython3 is built against pybind11 3.0.x on purpose; 3.1.0 segfaults
when a binding is called with the wrong argument types (pybind/pybind11#6183).

This channel exists until conda-forge/sofa-python3-feedstock#4 and
conda-forge/sofa-beamadapter-feedstock#1 merge. After that, use conda-forge alone.

To add a package: copy the `.conda` file into its platform directory, run
`pixi exec rattler-index fs .` at the root, and commit.

## Building the packages

Build each feedstock config with `scripts/build-feedstock.sh`, never by running the feedstock's
`.scripts/run_osx_build.sh` with `CI` set:

    scripts/build-feedstock.sh <feedstock-checkout> osx_64_python3.14.____cp314

With `CI` set, conda-forge's macOS script assumes a throwaway hosted runner and runs
`sudo mangle_homebrew`, which moves everything in `/usr/local` into `/usr/local/conda_mangled`
(on 2026-10-04 that took a shared build machine's service manager with it). The launcher builds
with `CI` unset, keeps miniforge, the SDK and the output in a work dir, runs the macOS build in a
sandbox that cannot write system paths, refuses to start on a shared builder if any of that would
not hold, and fails if `/usr/local` or `/opt` changed. Windows builds have no such step: run
`.scripts\run_win_build.bat` with `CI` unset.

Tests: `tests/test_build_feedstock.sh` (no build, any OS); `SOFA_E2E=1 tests/e2e_macos_build.sh`
for a real macOS build that checks the machine was left alone.

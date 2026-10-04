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

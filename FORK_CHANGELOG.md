# Fork Changelog

This document summarizes the key differences and enhancements in this fork
relative to the upstream [Code Puppy](https://github.com/mpfaffenberger/code_puppy) project.

For per-commit detail, see `git log`.

## Release History

### v0.1.0 (2026-05-09) — Elixir-native release stream

- **Phase J root restructure**: Elixir app moved from nested subdirectory to
  repository root. All CI workflows, scripts, Python bridge paths, and
  documentation updated for new layout.
- **TUI flake fix** (code-puppy-268): Owl.IO.select/CaptureIO GenServer timeout
  flakes resolved via `force_fallback_select` env + `CaptureIO("\n")`.
- **Session storage flake fix** (code-puppy-dt3): SQLite busy concurrency flakes
  resolved via prefixed ETS table names + `safe_insert`/`safe_lookup` wrappers.
- **Release-gate race fix** (code-puppy-mkk.1): Fresh-worktree dependency
  compilation race eliminated by adding explicit `mix deps.get` → `mix deps.compile`
  before format/compile gates.
- **TUI spinner fix**: Duplicate tool-call spinners eliminated.
- **Python compatibility audit**: Documented Elixir-first/Python-optional runtime
  guarantee for 0.1.x stream.
- **Known P3 follow-ups**: ETS cleanup closure in pubsub test (mkk.4),
  `validate_mvp.sh` deps.compile gap (mkk.5), CommandRunnerTest timing flake.
- Validation: `docs/release/v0.1.0-validation.md`

### codepp 0.0.456 (2026-05-05) — Python/PyPI compatibility stream

- **Phase 1 `pup` alias deprecation**: opt-in warning via
  `PUP_PUP_ALIAS_DEPRECATED=1` when the CLI is invoked as `pup` or
  `pup.exe`. The `pup` entry point is NOT removed; migration guidance
  recommends `code-puppy` for Python and explicit `./pup` / native binary
  for Elixir. See `docs/release/python-pup-alias-deprecation-plan.md`.
- Release notes: `docs/release/codepp-0.0.456.md`

## Key Fork Differences

### Architecture & Runtime

- **Elixir-native runtime and Phoenix control plane** (repository-root Elixir app: `mix.exs`, `lib/`, `priv/`, `rel/`)
  are now the default for agent execution, tooling, session management,
  scheduling, and orchestration.
- **Python compatibility path**: The Python package/CLI remains available for
  legacy PyPI usage, Python plugins/agents, and troubleshooting. The Elixir
  escript (`pup`) and Python console script (`code-puppy`, plus the legacy
  Python `pup` alias in the `codepp` wheel) coexist. The Python `pup` alias
  is being deprecated — see
  `docs/release/python-pup-alias-deprecation-plan.md` for the phased plan
  and opt-in warning (`PUP_PUP_ALIAS_DEPRECATED=1`). Use
  `uvx --from codepp code-puppy` or a known Python venv's `code-puppy` to force
  the Python/PyPI path and an explicit Elixir binary path (`./pup` or packaged
  native artifact) when `PATH` ambiguity matters. `--bridge-mode` or
  `PUP_RUNTIME=python` explicitly delegates to the Python bridge runtime.
- **Burrito single-binary packaging** for macOS, Linux, and Windows — no
  Erlang/Elixir installation required on target machines.

### Python Distribution (Legacy/Compatibility)

- Published to PyPI as **`codepp`** (the `code-puppy` name on PyPI belongs to
  upstream). Installed Python entry points remain `code-puppy`, legacy alias
  `pup` (being deprecated — see deprecation plan), and `gac` for compatibility with existing workflows. The Python `0.0.x`
  version stream is independent from the Elixir-native `0.1.x` stream in
  root `mix.exs`.
- Requires **Python 3.14+** when using the Python package/CLI, Python bridge, or
  free-threaded compatibility path.

### CI & Release

- **Two tag namespaces** — `v*` tags trigger Burrito/Elixir releases
  (`burrito-release.yml`); `codepp/*` tags trigger Python/PyPI releases
  (`publish-pypi.yml`). **Never use `v0.0.x` for Python** or `codepp/x.y.z`
  for Elixir.
- **GitHub Actions CI** (`ci.yml`): Python lint/test, Elixir format/compile/test,
  Elixir smoke/escript validation on every push/PR.
- **Burrito release workflow** (`burrito-release.yml`): tag-triggered builds on
  3 platforms with GitHub Release + SHA256SUMS.txt.
- **PyPI publish workflow** (`publish-pypi.yml`): tag-triggered (`codepp/*`)
  OIDC Trusted Publishing via `pypa/gh-action-pypi-publish`. Validates tag
  version matches `pyproject.toml`, runs quality gates, builds sdist + wheel.
- **Local release gate** (`scripts/release-gate.sh`): pre-push quality gate
  for Python and Elixir lanes.
- **Python package smoke** (`scripts/python-package-smoke.sh`): validates
  wheel build, install, and entry points from a clean venv.

### Plugins & Agents

- 48 plugins, 18+ agents, 150+ merged feature branches.
- Agent names aligned with current catalogue (`elixir-code-critic`, `qa-kitten`).
- Default plugin system uses Elixir `CodePuppyControl.Callbacks`; legacy Python plugins under `code_puppy/plugins/` remain supported through the compatibility bridge.

### Security

- AES-256-GCM credential encryption with per-installation machine secrets.
- OAuth integration (ChatGPT, Claude) with PKCE flow.
- SQLite database isolation (ADR-003: separate from Python `~/.code_puppy/`).

### Free-Threading

- Python 3.14t free-threaded mode supported for true parallel execution.
- Pack parallelism boost with GIL-disabled interpreter.

---

For the upstream project's changelog, see the
[upstream repository](https://github.com/mpfaffenberger/code_puppy).

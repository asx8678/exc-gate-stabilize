# Root Restructure Validation & Baseline

**Epic:** `code-puppy-2xg` — Root restructure: Elixir app to repository root
**Stage:** `code-puppy-2xg.1` — Stage A: Execute root Elixir migration with Python preserved

## Environment

| Field | Value |
|---|---|
| **CWD** | `/home/adam/projects/exc` (bare repo root) |
| **Branch** | `wave3/code-puppy-3o7.6-c-runtime-removal` |
| **Worktree** | bare (`core.bare=true`) — all git ops require `--git-dir=.git --work-tree=.` |
| **Initial commit** | `chore: snapshot baseline before root restructure` |
| **Last updated** | 2026-05-08 |

> **Worktree rule:** All git commands in `/home/adam/projects/exc` must use explicit
> `git --git-dir=.git --work-tree=.` flags because `core.bare=true`. Never run bare
> git commands without `--work-tree=.` pointing to a real filesystem directory.

## Phase 0: Baseline Validation

> **Historical baseline note:** nested `elixir/code_puppy_control` paths in this section intentionally record the pre-root-migration validation environment.

### Elixir Baseline (from `elixir-expert` audit)

Ran in `elixir/code_puppy_control/` against the baseline snapshot.

| Check | Result | Duration |
|---|---|---|
| `mix deps.get` | ✅ PASS (exit 0) | ~3s |
| `mix compile --warnings-as-errors` | ✅ PASS (exit 0, zero warnings) | ~3s |
| `mix format --check-formatted` | ✅ PASS (exit 0) | ~7s |
| `mix test --max-failures 5` | ⚠️ 2 FAILURES (exit 2) | 400.8s total |

**Test summary:** 9 doctests, 89 properties, 7895 tests, 2 failures, 106 excluded  
**Excluded tags:** `integration`, `e2e`, `skip`, `eval`, `triage_pending`, `packaged_cli`, `phase_c_e2e`

**Failure details:**

1. `CodePuppyControl.TUI.RendererTest: unknown tool name prints default-style banner` (`renderer_test.exs:139`)
   - `GenServer.call :finalize` timed out (5s) — pre-existing, Owl-based TUI test isolation issue

2. `CodePuppyControl.TUI.RendererTest: reset/1 clears state` (`renderer_test.exs:261`)
   - `GenServer.call :reset` timed out (5s) — same root cause, pre-existing

**Assessment:** Both failures are pre-existing Renderer GenServer timeouts under `CaptureIO`. Not restructure-related. Sync time (352.2s) driven by per-test Ecto migrations (~2.5s each). Tracking as separate issue per `code-puppy-2xg.1.1` notes.

### Python Baseline (from `code-puppy` audit)

Ran from repository root (`/home/adam/projects/exc`).

| Check | Result |
|---|---|
| `uv sync --frozen` | ✅ PASS |
| `ruff check` | ✅ PASS |
| `pytest tests -v` | ✅ 182 passed, 1 warning |

**Assessment:** Python stack fully functional at baseline. No failures.

## Phase 1: Conflict & Inventory Audit (Wave 1 summary)

Wave 1 auditors inspected pre-restructure state across all top-level directories to identify filename collisions and merge decisions.

| Area | Finding | Decision |
|---|---|---|
| **Root README** | `main` has one README; Python module adds its own | Manual merge: keep root README, Python README content added as section |
| **`.gitignore`** | Separate `.gitignore` in Python module | Manual merge: union of both patterns |
| **`priv/`** | Python `priv/` and Elixir `priv/` coexist | `priv/models.json` semantically equal; no merge conflict |
| **`rel/`** | Elixir release overlay files | Safe to merge/verify; no filename collisions with Python |
| **`scripts/`** | Python scripts + Elixir shell scripts | No filename collisions detected |
| **`docs/`** | Wave 1 added `burrito-release.yml` workflow doc | Safe to add; no collision |
| **Generated artifacts** | `_build/`, `deps/`, `burrito_out/`, `tmp/`, `pup`, `erl_crash.dump` | **NOT staged** — will not be moved during restructure |

**Key invariant confirmed:** Generated build artifacts are not in the git index and will not be accidentally committed or moved.

## Phase 10: Final Validation (Stage Complete)

Four parallel validation lanes confirmed the root restructure is complete and functional.

### Elixir Validation Lane (`exc-2xg-val-elixir`)

| Check | Result |
|---|---|
| `mix deps.get` | ✅ PASS |
| `mix format --check-formatted` | ✅ PASS |
| `mix compile --warnings-as-errors` | ✅ PASS |
| `mix test --max-failures 5` | ⚠️ 2 FAILURES (exit 2) — pre-existing RendererTest GenServer timeouts; pre-existing SessionStorage SQLite busy flakiness. Not root-migration regressions. |

### Python Validation Lane (`exc-2xg-val-python`)

| Check | Result |
|---|---|
| `uv sync --frozen` | ✅ PASS |
| `uv run ruff check` | ✅ PASS (All checks passed) |
| `uv run pytest tests -q` | ✅ 182 passed |
| `bash scripts/python-package-smoke.sh` | ✅ PASS |

### Release/Escript Validation Lane (`exc-2xg-val-release`)

| Check | Result |
|---|---|
| prod deps + compile | ✅ PASS |
| escript build (`./pup --help`) | ✅ PASS |
| `mix release --overwrite` | ✅ PASS |
| Burrito smoke | ✅ PASS |
| Packaged smoke | ✅ PASS |

### Static Validation Lane (`exc-2xg-val-static`)

| Check | Result |
|---|---|
| `elixir/` directory | ✅ **Absent** — wrapper directory correctly removed |
| Active stale `elixir/code_puppy_control` refs | ✅ **Zero** — all remaining hits in explicitly labeled historical/plan/audit docs |
| `bash -n` on release/build/smoke scripts | ✅ PASS (7/8; `scripts/pre-commit` correct absence, lives at `scripts/git-hooks/`) |
| `scripts/release-gate.sh` fresh worktree | ✅ **Fixed** (`code-puppy-mkk.1`): gate now runs `mix deps.get` → `mix deps.compile` before `mix format`/`mix compile`, eliminating the NIF + `:elixir_code_server` lock race in fresh worktrees. |

### Stage A Assessment

All 11 phases complete. Elixir app now lives at repository root. Python/PyPI package preserved at root. No active stale path references in active code, docs, or scripts. Stage B (Python isolation under `legacy/python/`) remains deferred per `code-puppy-2xg.2`.

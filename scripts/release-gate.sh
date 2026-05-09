#!/usr/bin/env bash
# release-gate.sh — local release quality gate for Code Puppy.
#
# This is intentionally boring: deterministic command order, explicit
# skip flags, no fixed temp log paths, and no live LLM credential checks.

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SKIP_PYTHON=false
SKIP_ELIXIR=false
WITH_BURRITO=false
PYTHON_DIST=false
RUN_INTEGRATION=false
RUN_E2E=false
FAILED=0
LAST_STATUS=0
SUMMARY=()

usage() {
  cat <<HELP
Code Puppy local release gate

Usage:
  ${SCRIPT_NAME} [options]

Default gates:
  Python:
    uv sync --frozen
    uv run ruff check code_puppy tests scripts
    uv run pytest tests

  Elixir (from repository root):
    mix deps.get
    mix deps.compile
    mix format --check-formatted
    mix compile --warnings-as-errors
    mix test
    mix pup_ex.smoke
    ./scripts/smoke-packaged.sh

Options:
  --skip-python    Skip Python dependency/lint/test gates
  --skip-elixir    Skip Elixir format/compile/test/smoke gates
  --with-burrito   Pass --with-burrito through to packaged smoke
  --python-dist    Also run Python package artifact smoke
                   (builds wheel, installs in temp venv, verifies entry points)
  --integration    Also run: mix test --only integration
  --e2e            Also run: mix test --only e2e
  --help, -h       Show this help

Notes:
  - This script does not require live LLM credentials.
  - Packaged Burrito smoke is opt-in because it depends on host Zig/Burrito tooling.
  - Python artifact smoke is opt-in because it builds/installs a wheel.
  - Use --skip-python --skip-elixir to validate argument parsing and summary output.
HELP
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf >&2 'WARNING: %s\n' "$*"
}

error() {
  printf >&2 'ERROR: %s\n' "$*"
}

section() {
  printf '\n────────────────────────────────────────────────────────────\n'
  printf '%s\n' "$*"
  printf '────────────────────────────────────────────────────────────\n'
}

find_repo_root() {
  local start_dir="$1"
  local root=""

  if root="$(git -C "$start_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$root"
    return 0
  fi

  local dir="$start_dir"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/pyproject.toml" && -f "$dir/mix.exs" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

record_result() {
  local name="$1"
  local status="$2"
  SUMMARY+=("${name}|${status}")
}

record_skip() {
  local name="$1"
  local reason="$2"
  record_result "$name" "SKIP (${reason})"
}

record_failure() {
  local name="$1"
  local reason="$2"
  FAILED=1
  record_result "$name" "FAIL (${reason})"
}

print_command() {
  local cwd="$1"
  shift

  printf 'cwd: %s\n' "$cwd"
  printf 'cmd:'
  printf ' %q' "$@"
  printf '\n'
}

run_step() {
  local name="$1"
  local cwd="$2"
  shift 2

  section "$name"
  print_command "$cwd" "$@"

  set +e
  (cd "$cwd" && "$@")
  LAST_STATUS=$?
  set -e

  if [[ "$LAST_STATUS" -eq 0 ]]; then
    info "PASS: ${name}"
    record_result "$name" "PASS"
  else
    warn "FAIL: ${name} (exit ${LAST_STATUS})"
    FAILED=1
    record_result "$name" "FAIL (exit ${LAST_STATUS})"
  fi
}

run_python_gate() {
  if [[ "$SKIP_PYTHON" == "true" ]]; then
    record_skip "Python gate" "--skip-python"
    return 0
  fi

  if [[ ! -f "$REPO_ROOT/pyproject.toml" ]]; then
    record_failure "Python gate" "pyproject.toml not found under ${REPO_ROOT}"
    return 0
  fi

  if ! command -v uv >/dev/null 2>&1; then
    record_failure "Python toolchain" "uv not found on PATH"
    record_skip "Python lint" "uv unavailable"
    record_skip "Python tests" "uv unavailable"
    return 0
  fi

  run_step "Python dependencies" "$REPO_ROOT" uv sync --frozen
  if [[ "$LAST_STATUS" -ne 0 ]]; then
    record_skip "Python lint" "uv sync failed"
    record_skip "Python tests" "uv sync failed"
    return 0
  fi

  run_step "Python lint" "$REPO_ROOT" uv run ruff check code_puppy tests scripts
  run_step "Python tests" "$REPO_ROOT" uv run pytest tests

  if [[ "$PYTHON_DIST" == "true" ]]; then
    local smoke_script="$REPO_ROOT/scripts/python-package-smoke.sh"
    if [[ -x "$smoke_script" ]]; then
      run_step "Python artifact smoke" "$REPO_ROOT" "$smoke_script"
    else
      record_failure "Python artifact smoke" "$smoke_script not found or not executable"
    fi
  fi
}

run_elixir_gate() {
  local elixir_dir="$REPO_ROOT"

  if [[ "$SKIP_ELIXIR" == "true" ]]; then
    record_skip "Elixir gate" "--skip-elixir"
    return 0
  fi

  if [[ ! -f "$elixir_dir/mix.exs" ]]; then
    record_failure "Elixir gate" "mix.exs not found under ${elixir_dir}"
    return 0
  fi

  if ! command -v mix >/dev/null 2>&1; then
    record_failure "Elixir toolchain" "mix not found on PATH"
    record_skip "Elixir dependencies" "mix unavailable"
    record_skip "Elixir deps compile" "mix unavailable"
    record_skip "Elixir format" "mix unavailable"
    record_skip "Elixir compile" "mix unavailable"
    record_skip "Elixir tests" "mix unavailable"
    record_skip "Elixir smoke" "mix unavailable"
    record_skip "Elixir packaged smoke" "mix unavailable"
    return 0
  fi

  # (code-puppy-mkk.1) Explicit dependency resolution and compilation
  # before format/compile gates. In a fresh worktree (no _build/ or deps/),
  # mix compile implicitly resolves+compiles deps, which races with
  # :elixir_code_server lock and parallel NIF compilation. Serializing
  # deps.get → deps.compile → compile eliminates the race. Both are
  # idempotent fast no-ops in already-built worktrees.
  run_step "Elixir dependencies" "$elixir_dir" mix deps.get
  if [[ "$LAST_STATUS" -ne 0 ]]; then
    record_skip "Elixir deps compile" "deps.get failed"
    record_skip "Elixir format" "deps.get failed"
    record_skip "Elixir compile" "deps.get failed"
    record_skip "Elixir tests" "deps.get failed"
    if [[ "$RUN_INTEGRATION" == "true" ]]; then
      record_skip "Elixir integration tests" "deps.get failed"
    fi
    if [[ "$RUN_E2E" == "true" ]]; then
      record_skip "Elixir e2e tests" "deps.get failed"
    fi
    record_skip "Elixir smoke" "deps.get failed"
    record_skip "Elixir packaged smoke" "deps.get failed"
    return 0
  fi

  run_step "Elixir deps compile" "$elixir_dir" mix deps.compile
  if [[ "$LAST_STATUS" -ne 0 ]]; then
    record_skip "Elixir format" "deps.compile failed"
    record_skip "Elixir compile" "deps.compile failed"
    record_skip "Elixir tests" "deps.compile failed"
    if [[ "$RUN_INTEGRATION" == "true" ]]; then
      record_skip "Elixir integration tests" "deps.compile failed"
    fi
    if [[ "$RUN_E2E" == "true" ]]; then
      record_skip "Elixir e2e tests" "deps.compile failed"
    fi
    record_skip "Elixir smoke" "deps.compile failed"
    record_skip "Elixir packaged smoke" "deps.compile failed"
    return 0
  fi

  run_step "Elixir format" "$elixir_dir" mix format --check-formatted
  run_step "Elixir compile" "$elixir_dir" mix compile --warnings-as-errors

  if [[ "$LAST_STATUS" -ne 0 ]]; then
    record_skip "Elixir tests" "compile failed"
    if [[ "$RUN_INTEGRATION" == "true" ]]; then
      record_skip "Elixir integration tests" "compile failed"
    fi
    if [[ "$RUN_E2E" == "true" ]]; then
      record_skip "Elixir e2e tests" "compile failed"
    fi
    record_skip "Elixir smoke" "compile failed"
    record_skip "Elixir packaged smoke" "compile failed"
    return 0
  fi

  run_step "Elixir tests" "$elixir_dir" mix test

  if [[ "$RUN_INTEGRATION" == "true" ]]; then
    run_step "Elixir integration tests" "$elixir_dir" mix test --only integration
  fi

  if [[ "$RUN_E2E" == "true" ]]; then
    run_step "Elixir e2e tests" "$elixir_dir" mix test --only e2e
  fi

  run_step "Elixir smoke" "$elixir_dir" mix pup_ex.smoke

  local packaged_args=("./scripts/smoke-packaged.sh")
  if [[ "$WITH_BURRITO" == "true" ]]; then
    packaged_args+=("--with-burrito")
  fi
  run_step "Elixir packaged smoke" "$elixir_dir" "${packaged_args[@]}"
}

print_summary() {
  local passed=0
  local failed=0
  local skipped=0
  local entry=""
  local name=""
  local status=""

  printf '\n════════════════════════════════════════════════════════════\n'
  printf 'Release gate summary\n'
  printf '════════════════════════════════════════════════════════════\n'

  for entry in "${SUMMARY[@]}"; do
    name="${entry%%|*}"
    status="${entry#*|}"

    case "$status" in
      PASS*) ((passed += 1)) ;;
      FAIL*) ((failed += 1)) ;;
      SKIP*) ((skipped += 1)) ;;
    esac

    printf '  %-32s %s\n' "$name" "$status"
  done

  printf '\nTotals: %s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"

  if [[ "$FAILED" -ne 0 ]]; then
    printf '\nRelease gate FAILED. Fix the angry bits above. 🐶\n' >&2
    return 1
  fi

  printf '\nRelease gate PASSED. Ship it carefully, not recklessly. 🐶\n'
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-python) SKIP_PYTHON=true; shift ;;
    --skip-elixir) SKIP_ELIXIR=true; shift ;;
    --with-burrito) WITH_BURRITO=true; shift ;;
    --python-dist) PYTHON_DIST=true; shift ;;
    --integration) RUN_INTEGRATION=true; shift ;;
    --e2e) RUN_E2E=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *)
      error "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! REPO_ROOT="$(find_repo_root "$SCRIPT_DIR")"; then
  error "Could not discover repository root from ${SCRIPT_DIR}"
  exit 2
fi

info "repo root: ${REPO_ROOT}"
run_python_gate
run_elixir_gate
print_summary

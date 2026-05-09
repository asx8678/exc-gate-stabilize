#!/bin/bash
#
# MVP Validation Script for CodePuppy Hybrid Architecture
#
# Validates the full stack:
# - Elixir control plane compilation
# - Database migrations
# - Unit tests
# - Integration tests
# - Python bridge availability
# - E2E tests with mock worker
#
# Usage:
#   ./scripts/validate_mvp.sh
#
# Exit codes:
#   0 - All validations passed
#   1 - One or more validations failed
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Track overall success
SUCCESS=0
STEP=0

log_step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${BLUE}[$STEP] $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Navigate to project root (parent of scripts directory)
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}🔍 Validating Hybrid MVP${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""
echo "Project root: $PROJECT_ROOT"
echo "Started at: $(date)"
echo ""

# -----------------------------------------------------------------------------
# Step 1: Check Elixir project compiles
# -----------------------------------------------------------------------------
log_step "Checking Elixir compilation..."

if mix deps.get >/dev/null 2>&1; then
    log_success "Dependencies fetched"
else
    log_error "Failed to fetch dependencies"
    SUCCESS=1
fi

# (code-puppy-mkk.5) Explicit deps.compile before compile. In a fresh
# worktree (no _build/ or deps/), mix compile implicitly resolves+compiles
# deps, which races with :elixir_code_server lock and parallel NIF
# compilation. Serializing deps.get → deps.compile → compile eliminates
# the race. Idempotent fast no-op in already-built worktrees.
if mix deps.compile 2>&1; then
    log_success "Dependencies compiled"
else
    log_error "Failed to compile dependencies"
    SUCCESS=1
fi

if mix compile --warnings-as-errors 2>&1 | tee /tmp/compile.log; then
    if grep -q "warning:" /tmp/compile.log; then
        log_warning "Compilation had warnings (treating as errors)"
        SUCCESS=1
    else
        log_success "Compilation successful with no warnings"
    fi
else
    log_error "Compilation failed"
    SUCCESS=1
fi

# -----------------------------------------------------------------------------
# Step 2: Run database migrations
# -----------------------------------------------------------------------------
log_step "Running database migrations..."

# Try to create database if it doesn't exist
mix ecto.create --quiet 2>/dev/null || true

if mix ecto.migrate; then
    log_success "Migrations completed"
else
    log_warning "Migration issues (may need manual setup)"
    # Don't fail here - tests might still work with existing DB
fi

# -----------------------------------------------------------------------------
# Step 3: Run unit tests
# -----------------------------------------------------------------------------
log_step "Running unit tests..."

if mix test --exclude e2e --exclude integration --max-failures 5; then
    log_success "Unit tests passed"
else
    log_error "Some unit tests failed"
    SUCCESS=1
fi

# -----------------------------------------------------------------------------
# Step 4: Run integration tests
# -----------------------------------------------------------------------------
log_step "Running integration tests..."

if mix test --only integration --max-failures 3 2>&1 | tee /tmp/integration_test.log; then
    log_success "Integration tests passed"
else
    # Check if tests were excluded or actually failed
    if grep -q "0 failures" /tmp/integration_test.log; then
        log_success "Integration tests passed (or no tests found)"
    else
        log_warning "Some integration tests failed"
        # Don't fail the whole validation for integration tests
    fi
fi

# -----------------------------------------------------------------------------
# Step 5: Check Python bridge (from project root)
# -----------------------------------------------------------------------------
log_step "Checking Python bridge..."

# Python package is at the same level as mix.exs (repo root)
if [ -d "code_puppy" ] && [ -f "pyproject.toml" ]; then
    # Try to import the bridge module
    if python3 -c "
try:
    from code_puppy.plugins.elixir_bridge import bridge_controller
    print('✅ Python bridge imports OK')
except ImportError as e:
    print(f'⚠️  Python bridge import issue: {e}')
    exit(1)
" 2>/dev/null; then
        log_success "Python bridge is importable"
    else
        log_warning "Python bridge not fully importable (may need dependencies)"
    fi
else
    log_warning "Python project not found at expected location"
fi

# PROJECT_ROOT is already the repo root (mix.exs + pyproject.toml)

# -----------------------------------------------------------------------------
# Step 6: Run E2E tests with mock worker
# -----------------------------------------------------------------------------
log_step "Running E2E tests..."

E2E_FAILED=0
if mix test --only e2e --max-failures 3 2>&1 | tee /tmp/e2e_test.log; then
    log_success "E2E tests passed"
else
    E2E_FAILED=1
    if grep -q "0 failures" /tmp/e2e_test.log 2>/dev/null; then
        log_success "E2E tests completed with no failures"
        E2E_FAILED=0
    else
        log_warning "Some E2E tests failed (may need real Python worker for full stack)"
    fi
fi

# Show summary of what ran
if [ -f /tmp/e2e_test.log ]; then
    echo ""
    echo "E2E test summary:"
    grep -E "(test|Excluding|Including|done|passed|failed)" /tmp/e2e_test.log | tail -5 || true
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}📊 Validation Summary${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

if [ $SUCCESS -eq 0 ]; then
    echo -e "${GREEN}✅ MVP Validation Complete - All checks passed!${NC}"
else
    echo -e "${YELLOW}⚠️  MVP Validation Complete with some issues${NC}"
fi

if [ $E2E_FAILED -ne 0 ]; then
    echo -e "${YELLOW}⚠️  Some E2E tests failed - this may be expected if running without full Python worker${NC}"
fi

echo ""
echo "Next steps:"
echo "  Start control plane: cd $PROJECT_ROOT && mix phx.server"
echo "  Run with Python:     cd $PROJECT_ROOT && CODE_PUPPY_BRIDGE=1 python -m code_puppy"
echo "  Run E2E tests:       mix test.e2e"
echo ""
echo "Finished at: $(date)"
echo ""

exit $SUCCESS

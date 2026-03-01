#!/usr/bin/env bash
# verify-on-stop.sh — Post-execution governance checks (enforce mode)
# Usage: bash scripts/verify-on-stop.sh [--pre-flight] [path/to/task-plan.yaml]
#
# Checks:
#   1. Output files exist as declared in task plan
#   2. No writes outside /workspace or repo root
#   3. Git working tree is clean after tasks
#   4. All tasks have a completed state in sidecar
#
# In enforce mode: blocks on any flag raised (exit 1).

set -euo pipefail

PLAN_FILE="${2:-plans/task-plan.yaml}"
PRE_FLIGHT=false
SIDECAR="http://localhost:3001"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
WARN_COUNT=0
FLAGS=()

if [[ "${1:-}" == "--pre-flight" ]]; then
  PRE_FLIGHT=true
fi

warn() {
  echo "  [BLOCK] $*"
  FLAGS+=("$*")
  (( WARN_COUNT++ )) || true
}

pass() {
  echo "  [PASS] $*"
}

echo ""
echo "══════════════════════════════════════════════════════"
if $PRE_FLIGHT; then
  echo "  VERIFY — PRE-FLIGHT"
else
  echo "  VERIFY — POST-EXECUTION"
fi
echo "══════════════════════════════════════════════════════"
echo ""

# ── Check 1: Sidecar reachable ────────────────────────────────────────────────
echo "[ Sidecar ]"
if curl -sf "$SIDECAR/health" > /dev/null 2>&1; then
  pass "Sidecar reachable at $SIDECAR"
else
  warn "Sidecar not reachable at $SIDECAR — state checks skipped"
fi
echo ""

if $PRE_FLIGHT; then
  # Pre-flight only needs sidecar check — enforce: block if sidecar unreachable
  if [[ $WARN_COUNT -gt 0 ]]; then
    echo "  RESULT: BLOCK — pre-flight failed (enforce mode — halting)"
    echo "══════════════════════════════════════════════════════"
    echo ""
    exit 1
  fi
  echo "Pre-flight complete."
  echo ""
  exit 0
fi

# ── Check 2: Task plan exists ─────────────────────────────────────────────────
echo "[ Task Plan ]"
if [[ ! -f "$PLAN_FILE" ]]; then
  warn "Task plan not found: $PLAN_FILE"
else
  pass "Task plan found: $PLAN_FILE"

  # ── Check 3: Output files exist as declared ───────────────────────────────
  echo ""
  echo "[ Output Files ]"
  while IFS= read -r line; do
    OUTPUT_PATH=$(echo "$line" | sed 's/.*output:[[:space:]]*//' | tr -d '"' | tr -d "'")
    if [[ "$OUTPUT_PATH" =~ ^[./a-zA-Z0-9_-]+$ ]]; then
      if [[ -f "$REPO_ROOT/$OUTPUT_PATH" ]]; then
        pass "Output exists: $OUTPUT_PATH"
      else
        warn "Output missing: $OUTPUT_PATH"
      fi
    fi
  done < <(grep "output:" "$PLAN_FILE" || true)
fi
echo ""

# ── Check 4: All tasks completed in sidecar ───────────────────────────────────
echo "[ Sidecar Task States ]"
if curl -sf "$SIDECAR/health" > /dev/null 2>&1; then
  AGENTS=$(curl -sf "$SIDECAR/agents" 2>/dev/null || echo "[]")
  if echo "$AGENTS" | grep -q '"status"'; then
    if echo "$AGENTS" | grep -qE '"status":\s*"(running|spawning)"'; then
      warn "One or more tasks still running or spawning in sidecar"
    else
      pass "All registered tasks in terminal state"
    fi
  else
    warn "No agents found in sidecar — nothing to verify"
  fi
fi
echo ""

# ── Check 5: No writes outside repo root ─────────────────────────────────────
echo "[ Write Boundary ]"
RECENT_WRITES=$(find /tmp -newer "$PLAN_FILE" -type f 2>/dev/null | head -5 || true)
if [[ -n "$RECENT_WRITES" ]]; then
  warn "Files written to /tmp during execution — review: $RECENT_WRITES"
else
  pass "No unexpected writes to /tmp detected"
fi
echo ""

# ── Check 6: Git working tree clean ──────────────────────────────────────────
echo "[ Git State ]"
cd "$REPO_ROOT"
UNTRACKED=$(git status --porcelain 2>/dev/null || echo "")
if [[ -z "$UNTRACKED" ]]; then
  pass "Git working tree clean"
else
  CHANGED_COUNT=$(echo "$UNTRACKED" | wc -l)
  warn "Git working tree has ${CHANGED_COUNT} uncommitted change(s) — review before proceeding"
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
if [[ $WARN_COUNT -eq 0 ]]; then
  echo "  RESULT: PASS — no governance flags raised"
  echo "══════════════════════════════════════════════════════"
  echo ""
  exit 0
else
  echo "  RESULT: BLOCK — ${WARN_COUNT} flag(s) raised (enforce mode — halting)"
  echo ""
  for FLAG in "${FLAGS[@]}"; do
    echo "    ✗  $FLAG"
  done
  echo "══════════════════════════════════════════════════════"
  echo ""
  exit 1
fi

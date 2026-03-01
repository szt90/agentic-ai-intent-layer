#!/usr/bin/env bash
# verify-on-stop.sh — Post-execution governance checks (enforce mode)
# Usage: bash scripts/verify-on-stop.sh [--pre-flight] [path/to/task-plan.yaml]
#
# Checks:
#   1. Output files exist as declared in task plan
#   2. No writes outside /workspace or repo root
#   3. Git working tree is clean after tasks (excluding declared outputs)
#   4. All tasks have a completed state in sidecar
#
# In enforce mode: blocks on any flag raised (exit 1).
#
# v2 changes:
#   - Check 5: /tmp scan now ignores Claude Code internal files; only flags
#     repo-like file types (.yaml .json .md .txt .sh .py .ts .js)
#   - Check 6: Declared output paths from task plan are excluded from the
#     uncommitted file check — these are expected post-run state

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

info() {
  echo "  [INFO] $*"
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

# Collect declared output paths for use in Check 6
DECLARED_OUTPUTS=()

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
      DECLARED_OUTPUTS+=("$OUTPUT_PATH")
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
# Only flag repo-like file types; ignore Claude Code internals in /tmp
echo "[ Write Boundary ]"
REPO_LIKE_PATTERN="\.(yaml|yml|json|md|txt|sh|py|ts|js|tsx|jsx)$"
RECENT_WRITES=$(find /tmp -newer "$PLAN_FILE" -type f 2>/dev/null \
  | grep -E "$REPO_LIKE_PATTERN" \
  | grep -v "claude" \
  | head -5 || true)
if [[ -n "$RECENT_WRITES" ]]; then
  warn "Repo-like files written to /tmp during execution — review: $RECENT_WRITES"
else
  pass "No unexpected writes to /tmp detected"
fi
echo ""

# ── Check 6: Git working tree clean (excluding declared outputs) ──────────────
echo "[ Git State ]"
cd "$REPO_ROOT"
RAW_STATUS=$(git status --porcelain 2>/dev/null || echo "")

if [[ -z "$RAW_STATUS" ]]; then
  pass "Git working tree clean"
else
  # Filter out declared output paths — these are expected post-run
  UNEXPECTED=""
  while IFS= read -r status_line; do
    FILE_PATH=$(echo "$status_line" | awk '{print $2}')
    IS_DECLARED=false
    for DECLARED in "${DECLARED_OUTPUTS[@]:-}"; do
      if [[ "$FILE_PATH" == "$DECLARED" || "$FILE_PATH" == "./$DECLARED" ]]; then
        IS_DECLARED=true
        break
      fi
    done
    if ! $IS_DECLARED; then
      UNEXPECTED+="$status_line"$'\n'
    fi
  done <<< "$RAW_STATUS"

  DECLARED_COUNT=$(( ${#DECLARED_OUTPUTS[@]} ))
  DECLARED_UNCOMMITTED=$(git status --porcelain 2>/dev/null \
    | awk '{print $2}' \
    | grep -Ff <(printf '%s\n' "${DECLARED_OUTPUTS[@]:-}" | grep .) \
    2>/dev/null | wc -l || echo 0)

  if [[ -z "${UNEXPECTED// }" ]]; then
    pass "Git working tree clean (${DECLARED_UNCOMMITTED} declared output(s) uncommitted — expected post-run)"
    if [[ $DECLARED_UNCOMMITTED -gt 0 ]]; then
      info "Uncommitted declared outputs: ${DECLARED_OUTPUTS[*]:-}"
      info "Commit these when ready: git add <outputs> && git commit -m 'chore: add task outputs'"
    fi
  else
    UNEXPECTED_COUNT=$(echo "$UNEXPECTED" | grep -c . || true)
    warn "Git working tree has ${UNEXPECTED_COUNT} unexpected uncommitted change(s) — review before proceeding"
    echo "$UNEXPECTED" | while IFS= read -r line; do
      [[ -n "$line" ]] && echo "    → $line"
    done
  fi
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

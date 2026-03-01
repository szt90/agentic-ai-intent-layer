#!/usr/bin/env bash
# protect-files.sh — File protection governance hook (audit mode)
# Usage: bash scripts/protect-files.sh [path/to/task-plan.yaml]
#
# Protection model:
#   BLOCKLIST — critical files that must never be modified by agents
#   ALLOWLIST — only declared task output paths are permitted write targets
#
# Compares git diff against both lists. In audit mode: warns, does not block.

set -euo pipefail

PLAN_FILE="${1:-plans/task-plan.yaml}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
WARN_COUNT=0
FLAGS=()

warn() {
  echo "  [WARN] $*"
  FLAGS+=("$*")
  (( WARN_COUNT++ )) || true
}

pass() {
  echo "  [PASS] $*"
}

# ── Blocklist — never modified by agents ─────────────────────────────────────
BLOCKLIST=(
  ".env"
  ".env.*"
  "*.approved"
  "*.rejected"
  ".claude/settings.json"
  "scripts/protect-files.sh"
  "scripts/verify-on-stop.sh"
  "scripts/review-plan.sh"
  "docs/architecture/ADR-*.yaml"
  ".gitignore"
  "bootstrap.sh"
  "CLAUDE.md"
)

echo ""
echo "══════════════════════════════════════════════════════"
echo "  PROTECT-FILES — GOVERNANCE CHECK"
echo "══════════════════════════════════════════════════════"
echo ""

cd "$REPO_ROOT"

# Get files changed since last commit
CHANGED_FILES=$(git diff --name-only HEAD 2>/dev/null || true)
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
ALL_CHANGED=$(printf "%s\n%s" "$CHANGED_FILES" "$STAGED_FILES" | sort -u | grep -v '^$' || true)

if [[ -z "$ALL_CHANGED" ]]; then
  pass "No changed files to check"
  echo ""
else
  # ── Blocklist check ─────────────────────────────────────────────────────────
  echo "[ Blocklist Check ]"
  BLOCKLIST_HIT=false
  while IFS= read -r file; do
    for pattern in "${BLOCKLIST[@]}"; do
      # shellcheck disable=SC2254
      case "$file" in
        $pattern)
          warn "BLOCKLIST HIT: $file matches protected pattern '$pattern'"
          BLOCKLIST_HIT=true
          ;;
      esac
    done
  done <<< "$ALL_CHANGED"
  if ! $BLOCKLIST_HIT; then
    pass "No blocklist violations"
  fi
  echo ""

  # ── Allowlist check ─────────────────────────────────────────────────────────
  echo "[ Allowlist Check ]"
  if [[ ! -f "$PLAN_FILE" ]]; then
    warn "Task plan not found — cannot verify allowlist: $PLAN_FILE"
  else
    # Extract declared output paths from task plan
    ALLOWED_OUTPUTS=()
    while IFS= read -r line; do
      OUTPUT_PATH=$(echo "$line" | sed 's/.*output:[[:space:]]*//' | tr -d '"' | tr -d "'")
      if [[ "$OUTPUT_PATH" =~ ^[./a-zA-Z0-9_-]+$ ]]; then
        ALLOWED_OUTPUTS+=("$OUTPUT_PATH")
      fi
    done < <(grep "output:" "$PLAN_FILE" || true)

    # Always allow plans/ and intents/ directories (planner outputs)
    ALLOWED_PREFIXES=("plans/" "intents/")

    ALLOWLIST_VIOLATION=false
    while IFS= read -r file; do
      PERMITTED=false

      # Check declared outputs
      for allowed in "${ALLOWED_OUTPUTS[@]}"; do
        if [[ "$file" == "$allowed" || "$file" == "$allowed"* ]]; then
          PERMITTED=true
          break
        fi
      done

      # Check always-allowed prefixes
      if ! $PERMITTED; then
        for prefix in "${ALLOWED_PREFIXES[@]}"; do
          if [[ "$file" == "$prefix"* ]]; then
            PERMITTED=true
            break
          fi
        done
      fi

      if ! $PERMITTED; then
        warn "ALLOWLIST: $file not declared as a task output"
        ALLOWLIST_VIOLATION=true
      fi
    done <<< "$ALL_CHANGED"

    if ! $ALLOWLIST_VIOLATION; then
      pass "All changed files are within declared output paths"
    fi
  fi
  echo ""
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo "══════════════════════════════════════════════════════"
if [[ $WARN_COUNT -eq 0 ]]; then
  echo "  RESULT: PASS — no protection violations"
else
  echo "  RESULT: WARN — ${WARN_COUNT} violation(s) found (audit mode — not blocking)"
  echo ""
  for FLAG in "${FLAGS[@]}"; do
    echo "    ⚠  $FLAG"
  done
fi
echo "══════════════════════════════════════════════════════"
echo ""

# Audit mode: always exit 0
exit 0

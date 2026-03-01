#!/usr/bin/env bash
# review-plan.sh — Human gate for task plan approval
# Usage: bash scripts/review-plan.sh [path/to/task-plan.yaml]

set -euo pipefail

PLAN_FILE="${1:-plans/task-plan.yaml}"

if [[ ! -f "$PLAN_FILE" ]]; then
  echo "ERROR: Plan file not found: $PLAN_FILE"
  exit 1
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "  TASK PLAN REVIEW"
echo "══════════════════════════════════════════════════════"
echo ""
echo "File: $PLAN_FILE"
echo ""
cat "$PLAN_FILE"
echo ""
echo "══════════════════════════════════════════════════════"
echo ""

read -rp "Approve this plan? [y/N/reject]: " RESPONSE

case "$RESPONSE" in
  y|Y|yes|YES)
    APPROVED_BY="${USER:-unknown}"
    REVIEWED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    APPROVAL_FILE="${PLAN_FILE%.yaml}.approved"
    printf "approved_by: %s\nreviewed_at: %s\nplan_file: %s\n" \
      "$APPROVED_BY" "$REVIEWED_AT" "$PLAN_FILE" > "$APPROVAL_FILE"
    echo ""
    echo "✅ Plan approved by ${APPROVED_BY} at ${REVIEWED_AT}"
    echo "   Approval recorded at: ${APPROVAL_FILE}"
    echo ""
    ;;
  reject|REJECT|n|N|no|NO)
    echo ""
    read -rp "Rejection reason (will be passed to planner): " REASON
    REJECTION_FILE="${PLAN_FILE%.yaml}.rejected"
    printf "rejected_by: %s\nrejected_at: %s\nreason: \"%s\"\n" \
      "${USER:-unknown}" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$REASON" > "$REJECTION_FILE"
    echo ""
    echo "❌ Plan rejected. Reason recorded at: ${REJECTION_FILE}"
    echo "   Re-run the planner agent with this rejection file as revision notes."
    echo ""
    exit 2
    ;;
  *)
    echo ""
    echo "⚠️  No decision recorded. Plan remains unapproved."
    echo ""
    exit 1
    ;;
esac

# agentic-ai-intent-layer

This repo is the intent layer for the agentic AI template project. It introduces
structured intent as the mandatory entry point for all agentic work, with a
planner-orchestrator pattern that separates planning from execution.

---

## How to use this repo

### The full workflow

```
1. Draft IntentSpec in chat
       ↓
2. Iterate with Claude until spec_mode: approved
       ↓
3. Submit to planner agent
       ↓
4. Review task plan (review-plan.sh)
       ↓
5. Orchestrator executes
       ↓
6. Lifecycle hooks run (verify-on-stop, protect-files)
```

No task plan is produced without an approved IntentSpec.
No orchestration runs without human approval of the task plan.

---

## Step 1 — Draft your IntentSpec

Copy the template and fill it in:

```bash
cp intents/intent-template.yaml intents/intent-my-task.yaml
```

Open it and fill in all required fields:
- `goal` — one paragraph describing the desired end state
- `success_criteria` — falsifiable conditions you can verify
- `constraints` — hard limits the planner must not violate
- `out_of_scope` — explicitly name what this intent does NOT cover

Set `spec_mode: draft` while iterating.

---

## Step 2 — Iterate with Claude in chat

Paste your IntentSpec into a Claude chat and ask:

> "Review this IntentSpec. Is the goal clear and unambiguous? Are the constraints
> sufficient? Are the success criteria falsifiable? What's missing?"

Iterate until Claude confirms the spec is ready. Then set `spec_mode: approved`.

**The planner agent must never receive a draft spec.**

---

## Step 3 — Run the planner agent

```bash
claude -p "Read intents/intent-my-task.yaml and produce a task plan at plans/task-plan.yaml" \
  --dangerously-skip-permissions
```

The planner will write `plans/task-plan.yaml`. It will:
- Break the intent into tasks (one task = one verifiable output)
- Set runtime per ADR-004 (claude-code default, docker for high-risk)
- Leave all governance fields absent

If the planner outputs `PLAN BLOCKED:` — revise the IntentSpec and retry.

---

## Step 4 — Review the task plan

```bash
bash scripts/review-plan.sh plans/task-plan.yaml
```

This shows the full plan and asks for approval. On approval it writes
`plans/task-plan.approved`. On rejection it writes `plans/task-plan.rejected`
with your reason — re-run the planner with the rejection file as revision notes.

---

## Step 5 — Run the orchestrator

```bash
claude -p "Read plans/task-plan.yaml and execute it" \
  --dangerously-skip-permissions
```

The orchestrator will:
- Verify the sidecar is reachable (`http://localhost:3001`)
- Check for a `.approved` marker — halt if absent
- Dispatch tasks in dependency order
- Register each task with the state sidecar via MCP
- Run lifecycle hooks on completion

**Start the state sidecar first:**

```bash
cd ~/agentic-ai-state-layer && npm start
```

---

## Step 6 — Lifecycle hooks

The orchestrator calls these automatically. You can also run them manually:

```bash
# Pre-flight check
bash scripts/verify-on-stop.sh --pre-flight

# Post-execution check
bash scripts/verify-on-stop.sh plans/task-plan.yaml

# File protection check
bash scripts/protect-files.sh plans/task-plan.yaml
```

Both hooks run in **audit mode** — they log warnings but do not block execution.
To enable enforce mode, set `governance_modes.enforce.active: true` in
`docs/architecture/ADR-006-task-schema.yaml` and update the hook exit codes.

---

## Repo structure

```
.claude/
  agents/
    planner.md          # Planner subagent — reads IntentSpec, writes task plan
    orchestrator.md     # Orchestrator v2 — executes task plan
  settings.json         # bypassPermissions + MCP server registration

intents/
  intent-template.yaml            # Copy this to start a new intent
  intent-phase7-dogfood.yaml      # Worked example — approved IntentSpec

plans/
  task-plan-phase7-dogfood.yaml   # Worked example — task plan
  task-plan-phase7-dogfood.approved

scripts/
  review-plan.sh        # Human gate — inspect and approve task plan
  verify-on-stop.sh     # Post-execution governance checks
  protect-files.sh      # Blocklist + allowlist file protection

docs/architecture/
  ADR-006-task-schema.yaml        # Canonical task plan schema
```

---

## Architecture decisions

| ADR | Decision |
|-----|----------|
| ADR-004 | Claude Code is default runtime. Docker for network:true or high/critical risk. |
| ADR-005 | IntentSpec is mandatory. No task plan without approved spec. |
| ADR-006 | One task = one verifiable output. Governance fields populated by hooks only. |

---

## Dependencies

- [agentic-ai-state-layer](https://github.com/szt90/agentic-ai-state-layer) — state sidecar must be running on `:3001`
- [agentic-ai-template](https://github.com/szt90/agentic-ai-template) — base template this repo extends
- Claude Code installed and authenticated (`claude /login`)

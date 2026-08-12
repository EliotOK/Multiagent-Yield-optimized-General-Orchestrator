---
name: research-multiagent-orchestrator
description: Route and supervise scientific coding work across a primary Sol reviewer, DeepSeek V4 Flash long-context workers, and tiered Luna medium/high/max coding workers. Use when Codex must inspect a large R/Python/GIS repository, reconstruct data lineage, audit schemas or variables, process long logs, make bounded repetitive edits, debug a difficult localized failure, tune worker latency, or install, verify, repair, and operate this planner-worker-reviewer workflow.
---

# Research Multi-Agent Orchestrator

Keep the primary agent responsible for task interpretation, scientific judgment,
architecture, acceptance criteria, final diff review, validation, and integration.
Delegate only bounded investigation or implementation.

## Select a route

Read [routing-policy.md](references/routing-policy.md), then classify the task by:

1. context breadth;
2. reasoning density;
3. scientific or destructive risk;
4. write scope.

Use these defaults:

- Use `deepseek_context_worker` at low reasoning for broad but straightforward
  repository maps, inventories, metadata extraction, and long-log reduction.
- Use `deepseek_context_reasoning_worker` at high reasoning for data lineage,
  R-pipeline tracing, cross-file schema or variable audits, and complex diagnosis.
- Use `deepseek_batch_worker` for approved, repetitive edits across many files.
- Use `luna_medium_worker` by default for clear bounded coding, focused fixes, and
  tests whose useful work is likely to exceed the subagent startup cost.
- Use `luna_high_worker` for complex localized debugging, tricky refactors,
  integrations, algorithms, or difficult test failures.
- Use `luna_max_worker` only for the hardest quality-first tasks after high effort
  is insufficient or the acceptance risk explicitly justifies maximum reasoning.
- Keep scientific decisions and final review with the primary agent.
- Do not delegate a trivial edit when coordination costs more than the work.

## Check installation

Before the first delegated task in a project, run:

```powershell
powershell -ExecutionPolicy Bypass -File <skill>/scripts/verify-workflow.ps1 -ProjectRoot <root>
```

If installation is missing and the user explicitly requests installation, preview:

```powershell
powershell -ExecutionPolicy Bypass -File <skill>/scripts/install-workflow.ps1 -ProjectRoot <root>
```

Review the preview, then rerun with `-Apply`. Never put an API key in a file or
command argument. Require `DEEPSEEK_API_KEY` through the environment.

If the key is unavailable or existing instructions suspend DeepSeek, pass
`-LunaOnly` to installation and verification. This must skip the DeepSeek provider
and workers, install Luna/Terra routing, and record `deepseek_enabled = false` in
the project descriptor. If user-level Codex changes are not authorized, also pass
`-ProjectOnly`; modify only the project and do not touch `config.toml`, the global
agents directory, or global `AGENTS.md`. Project-only mode requires suitable Luna
agents to be configured independently at user level. Never ask the user to relax a
DeepSeek suspension merely to run MYGO.

## Delegate safely

Read [task-protocol.md](references/task-protocol.md) before spawning a worker.
Inspect repository status and relevant project instructions first.

Create an immutable task and binding with `scripts/create-task.ps1`. Supply the
generated task ID, absolute task path, binding path, SHA-256, canonical root, and
expected timing in the spawn message. Use a no-history fork for a custom agent.
Use the script's ready-to-send spawn payload verbatim. When it contains all binding
fields, require the worker to read task and binding together and skip descriptor
discovery, task-directory scans, a separate plan, and a separate acknowledgement.

Keep small inventories and one-file reads with the primary agent. Delegate to the
fast DeepSeek context worker only when the context volume can amortize agent startup.
Keep a clear coding task with the primary agent when it can likely be completed in
about one minute and isolation, parallelism, or specialist reasoning adds no value.

Allow at most one write-capable worker at a time. A read-only context worker may
run alongside it only when their responsibilities do not overlap semantically.
Never let DeepSeek and Luna modify the same task concurrently.

Use dynamic observation windows. Treat the first observation point as a status
check, not a failure. Extend the wait when messages, files, process activity,
stdout, or state records show progress. Diagnose only after two observation
windows with no progress.

Read [fallback-policy.md](references/fallback-policy.md) before changing workers.
Never switch because of elapsed time alone. Require hard-stop evidence, confirm
that no process can still write, and create a new immutable task for a fallback.

## Review and finish

Inspect every changed file and the complete diff. Independently run proportionate
validation. Apply [scientific-invariants.md](references/scientific-invariants.md)
for R, GIS, ecological data, Bash, and Python tasks.

Do not delete task or binding files while an agent remains running or while an
external process may still write. After the result is collected, the agent is
completed, and validation finishes, mark the state `REVIEWED` and remove or archive
temporary coordination files according to project policy.

Prefer recoverable archival with `scripts/close-task.ps1`. Preview first, confirm
the worker and child processes are stopped, then rerun with `-ConfirmWorkerStopped
-Apply`. Do not close a task merely because its chat state is delayed.

Report the selected route, delegated work, evidence returned, primary-agent
verification, and remaining risks.

## Diagnose failures

Classify a failure as one of:

- provider/API;
- agent creation or initialization;
- initial-message or binding delivery;
- tool scheduling;
- external command/runtime;
- sandbox or approval;
- state-return delay;
- binding lifecycle;
- unknown.

Attribute failure to the model provider only when API, HTTP, authentication,
rate-limit, or provider-side evidence supports it.

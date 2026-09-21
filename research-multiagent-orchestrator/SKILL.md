---
name: research-multiagent-orchestrator
description: MYGO routes and supervises scientific coding through the current-session model as primary, with optional known-profile aliases such as Astra or Sol, DeepSeek V4.1 Flash long-context workers, tiered Luna coding workers, and read-only cross-reviewers. Use when Codex must inspect a large R/Python/GIS repository, reconstruct data lineage, audit schemas or variables, process long logs, make bounded repetitive edits, debug a difficult localized failure, tune worker latency, or install, verify, repair, and operate this planner-worker-reviewer workflow.
---

# Research Multi-Agent Orchestrator

Keep exactly one primary agent responsible for task interpretation, scientific
judgment, architecture, acceptance criteria, final diff review, validation, and
integration. Delegate only bounded investigation, implementation, or advisory
review.

## Resolve the current primary

Read [primary-profiles.md](references/primary-profiles.md) before any delegation.
Read [model-map.md](references/model-map.md) when selecting or changing models,
reasoning effort, providers, or worker codenames. Resolve the project's
`.codex/mygo-model-map.json` before delegation. The shipped
`default_primary=CURRENT` means the active composer model is authoritative. Before
every delegated task, run `scripts/resolve-primary-profile.ps1`; it returns a known
profile alias when the model map contains one, otherwise it returns the neutral
`CURRENT` profile with the exact observed model and reasoning effort. Do not ask the
user to choose a logical primary profile.

The resolver reads only model metadata associated with `CODEX_THREAD_ID`; it never
returns conversation content. Treat its session-file format as a compatibility
adapter rather than a stable public API. If thread metadata or the model identity is
unavailable, do not dispatch. A readable but unmapped model is valid and becomes the
`CURRENT` primary. Re-resolve before each delegation so a composer-model change takes
effect immediately.

The shipped mappings are Astra at medium and Sol at high, but they are advisory
aliases rather than an allow-list. A different observed effort is recorded and the
current model remains primary. Only the resolved primary may dispatch write-capable
workers, modify or integrate code, and accept the result. The Astra/Sol reviewer
workers are available only for their corresponding known opposite profiles; an
unmapped current model uses no profile-specific reviewer. Never use a reviewer as a
second controller.

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
- Use `terra_readonly_fallback_worker` to reconstruct evidence after a diagnosed
  failure without workspace writes. Use `terra_fallback_worker` only when a new
  bounded recovery task genuinely requires writes.
- Keep scientific decisions and final review with the resolved current primary.
- Use `astra_review_worker` only in a known Sol-primary session for an explicit or
  high-risk second opinion. It is medium-reasoning, read-only, and single-pass by
  default.
- Use `sol_review_worker` only in a known Astra-primary session for an explicit or
  high-risk second opinion. It is read-only and advisory.
- Do not delegate a trivial edit when coordination costs more than the work.

Treat DeepSeek as an external data recipient. Default every task to `LOCAL_ONLY`.
Create a DeepSeek task only after the user or applicable data policy permits the
selected context to leave the Codex/OpenAI environment; set `DataSensitivity` to
`APPROVED_EXTERNAL` or `PUBLIC` explicitly. Never send credentials, participant
data, unpublished restricted data, or contractual/confidential material by default.

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
command argument. Require `DEEPSEEK_API_KEY` through the environment. When it is
missing, do not ask for it in chat. Instruct the user to run
`scripts/set-deepseek-key.ps1` in their own interactive PowerShell terminal. The
script hides input and never prints the value; it stores the key as a Windows user
environment variable, which is not an encrypted secret vault. Require a complete
Codex restart afterward. Full-mode apply must stop before writing when the key is
missing unless the user explicitly selects `-LunaOnly`.

If the key is unavailable or existing instructions suspend DeepSeek, pass
`-LunaOnly` to installation and verification. This must skip the DeepSeek provider
and workers, install Luna/Terra routing, and record `deepseek_enabled = false` in
the project descriptor. If user-level Codex changes are not authorized, also pass
`-ProjectOnly`; modify only the project and do not touch `config.toml`, the global
agents directory, or global `AGENTS.md`. Project-only changes scope, not routing:
it requires every selected user-level worker and provider to be present already and
validates them read-only. Never ask the user to relax a DeepSeek suspension merely
to run MYGO.

## Delegate safely

Read [task-protocol.md](references/task-protocol.md) before spawning a worker.
Inspect repository status and relevant project instructions first.

Create an immutable task and binding with `scripts/create-task.ps1`; its default
`-PrimaryProfile AUTO` resolves and verifies the current composer automatically.
Use explicit `-ObservedPrimaryModel` and `-ObservedPrimaryEffort` only for an
already observed runtime value or an isolated test, never to simulate another
primary. Include a concise English `-TaskLabel` that describes the work. Before task creation, ensure the label is
unique among child tasks in the current conversation; use a readable sequence such
as `schema audit 2` only when needed. Supply the
generated task ID, absolute task path, binding path, SHA-256, canonical root, and
expected timing in the spawn message. Use a no-history fork for a custom agent.
Use the script's ready-to-send spawn payload verbatim, including its codename-based
semantic `task_name`, such as `anon_schema_audit`. Keep the random task-ID suffix
only in coordination artifacts; never use it as the child task name. When the
payload contains all binding
fields, require the worker to read task and binding together and skip descriptor
discovery, task-directory scans, a separate plan, and a separate acknowledgement.

Keep small inventories and one-file reads with the primary agent. Delegate to the
fast DeepSeek context worker only when the context volume can amortize agent startup.
Keep a clear coding task with the primary agent when it can likely be completed in
about one minute and isolation, parallelism, or specialist reasoning adds no value.

Run at most one delegated worker at a time. The immutable binding protocol is
strictly serial and does not claim semantic isolation for concurrent workers.
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
external process may still write. After the result is collected and the agent is
completed, transition state with `scripts/update-task-state.ps1`. After independent
validation finishes, archive as `REVIEWED`; never edit state JSON manually.

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

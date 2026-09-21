# Immutable task and state protocol

## Required artifacts

Use one unique task ID per delegation:

```text
.codex/tasks/<task-id>.md
.codex/bindings/<task-id>.json
work/worker_state/<task-id>.json
```

Never overwrite or reuse an active task. Never use the legacy singleton
`.codex/deepseek-worker-task.md`.

## Lifecycle

```text
DISPATCHED -> AGENT_CREATED -> TASK_ACKNOWLEDGED -> TOOL_STARTED
-> RUNNING -> OUTPUT_READY -> AGENT_COMPLETED -> REVIEWED
```

The parent creates `DISPATCHED` and records parent-observed transitions for a
read-only worker, which cannot write heartbeats. A write-capable worker may update
`TASK_ACKNOWLEDGED` through `OUTPUT_READY`. All actors must use
`scripts/update-task-state.ps1`; direct JSON editing is invalid. `REVIEWED` is an
archive outcome written by `close-task.ps1`, not an active state transition.
For latency diagnosis, record dispatch, agent-created, first-tool, last-tool,
output-received, and agent-completed times without adding acknowledgement turns.

## Binding rules

Bind a worker to the task ID, canonical root, absolute task path, stable worker role,
display codename, concise task label, current-session primary profile, observed
primary model and reasoning effort, resolution source, and task SHA-256.
Put every field in the spawn message. Use a semantic child name in the form
`codename_task_description`, such as `anon_schema_audit`, while keeping the stable
worker role for routing and audit. The child API accepts lowercase letters, numbers,
and underscores, so the script normalizes the human-readable display form
`Anon — schema audit`. Keep the random task-ID suffix out of the child name. If a
semantic name already exists in the conversation, choose a readable numbered label
before task creation, such as `schema audit 2`.
Resolve the active composer before task creation. Use a known `ASTRA` or `SOL` alias
when available, otherwise use `CURRENT`; never use a user-selected logical primary.
Read task and binding together
in the first tool call; skip the project descriptor and directory discovery when
the message is complete. Check once before the first write and once before return.
Do not repeat hashes, Git status, and path checks before every command.

Only if the initial spawn message is incomplete, read the project descriptor and
accept exactly one `READY` binding
whose `worker_name` matches the current agent. Stop on zero, multiple, changed,
missing, outside-root, or hash-mismatched bindings.

`astra_review_worker` requires `primary_profile=SOL`; `sol_review_worker` requires
`primary_profile=ASTRA`. Both require `READ_ONLY` mode. A mismatch is a hard stop.

## Waiting

Record expected duration and first observation point in every task. Choose the wait
budget from the largest of parent estimate, worker estimate, historical duration,
and input-size allowance. Extend the wait on any progress signal. After two silent
windows, inspect provider errors, agent state, processes, stdout, artifacts,
permissions, and binding state before deciding that execution failed.

## Return contract

Require:

- task ID and binding verification;
- files inspected and changed;
- commands and exit codes;
- tests and results;
- elapsed time;
- unresolved risks and primary-agent decisions;
- explicit `COMPLETE`, `FAILED`, or `BLOCKED` status.

After the primary agent collects and reviews the result, transition through
`OUTPUT_READY` to `AGENT_COMPLETED`, then use `scripts/close-task.ps1 -Outcome
REVIEWED` to archive the task, binding, and state together. Failed outcomes require
the matching terminal active state. Require explicit confirmation that the worker
and child processes are stopped. Archival clears the active binding while preserving
evidence for fallback diagnosis.

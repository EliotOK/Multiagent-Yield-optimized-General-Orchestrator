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

The parent owns `DISPATCHED`, `AGENT_CREATED`, and final `REVIEWED`. A read-only
worker cannot write heartbeats, so the parent records observations for that route.
A write-capable worker may update `TASK_ACKNOWLEDGED` through `OUTPUT_READY`.
For latency diagnosis, record dispatch, agent-created, first-tool, last-tool,
output-received, and agent-completed times without adding acknowledgement turns.

## Binding rules

Bind a worker to the task ID, canonical root, absolute task path, worker name, and
task SHA-256. Put every field in the spawn message. Read task and binding together
in the first tool call; skip the project descriptor and directory discovery when
the message is complete. Check once before the first write and once before return.
Do not repeat hashes, Git status, and path checks before every command.

Only if the initial spawn message is incomplete, read the project descriptor and
accept exactly one `READY` binding
whose `worker_name` matches the current agent. Stop on zero, multiple, changed,
missing, outside-root, or hash-mismatched bindings.

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

After the primary agent collects and reviews the result, use `scripts/close-task.ps1`
to archive the task, binding, and state together. Require explicit confirmation that
the worker and child processes are stopped. Archival clears the active binding while
preserving evidence for fallback diagnosis.

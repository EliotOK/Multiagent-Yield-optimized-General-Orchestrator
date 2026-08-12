<!-- research-multiagent-orchestrator-global:start -->
# Planner-worker-reviewer workflow

The primary Codex agent owns task interpretation, scientific assumptions,
architecture, decomposition, acceptance criteria, final review, validation, and
integration. Use `$research-multiagent-orchestrator` for nontrivial scientific
coding delegation.

Use `deepseek_context_worker` for low-reasoning long-context inventory and log
reduction, `deepseek_context_reasoning_worker` for complex lineage and schema audits,
`deepseek_batch_worker` for approved repetitive edits, `luna_medium_worker` for
ordinary bounded coding, `luna_high_worker` for complex localized work,
`luna_max_worker` only for explicit quality-first escalation,
`terra_readonly_fallback_worker` for read-only failure reconstruction, and
`terra_fallback_worker` for bounded write recovery only after diagnosed failure.
Keep trivial work with the
primary agent when worker startup is likely to cost more than the task.

Use unique immutable `.codex/tasks/<task-id>.md` and
`.codex/bindings/<task-id>.json` artifacts. Never use the legacy singleton
`.codex/deepseek-worker-task.md`. Run only one delegated worker at a time.
Never switch workers because of elapsed time alone, and never remove a binding until
the worker and child processes are confirmed stopped.

Treat raw data as immutable. Never silently drop rows, impute missing values, change
units or CRS, merge taxonomy, or reinterpret statistical assumptions. Log row,
schema, unit, join, and spatial changes. The primary agent reviews every diff and
runs proportionate validation independently.
<!-- research-multiagent-orchestrator-global:end -->

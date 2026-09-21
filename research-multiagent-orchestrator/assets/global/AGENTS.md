<!-- research-multiagent-orchestrator-global:start -->
# Planner-worker-reviewer workflow

On first `$research-multiagent-orchestrator` use in a conversation, select exactly
one primary profile: Astra or Sol. The selected primary alone owns task
interpretation, scientific assumptions, architecture, decomposition, worker
dispatch, acceptance criteria, final review, validation, and integration. Reuse
the selection for the conversation and never pretend a skill switched the root
model.
Resolve models, reasoning effort, providers, and child codenames from the project's
`.codex/mygo-model-map.json`. Keep stable role names in bindings; use the generated
semantic codename-based task name for child threads, such as
`anon_schema_audit`. Keep random task-ID suffixes in coordination artifacts, not
visible child names.

Use `deepseek_context_worker` for low-reasoning long-context inventory and log
reduction, `deepseek_context_reasoning_worker` for complex lineage and schema audits,
`deepseek_batch_worker` for approved repetitive edits, `luna_medium_worker` for
ordinary bounded coding, `luna_high_worker` for complex localized work,
`luna_max_worker` only for explicit quality-first escalation,
`terra_readonly_fallback_worker` for read-only failure reconstruction, and
`terra_fallback_worker` for bounded write recovery only after diagnosed failure.
In a Sol-primary session, use `astra_review_worker` only as a quota-conscious,
read-only, single-pass second opinion. Its shipped effort is medium. In an
Astra-primary session, use
`sol_review_worker` only as a read-only second opinion. Neither reviewer may write,
dispatch, or accept results.
Keep trivial work with the
primary agent when worker startup is likely to cost more than the task.

Use unique immutable `.codex/tasks/<task-id>.md` and
`.codex/bindings/<task-id>.json` artifacts. Never use the legacy singleton
`.codex/deepseek-worker-task.md`. Record the selected primary profile in every new
binding. Run only one delegated worker at a time.
Never switch workers because of elapsed time alone, and never remove a binding until
the worker and child processes are confirmed stopped.

Treat raw data as immutable. Never silently drop rows, impute missing values, change
units or CRS, merge taxonomy, or reinterpret statistical assumptions. Log row,
schema, unit, join, and spatial changes. The primary agent reviews every diff and
runs proportionate validation independently.
<!-- research-multiagent-orchestrator-global:end -->

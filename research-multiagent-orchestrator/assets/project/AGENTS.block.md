<!-- research-multiagent-orchestrator:start -->
## Research multi-agent workflow

At first MYGO use in a conversation, select one Astra or Sol primary. The selected
primary alone owns task interpretation, scientific assumptions, architecture,
worker dispatch, acceptance criteria, final diff review, independent validation,
and integration. Reuse the choice for the conversation; a skill does not silently
switch the root model.
Resolve the primary model, reasoning effort, providers, and child codenames from
`.codex/mygo-model-map.json`. Keep stable technical roles in bindings and use the
generated semantic `task_name` for child threads, such as `anon_schema_audit`.
Keep random task-ID suffixes in coordination artifacts, not visible child names.

Route broad straightforward inventories, repo maps, metadata, and log reduction to
the low-reasoning `deepseek_context_worker`. Route complex lineage, R pipeline,
schema, variable, and cross-file reasoning to `deepseek_context_reasoning_worker`.
Route approved repetitive multi-file edits to
`deepseek_batch_worker`. Route ordinary bounded coding to `luna_medium_worker`,
complex localized debugging and implementation to `luna_high_worker`, and only
explicit quality-first escalations to `luna_max_worker`. Use
`terra_readonly_fallback_worker` for read-only reconstruction and
`terra_fallback_worker` only for bounded write recovery after a failure is diagnosed,
the previous writer is stopped, and a new immutable task describes partial state.
Use `astra_review_worker` only for a bounded read-only second opinion in a
Sol-primary session. Use `sol_review_worker` only for the corresponding second
opinion in an Astra-primary session. Reviewers never write, dispatch, or accept.
Keep trivial work with the primary agent.

Before delegation, create one unique immutable task and binding under `.codex/` and
record `ASTRA` or `SOL` as its primary profile.
Use a no-history fork for custom agents. Run at most one delegated worker at a time,
and never let DeepSeek and Luna write the same task concurrently. Do not
delete bindings until the worker is completed and no process may still write.

When the spawn message supplies every binding field, the worker must read task and
binding in one call and skip descriptor discovery, task-directory scans, separate
planning narration, and separate acknowledgement. Keep trivial and small read-only
work with the primary agent because worker startup can dominate elapsed time. Also
keep clear coding tasks likely to take about one minute or less with the primary
agent unless isolation, parallelism, or specialist reasoning adds material value.

Observe at 30 seconds without treating it as failure. Allow roughly three minutes
for ordinary tasks and five minutes for broad scientific scans unless a hard error
appears. Extend the wait on messages, files, stdout, process activity, or heartbeats.
Diagnose after two silent windows; never switch workers because of elapsed time alone.
For Luna, use 30 seconds as observation only, inspect medium again near 60 seconds,
and allow high/max roughly 90 seconds for a first progress signal before diagnosis.

Treat raw data as immutable. Never silently drop rows, impute missing values, change
units or CRS, merge taxonomy, or reinterpret statistical assumptions. Log row-count,
schema, unit, and spatial changes. The primary agent must review every diff and run
proportionate validation independently.
<!-- research-multiagent-orchestrator:end -->

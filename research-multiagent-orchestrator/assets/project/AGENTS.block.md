<!-- research-multiagent-orchestrator:start -->
## Research multi-agent workflow

The primary agent owns task interpretation, scientific assumptions, architecture,
acceptance criteria, final diff review, independent validation, and integration.

Route broad straightforward inventories, repo maps, metadata, and log reduction to
the low-reasoning `deepseek_context_worker`. Route complex lineage, R pipeline,
schema, variable, and cross-file reasoning to `deepseek_context_reasoning_worker`.
Route approved repetitive multi-file edits to
`deepseek_batch_worker`. Route ordinary bounded coding to `luna_medium_worker`,
complex localized debugging and implementation to `luna_high_worker`, and only
explicit quality-first escalations to `luna_max_worker`. Use
`terra_fallback_worker` only after a failure is diagnosed,
the previous writer is stopped, and a new immutable task describes partial state.
Keep trivial work with the primary agent.

Before delegation, create one unique immutable task and binding under `.codex/`.
Use a no-history fork for custom agents. Allow at most one write-capable worker at
a time, and never let DeepSeek and Luna write the same task concurrently. Do not
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

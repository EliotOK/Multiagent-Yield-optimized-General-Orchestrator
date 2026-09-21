<!-- research-multiagent-orchestrator-global:start -->
# Planner-worker-reviewer workflow (Luna-only)

On first `$research-multiagent-orchestrator` use in a conversation, select exactly
one Astra or Sol primary according to `.codex/mygo-model-map.json`. The selected primary alone owns interpretation,
scientific assumptions, architecture, dispatch, acceptance, final review,
validation, and integration. DeepSeek workers are disabled. Keep broad long-context
work with the primary agent. Use
`luna_medium_worker` for ordinary bounded coding, `luna_high_worker` for complex
localized work, and `luna_max_worker` only for explicit quality-first escalation.
Use `terra_readonly_fallback_worker` for read-only reconstruction and
`terra_fallback_worker` for bounded write recovery only after diagnosed failure and
confirmed worker stop.
In a Sol-primary session, `astra_review_worker` may provide one medium-reasoning,
read-only second opinion. In an Astra-primary session, `sol_review_worker` may
provide a read-only second opinion. Neither reviewer may write, dispatch, or accept.

Use unique immutable task and binding artifacts and record the primary profile in
each binding. Run only one delegated worker at
a time. Never switch workers because of elapsed time alone, and never remove a
binding until the worker and child processes are confirmed stopped. Treat raw data
as immutable and require primary-agent review and independent validation.
<!-- research-multiagent-orchestrator-global:end -->

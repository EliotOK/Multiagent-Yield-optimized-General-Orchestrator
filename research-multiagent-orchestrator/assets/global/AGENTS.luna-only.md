<!-- research-multiagent-orchestrator-global:start -->
# Planner-worker-reviewer workflow (Luna-only)

The active composer model is the only MYGO primary. Resolve it before every
delegation through `.codex/mygo-model-map.json` using the current composer model. A
known model may receive an Astra or Sol alias; any readable unmapped model resolves
to CURRENT. The resolved primary alone owns interpretation,
scientific assumptions, architecture, dispatch, acceptance, final review,
validation, and integration. Do not ask for a second logical primary; stop when the
current model is unavailable or ambiguous. DeepSeek workers are disabled. Keep broad long-context
work with the primary agent. Use
`luna_medium_worker` for ordinary bounded coding, `luna_high_worker` for complex
localized work, and `luna_max_worker` only for explicit quality-first escalation.
Use `terra_readonly_fallback_worker` for read-only reconstruction and
`terra_fallback_worker` for bounded write recovery only after diagnosed failure and
confirmed worker stop.
In a known Sol-primary session, `astra_review_worker` may provide one medium-reasoning,
read-only second opinion. In a known Astra-primary session, `sol_review_worker` may
provide a read-only second opinion. Neither reviewer may write, dispatch, or accept.

Use unique immutable task and binding artifacts and record the resolved primary
profile, model, effort, and source in each binding. Run only one delegated worker at
a time. Never switch workers because of elapsed time alone, and never remove a
binding until the worker and child processes are confirmed stopped. Treat raw data
as immutable and require primary-agent review and independent validation.
<!-- research-multiagent-orchestrator-global:end -->

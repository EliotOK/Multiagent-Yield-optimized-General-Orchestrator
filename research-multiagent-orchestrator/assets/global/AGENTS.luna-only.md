<!-- research-multiagent-orchestrator-global:start -->
# Planner-worker-reviewer workflow (Luna-only)

The primary Codex agent owns interpretation, scientific assumptions, architecture,
acceptance criteria, final review, validation, and integration. DeepSeek workers are
disabled. Keep broad long-context work with the primary agent. Use
`luna_medium_worker` for ordinary bounded coding, `luna_high_worker` for complex
localized work, and `luna_max_worker` only for explicit quality-first escalation.
Use `terra_readonly_fallback_worker` for read-only reconstruction and
`terra_fallback_worker` for bounded write recovery only after diagnosed failure and
confirmed worker stop.

Use unique immutable task and binding artifacts. Run only one delegated worker at
a time. Never switch workers because of elapsed time alone, and never remove a
binding until the worker and child processes are confirmed stopped. Treat raw data
as immutable and require primary-agent review and independent validation.
<!-- research-multiagent-orchestrator-global:end -->

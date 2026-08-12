<!-- research-multiagent-orchestrator:start -->
## Research multi-agent workflow (Luna-only)

The primary agent owns interpretation, scientific assumptions, architecture,
acceptance criteria, final diff review, independent validation, and integration.
DeepSeek routing is disabled for this project. Keep repository-wide context work
with the primary agent. Route ordinary bounded coding to `luna_medium_worker`,
complex localized debugging and implementation to `luna_high_worker`, and explicit
quality-first escalation to `luna_max_worker`. Use `terra_fallback_worker` only after
a diagnosed failure, confirmed worker stop, and a new immutable task.

Use unique immutable task and binding artifacts. Allow at most one write-capable
worker at a time. Observe dynamically and never switch because of elapsed time
alone. Treat raw data as immutable. Never silently alter rows, units, CRS,
missingness, taxonomy, or scientific assumptions. Review every diff independently.
<!-- research-multiagent-orchestrator:end -->

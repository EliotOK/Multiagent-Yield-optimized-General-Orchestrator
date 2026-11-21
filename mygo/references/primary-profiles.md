# Primary profiles

MYGO uses the current composer as its only primary controller. That primary alone owns
task interpretation, scientific judgment, architecture, worker dispatch, workspace
changes, acceptance decisions, final validation, and integration.

## Current-session resolution

Before each delegation, resolve `.codex/mygo-model-map.json` and run
`scripts/resolve-primary-profile.ps1`. The current thread model maps directly to
`ASTRA` or `SOL`; any other readable model resolves to `CURRENT`. No primary-
selection question is shown. Re-resolving allows a composer-model change to take
effect without preserving stale conversation state.

The resolver uses explicit observed values in tests and otherwise reads only the
latest model and reasoning-effort metadata associated with `CODEX_THREAD_ID`. If
the current model is missing or ambiguous, stop before task creation and ask the
user to switch or repair the composer session. An unmapped but readable model is
already a valid `CURRENT` primary; it does not need a map entry. A skill cannot
replace the root model, and a card selection cannot make a mismatched model the
primary. Never represent a secondary subagent as the native root controller.

## Known Astra alias

Use an Astra-rooted conversation for ambiguous, high-risk, or architecture-heavy
work where stronger global reasoning justifies its higher quota cost.

- Astra remains the sole controller and final reviewer.
- Do not spawn another Astra agent merely to duplicate the root agent.
- Use DeepSeek and Luna workers according to the routing matrix.
- Invoke `sol_review_worker` only for a materially useful independent review of a
  high-risk decision, a disputed finding, or an explicit user request.
- Give the Sol reviewer a compact frozen evidence bundle and one bounded question.

## Known Sol alias

Use a Sol-rooted conversation for the established, quota-predictable workflow and
most routine scientific engineering.

- Sol remains the sole controller and final reviewer.
- Use DeepSeek and Luna workers according to the routing matrix.
- Invoke `astra_review_worker` only for a materially useful independent review of a
  high-risk decision, a disputed finding, or an explicit user request.
- Keep the Astra review read-only, single-pass, medium reasoning by default, and based
  on a compact frozen evidence bundle. Do not request a repo-wide rescan unless the
  user explicitly accepts the quota cost.

## Secondary-review contract

`astra_review_worker` and `sol_review_worker` are advisory only. They must not:

- modify files or run write-capable commands;
- dispatch or supervise other workers;
- broaden the task beyond the supplied evidence;
- make the final acceptance decision;
- continue into a second pass unless the primary agent or user explicitly asks.

The primary controller resolves disagreements, records uncertainty, and performs
the final validation. Parallel work is limited to independent read-only review;
MYGO still permits at most one write-capable worker.

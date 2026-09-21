# Primary profiles

MYGO uses one primary controller per conversation. The selected primary alone owns
task interpretation, scientific judgment, architecture, worker dispatch, workspace
changes, acceptance decisions, final validation, and integration.

## First invocation

On the first MYGO invocation in a conversation, resolve
`.codex/mygo-model-map.json`, then:

1. If the user explicitly selected `ASTRA` or `SOL`, accept that choice.
2. If `default_primary` is `ASTRA` or `SOL`, use that profile. If it is `ASK`, use
   the native structured question UI when it is available and ask
   the user to choose **Astra primary** or **Sol primary**.
3. If structured input is unavailable, ask one concise plain-text question and
   wait. Do not dispatch a worker or modify files before the choice is known.
4. Reuse the choice for the remainder of the conversation. Ask again only when the
   user explicitly requests a profile switch.

A skill cannot silently replace the root model of the current conversation. When
the selected profile does not match the current root model and the identity is
known, explain the mismatch and ask the user to switch the composer model or start
a matching task. When identity cannot be verified, say so and ask the user to
confirm it. Never represent a secondary subagent as the native root controller.

## Astra primary

Use an Astra-rooted conversation for ambiguous, high-risk, or architecture-heavy
work where stronger global reasoning justifies its higher quota cost.

- Astra remains the sole controller and final reviewer.
- Do not spawn another Astra agent merely to duplicate the root agent.
- Use DeepSeek and Luna workers according to the routing matrix.
- Invoke `sol_review_worker` only for a materially useful independent review of a
  high-risk decision, a disputed finding, or an explicit user request.
- Give the Sol reviewer a compact frozen evidence bundle and one bounded question.

## Sol primary

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

# Routing policy

## Decision matrix

| Context breadth | Reasoning density | Default route |
| --- | --- | --- |
| Broad | Low | `deepseek_context_worker` |
| Broad | Medium to high | `deepseek_context_reasoning_worker` |
| Broad | Medium, repetitive writes | context worker, primary review, then `deepseek_batch_worker` |
| Narrow | Low, under about one minute | primary agent |
| Narrow | Medium | `luna_medium_worker` |
| Narrow | High | `luna_high_worker` |
| Narrow | Exceptional quality-first | `luna_max_worker` |
| Any | High scientific risk | primary agent decides; worker only gathers evidence or implements an exact rule |
| Any, Sol primary | Independent high-risk review | `astra_review_worker` once, medium reasoning, read-only |
| Any, Astra primary | Independent high-risk review | `sol_review_worker` once, read-only |

## DeepSeek context routes

Use `deepseek_context_worker` with low reasoning for inventories, repo maps,
metadata extraction, deterministic search, and log reduction. Keep very small scans
with the primary agent because worker startup can dominate wall time.

Use `deepseek_context_reasoning_worker` with high reasoning when the result requires
cross-file inference: data lineage, R pipeline reconstruction, schema relationships,
variable consistency, or ambiguous failure diagnosis.

Use a staged scan instead of blindly loading every file:

1. Inventory text source, configuration, documentation, metadata, and logs.
2. Exclude `.git`, package libraries, caches, binaries, generated outputs, raw
   datasets, and secrets unless explicitly required.
3. Rank files by relevance and read them in coherent groups.
4. Return a structured evidence package with paths, symbols, uncertainties,
   skipped inputs, and proposed next scope.
5. Let the primary agent approve any write task.

Good outputs include repository maps, R call graphs, pipeline stages, input/output
tables, join keys, units, CRS, schemas, inconsistent variables, and log timelines.

## DeepSeek batch route

Use only after the transformation rule and file set are explicit. Prefer mechanical
changes with deterministic validation. Stop on semantic ambiguity, scientific
judgment, unexpected file structure, or task/hash mismatch.

## Luna route

Provide a compact evidence bundle instead of the entire repository. Include the
reproduction, relevant files, observed versus expected behavior, constraints,
tests, and earlier failed approaches. Reserve max reasoning for tasks whose measured
quality gain justifies additional latency.

- Keep trivial edits and clear tasks likely to take the primary agent about one
  minute or less with the primary agent; coordination cost can exceed useful work.
- Start with `luna_medium_worker` for ordinary bounded implementation and tests.
- Select `luna_high_worker` when the task requires tracing complex logic, resolving
  ambiguity, integration reasoning, or a tricky localized refactor.
- Escalate to `luna_max_worker` only after high reasoning is insufficient or when a
  quality-critical task has an explicit acceptance case for maximum reasoning.

Local latency probes observed roughly 15 seconds in spawn/thread setup and variable
additional time before the first tool call. Treat these numbers as scheduling
baselines, not guarantees: medium ranged from about 9 to 23 seconds after spawn
returned in two probes, while high/max could take roughly 40 to 50 seconds. Use
representative repeated measurements before changing a route solely for speed.

## Sequential handoffs

Prefer:

```text
DeepSeek read-only survey -> primary decision -> DeepSeek batch or Luna write
-> primary review -> optional DeepSeek read-only consistency audit
```

Never switch workers merely because chat status still says `running` after an
artifact appears. Confirm process, state, and binding status first.

## Cross-review routes

Cross-review is exceptional, not a mandatory stage. Use it only for an explicit
request, a high-impact scientific or architectural decision, or a genuine dispute
that independent reasoning can resolve. Give the reviewer a compact immutable
evidence bundle and one question. The reviewer cannot write, dispatch, accept, or
supersede the resolved current primary.

Do not spawn `astra_review_worker` when Astra is already the primary, or
`sol_review_worker` when Sol is already the primary. Do not use a reviewer to repeat
ordinary final review. Astra review defaults to medium reasoning and one pass to
control quota use.

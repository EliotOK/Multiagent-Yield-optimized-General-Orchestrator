# Scientific task prompts

## Broad audit

```text
Use $research-multiagent-orchestrator to map the R pipeline that produces the
derived vegetation table. Use a DeepSeek context reasoning worker for read-only
lineage evidence. Do not modify data or scripts. Return inputs, outputs, joins,
units, row-count changes, and unresolved ambiguities. The primary agent reviews the
result.
```

## Bounded implementation

```text
Use $research-multiagent-orchestrator to add a focused validation function to the
specified R script. Keep the primary agent responsible for requirements and review.
Use Luna medium if the work is bounded and likely exceeds a minute; run the listed
tests and return the complete diff for review.
```

## Difficult local failure

```text
Use $research-multiagent-orchestrator to diagnose this reproducible package/API
integration failure. Supply only the reproduction, relevant files, observed error,
and acceptance criteria. Route to Luna high; do not change dependencies or raw data
without primary-agent approval.
```

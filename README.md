# Research Multi-Agent Orchestrator

Windows-first Codex skill for scientific coding projects that routes work across a
primary reviewer, DeepSeek V4 Flash long-context workers, and tiered Luna coding
workers.

> Status: `v0.1.0-beta.1` release candidate. This is an unofficial community
> project and is not affiliated with or endorsed by OpenAI or DeepSeek.

## What it does

The primary Codex agent retains task interpretation, scientific decisions,
architecture, acceptance criteria, final review, and validation. It routes bounded
work as follows:

| Work shape | Default route |
| --- | --- |
| Tiny task, likely under one minute | Primary agent |
| Broad inventory, logs, metadata | DeepSeek context (low) |
| Lineage, schemas, cross-file inference | DeepSeek context reasoning (high) |
| Repetitive approved edits | DeepSeek batch |
| Clear bounded implementation | Luna medium |
| Difficult local debugging or refactor | Luna high |
| Exceptional quality-first escalation | Luna max |

The skill installs task/binding/state protocols, worker definitions, routing rules,
fallback rules, and PowerShell utilities for Windows.

## Requirements

- Codex Desktop or Codex CLI with custom subagents enabled.
- Windows PowerShell 5.1+ or PowerShell 7+.
- Node.js for the included smoke examples; R and Python are optional but recommended
  for scientific projects.
- A DeepSeek API key in `DEEPSEEK_API_KEY` only when using DeepSeek workers. Never
  put the key in project files, prompts, task files, or this repository.
- Access to the selected Luna models for Luna workers; model availability depends on
  the user's Codex account and release.

## Install

Ask Codex to install the skill from this repository with `$skill-installer`, then
restart Codex if the new skill is not listed. From a project root, preview the
project installation first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\install-workflow.ps1 `
  -ProjectRoot "D:\path\to\project" `
  -ForceAgentUpdate
```

Review the dry-run output, then add `-Apply`. The installer writes only managed
blocks, creates recoverable backups under `.codex\diagnostics\backups` or the
user Codex backup directory, and refuses to overwrite a detected legacy singleton
global protocol automatically.

Verify after restarting Codex:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\verify-workflow.ps1 `
  -ProjectRoot "D:\path\to\project"
```

## Use

In Codex, start a task with:

```text
Use $research-multiagent-orchestrator for this scientific coding task.
Keep scientific interpretation and final review with the primary agent.
Route only work that can amortize worker startup, and review every worker diff.
```

See [examples](examples) for scientific-task prompts and expected routing.

## Safety model

- Treat raw data as immutable.
- Do not silently alter rows, units, CRS, missingness, taxonomy, or assumptions.
- Allow one write-capable worker at a time.
- Use immutable task and binding records for every delegation.
- Archive coordination evidence after review; do not delete it while a worker might
  still write.

## Known limitations

- This release is Windows-first because its deterministic helpers are PowerShell.
- DeepSeek initial custom-agent messages may be dropped on some Codex versions. The
  task/binding fallback handles this, but can add startup delay.
- Luna startup latency can vary materially. Use Luna medium for ordinary bounded
  work; reserve high and max for measured quality gains.
- A separate throwaway "warm-up" worker is not expected to warm a later independent
  worker thread. Persistent same-thread reuse is experimental and is not enabled by
  default until it demonstrates a latency benefit in repeated A/B tests.

## Development

Run the offline checks on Windows:

```powershell
pwsh -NoProfile -File .\tests\validate-package.ps1
pwsh -NoProfile -File .\tests\install-smoke.ps1
```

The CI workflow runs the same checks without API keys or model calls.

## Security

Report security-sensitive issues privately as described in [SECURITY.md](SECURITY.md).
Do not include API keys, raw research data, or private project paths in issues.

## License

MIT. See [LICENSE](LICENSE).

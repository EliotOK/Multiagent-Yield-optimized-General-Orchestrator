# MYGO

**Multi-agent Yield-optimized General Orchestrator**

[简体中文](README.zh-CN.md) | English

Windows-first Codex skill for scientific coding projects that routes work across a
primary reviewer, DeepSeek V4 Flash long-context workers, and tiered Luna coding
workers.

The distributable Codex skill keeps the descriptive internal name
`research-multiagent-orchestrator` so its purpose and trigger remain explicit.

> Status: `v0.1.0-beta.4` release candidate. This is an unofficial community
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
| Failed task, read-only evidence reconstruction | `terra_readonly_fallback_worker` |
| Failed task, approved bounded write recovery | `terra_fallback_worker` |

The skill installs task/binding/state protocols, worker definitions, routing rules,
fallback rules, and PowerShell utilities for Windows.

## Requirements

- Codex Desktop or Codex CLI with custom subagents enabled.
- Windows PowerShell 5.1+ or PowerShell 7+.
- No Node.js or Python runtime is required for installation. Python 3.11+ is used
  only by the release validation suite; install R, Python, Node.js, GIS tools, or
  Git only when the delegated project tasks need them.
- A DeepSeek API key in `DEEPSEEK_API_KEY` only when using DeepSeek workers. Never
  put the key in project files, prompts, task files, or this repository.
- Access to the selected Luna models for Luna workers; model availability depends on
  the user's Codex account and release.

## Install

### Copy-paste installation prompt

Paste this into a new Codex task on the target device:

```text
Use $skill-installer to install the skill from:
https://github.com/EliotOK/Multiagent-Yield-optimized-General-Orchestrator/tree/v0.1.0-beta.4

Install the research-multiagent-orchestrator skill. After installation, read its
SKILL.md and configure MYGO for the current project. Run install-workflow.ps1 in
preview mode first, review the proposed paths and changes, then apply them and run
verify-workflow.ps1. Never print, read, store, or copy my DeepSeek API key. First
check whether DEEPSEEK_API_KEY is available without reading or printing its value.
If it is missing, stop before apply and tell me to run scripts/set-deepseek-key.ps1
myself in an interactive PowerShell terminal, then fully restart Codex. Do not ask
me to paste the key into chat. If I explicitly decline DeepSeek or existing
instructions suspend it, pass -LunaOnly to both scripts and do not ask me to
re-enable DeepSeek. If global Codex changes are not authorized, also pass
-ProjectOnly; do not modify ~/.codex/config.toml, ~/.codex/agents, or the global
AGENTS.md. ProjectOnly changes installation scope only: preserve full DeepSeek
routing when all compatible user-level agents, provider configuration, and the key
already exist; otherwise stop before writing. LunaOnly disables DeepSeek and keeps
long-context work with the primary agent. Reserve Terra for diagnosed sequential
fallback. Tell me when a full Codex Desktop restart is required.
```

Full-mode preview is safe without `DEEPSEEK_API_KEY`, but apply stops before writing
and explains how to set it. Run this yourself in an interactive terminal:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\set-deepseek-key.ps1
```

Input is hidden and the value is never printed or placed in command history. The
script stores it as a Windows user environment variable because that is what the
Codex provider integration consumes. Windows environment variables are not an
encrypted secret vault; protect the Windows account and never put the key in chat,
commands, project files, or logs. Fully restart Codex afterward.

The skill can alternatively be installed without a key using `-LunaOnly`. In that case the primary
agent, Luna workers, Terra fallback, task records, validation, and archival remain
available; DeepSeek routes remain unavailable until the environment variable is
set, MYGO is reinstalled without `-LunaOnly`, and Codex is fully restarted.

Use `-LunaOnly` to install and verify Luna/Terra without installing or enabling any
DeepSeek provider or worker. Add `-ProjectOnly` when MYGO may update only the current
project; this intentionally leaves all user-level Codex configuration untouched.
Project-only mode installs project protocols and routing instructions, but requires
all selected Luna/Terra and, in full mode, DeepSeek agents and provider configuration
to exist at user level. It validates those prerequisites without modifying them.

### Manual project installation

After the skill is installed, preview the project changes from the project root:

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

- A DeepSeek worker sends selected prompt and file context to a third-party provider.
  Read-only sandboxing prevents local writes; it does not prevent data transmission.
  Keep participant-level, unpublished restricted, contractual, confidential, and
  credential-bearing content on the primary/Luna route unless its release policy
  explicitly permits DeepSeek. Task creation defaults to `LOCAL_ONLY` and requires
  an explicit `APPROVED_EXTERNAL` or `PUBLIC` classification for DeepSeek.
- Treat raw data as immutable.
- Do not silently alter rows, units, CRS, missingness, taxonomy, or assumptions.
- Run only one delegated worker at a time. The task protocol is deliberately serial.
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
powershell -NoProfile -File .\tests\validate-package.ps1
powershell -NoProfile -File .\tests\install-smoke.ps1
powershell -NoProfile -File .\tests\security-regression.ps1
```

PowerShell 7 users may substitute `pwsh`. CI runs all three checks on Windows
PowerShell 5.1 and PowerShell 7 without API keys or model calls.

## Security

Report security-sensitive issues privately as described in [SECURITY.md](SECURITY.md).
Do not include API keys, raw research data, or private project paths in issues.

## License

MIT. See [LICENSE](LICENSE).

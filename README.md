# MYGO

**Multi-agent Yield-optimized General Orchestrator**

[简体中文](README.zh-CN.md) | English

MYGO is a Codex plugin with a bundled skill for multi-model collaboration and scientific coding. The
current Codex chat keeps control of the task, review, and acceptance. It can
delegate evidence gathering to DeepSeek Flash (`deepseek-flash`), code candidates
to GLM-5.3-Flash, scoped writes to Luna, design and review to Kimi, and writing
or visual feedback to Gemini.

The bundled Codex skill uses the concise name `mygo`.

> The existing PowerShell release remains tagged `v0.1.0-beta.4`. MYGO is an
> unofficial community project.

## Install the plugin

Install Python 3.11 or newer and a current Codex Desktop release on Windows x64. Then run:

```powershell
codex plugin marketplace add EliotOK/Multiagent-Yield-optimized-General-Orchestrator
codex plugin add mygo@mygo
```

Restart Codex, open **MYGO settings**, and use the following guided setup:

1. Review each provider's status. MYGO first checks Magpie and the corresponding
   local environment variable. Select **Import from environment** or **Open password
   window** only for missing providers. The local password window passes the value
   to Magpie through standard input. MCP arguments, chat messages, logs, and role
   preferences do not carry the key.
2. Edit the display name, model ID, responsibility, and reasoning effort for each
   role. Save the role preferences. They are stored in
   `~/.codex/mygo/preferences.json`, which the bundled skill reads before dispatch.
3. Select **Configure native V2**. MYGO uses an installed compatible Magpie or
   downloads the official CLI, verifies its published SHA-256 checksum, selects
   the configured models, and updates the Codex V2 settings. Existing Codex files
   are backed up first. A failed setup restores the Codex files and Magpie's
   provider model selections.
4. Fully restart Codex and reopen the original chat. Send a small task and confirm
   both a native child and the requested provider route. Installation and a valid
   config do not by themselves prove that a provider accepted a request.

DeepSeek, Kimi, GLM, and Gemini use `DEEPSEEK_API_KEY`, `MOONSHOT_API_KEY`,
`ZAI_API_KEY`, and `GEMINI_API_KEY`, respectively. Select the appropriate GLM
Coding Plan or open-platform route before importing that provider. Magpie stores
provider keys in its own local configuration. That storage is not an encrypted
secret vault. Review the local configuration permissions on a shared device.

The interactive import and automatic CLI download currently target Windows x64.
On other platforms, configure providers with Magpie's own interface and use the
manual settings in [model routing](mygo/references/model-routing.md).

## Magpie V2 and direct API

The plugin automates the tested Magpie path described in the
[V2 setup and acceptance criteria](mygo/references/model-routing.md#native-v2-through-magpie).
The earlier local Desktop acceptance resumed an existing V2 chat with Sol and ran
DeepSeek, Kimi, GLM-5.3-Flash, and Gemini as native children. The test completed
a log search, design question, validated code draft, and copy revision. This was
a version-specific acceptance result, so repeat a real dispatch after upgrading
Codex or Magpie.

Use `$mygo` in your Codex chat and specify the task and
the context approved for each external provider. If the current chat sends a
sealed task or cannot start native external children, the bundled Python 3 helper
can call the four official APIs with your own environment variables. See
[direct API usage](mygo/references/model-routing.md#direct-vendor-api). A direct
API call returns text to the current chat. It does not create a native child.

## What it does

The rest of this section and the PowerShell installer describe the existing
project workflow with a model map and persisted task records.

Exactly one current-session primary retains task interpretation, scientific decisions,
architecture, worker dispatch, acceptance criteria, final review, and validation
for the conversation. The other flagship model can only provide a bounded,
read-only second opinion; it is never a second controller.

| Primary profile | Optional cross-review |
| --- | --- |
| Astra primary | `sol_review_worker` for a high-risk or explicit second opinion |
| Sol primary | `astra_review_worker`, medium reasoning and one pass by default |
| Any other current model | No profile-specific cross-review by default |

The primary routes bounded work as follows:

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
- The PowerShell installer requires neither Node.js nor Python. The direct API
  helper uses Python 3, and the release validation suite uses Python 3.11+.
- A DeepSeek API key in `DEEPSEEK_API_KEY` only when using DeepSeek workers. Never
  put the key in project files, prompts, task files, or this repository.
- Access to the selected Luna models for Luna workers; model availability depends on
  the user's Codex account and release.

## Install

This section covers the older standalone skill and its persisted PowerShell task
workflow. Use the plugin installation above for the guided multi-model setup.

### Copy-paste installation prompt

Paste this into a new Codex task on the target device:

```text
Use $skill-installer to install the skill from:
https://github.com/EliotOK/Multiagent-Yield-optimized-General-Orchestrator/tree/v0.1.0-beta.4

Install the mygo skill. After installation, read its
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
long-context work with the current primary agent. Before delegation, resolve the
active composer model through the project model map; do not ask me to choose a
second logical primary and do not claim that the skill can change the current
task's root model. Reserve Terra for diagnosed sequential
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
Use $mygo for this scientific coding task.
Resolve the active composer model as the MYGO primary before delegation. Keep
scientific interpretation and final review with that current-session primary.
Route only work that can amortize worker startup, and review every worker diff.
```

See [examples](examples) for scientific-task prompts and expected routing.

### Change models without changing the topology

MYGO creates `.codex/mygo-model-map.json`. Its shipped primary settings are
`default_primary = CURRENT`, Astra at `gpt-6-astra / medium`, and Sol at
`gpt-5.6-sol / high`. `CURRENT` means the active composer model is authoritative;
MYGO re-resolves it before every delegation and does not ask for a second primary.

Every worker has a stable technical role plus a human-facing codename inspired by
MyGO!!!!! and Ave Mujica. Codenames label child threads only; they do not inject a
fictional personality into scientific work. Edit the map to change a node's model,
provider, effort, or codename, then preview and apply:

Child names combine a codename prefix with a concise task description—for example,
`Anon — schema audit` in user-facing text and `anon_schema_audit` in the Codex
dispatch API. Each spawn draws the prefix randomly from every codename in the map
for variety; the binding keeps the stable role codename in `worker_codename` and
records the drawn prefix in `spawn_codename` with `codename_source = random`. Pass
`-CodenameMode role` to `create-task.ps1` to pin the prefix to the worker's own
codename. Random suffixes remain only in immutable audit IDs and are not shown
as child names. Repeated descriptions use readable numbering such as
`anon_schema_audit_2`.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\configure-model-map.ps1 -ProjectRoot "D:\path\to\project"

powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\configure-model-map.ps1 -ProjectRoot "D:\path\to\project" -Apply
```

Fully restart Codex and run `verify-workflow.ps1` afterward. The map never stores
API keys. Stable role keys and filenames are protocol identifiers; changing the
topology still requires a versioned skill migration.

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
- Cross-reviewers are read-only and advisory; only the resolved current primary can
  dispatch write work, integrate changes, or accept a result.
- Use immutable task and binding records for every delegation.
- Archive coordination evidence after review; do not delete it while a worker might
  still write.

## Known limitations

- This release is Windows-first because its deterministic helpers are PowerShell.
- DeepSeek initial custom-agent messages may be dropped on some Codex versions. The
  task/binding fallback handles this, but can add startup delay.
- Luna startup latency can vary materially. Use Luna medium for ordinary bounded
  work; reserve high and max for measured quality gains.
- The skill cannot change the root model of an existing conversation. If the chosen
  profile differs from the composer model, switch the model or start a matching
  task before dispatch. Astra cross-review is deliberately single-pass at medium
  effort by default and
  single-pass by default to limit quota use.
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

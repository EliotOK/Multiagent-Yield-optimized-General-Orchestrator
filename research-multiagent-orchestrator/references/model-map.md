# Model map and codenames

MYGO keeps stable technical roles and resolves their models from the project-level
`.codex/mygo-model-map.json`. This separates workflow topology from fast-moving
model releases. The technical role remains the audit identity; `codename` is a
human-facing child-thread name and has no behavioral or personality effect.

## Primary selection

`default_primary` accepts:

- `ASK` (recommended): ask once per conversation;
- `ASTRA`: use the configured Astra profile unless the user chooses otherwise;
- `SOL`: use the configured Sol profile unless the user chooses otherwise.

The shipped defaults are:

```text
ASTRA -> gpt-6-astra / medium
SOL   -> gpt-5.6-sol / high
```

These entries describe the required composer/root configuration. A skill cannot
change the current root model or reasoning effort by editing a subagent file.

## Stable roles and display codenames

| Stable role | Default codename |
| --- | --- |
| `deepseek_context_worker` | Soyo |
| `deepseek_context_reasoning_worker` | Mutsumi |
| `deepseek_batch_worker` | Taki |
| `luna_medium_worker` | Anon |
| `luna_high_worker` | Rana |
| `luna_max_worker` | Oblivionis |
| `terra_readonly_fallback_worker` | Mortis |
| `terra_fallback_worker` | Timoris |
| `astra_review_worker` | Sakiko |
| `sol_review_worker` | Uika |

Use the stable role in bindings and routing. Give each task a concise semantic label
and use the generated codename-based `task_name`, such as `anon_schema_audit`, when
spawning a child. Present it to users as `Anon — schema audit`. The immutable task ID
retains its random collision-resistant suffix, but the visible child name does not.

## Change a model binding

Edit only the relevant `provider`, `model`, `reasoning_effort`, or `codename` value
in `.codex/mygo-model-map.json`. Supported providers are currently `default`
(Codex/OpenAI) and `deepseek`. Provider credentials and provider configuration must
already exist; the map never stores credentials.

Preview the resolution:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <skill>\scripts\configure-model-map.ps1 -ProjectRoot <root>
```

After reviewing every role, apply and restart Codex Desktop:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <skill>\scripts\configure-model-map.ps1 -ProjectRoot <root> -Apply
```

Then run `verify-workflow.ps1`. Re-run `configure-model-map.ps1 -Apply` after a
forced MYGO agent-template update, because the installer may refresh the underlying
role instructions before the project-specific model binding is reapplied.

Do not change role keys or agent filenames in the map. Adding, removing, or changing
the responsibilities of nodes is an architecture migration and requires updating
the skill, protocol, installer, and tests together.

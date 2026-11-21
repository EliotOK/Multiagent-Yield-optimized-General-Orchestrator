# Model routing

| Worker | Magpie model ID | Direct API model | Environment variable |
| --- | --- | --- | --- |
| DeepSeek Flash | `deepseek/deepseek-flash` | `deepseek-flash` | `DEEPSEEK_API_KEY` |
| Kimi K3.1 Pro | `moonshot-cn/kimi-k3.1-pro` | `kimi-k3.1-pro` | `MOONSHOT_API_KEY` |
| Zhipu GLM-5.3-Flash | `zhipu/glm-5.3-flash` | `glm-5.3-flash` on the Zhipu Coding Plan | `ZAI_API_KEY` |
| Gemini Flash-Lite | `google/gemini-3.1-flash-lite` | `gemini-3.1-flash-lite` | `GEMINI_API_KEY` |

Use the runtime's actual model IDs. Prefer a provider-specific ID when the user has authorized that provider. A Magpie routing group can select a different account or provider. Luna uses an available native Codex model such as `gpt-6-luna`.

## Native V2 through Magpie

The recommended installation is the MYGO plugin, whose settings panel checks existing provider readiness, imports missing credentials through a local password window, and writes the V2 configuration. See the repository README for the two installation commands and restart procedure. Manual setup remains available in Magpie's own interface. Use Magpie's **Lead’s pick** setting for per-worker model selection. With ChatGPT sign-in, the tested route keeps Codex's built-in OpenAI provider for the lead and uses Magpie for model requests. Magpie receives Responses requests and converts the external worker's plaintext task to a Chat Completions user message. [Magpie Codex setup](https://usemagpie.ai/docs/codex-models) · [Magpie routing](https://github.com/yetone/magpie/blob/main/docs/subsystems/gateway-routing.md)

Check that the actual conversation offers Code Mode, exposes the model ID, and permits native collaboration in Code Mode. When the runtime provides the function below, dispatch in Code Mode with a no-history fork:

```javascript
const child = await tools.collaboration__spawn_agent({
  task_name: "check_public_docs",
  model: "deepseek/deepseek-flash",
  reasoning_effort: "low",
  fork_turns: "none",
  message: "Find the official Python pathlib documentation and return its URL."
});
text(child);
```

Use the active tool schema. If selecting a custom role that fixes a model, use the role's selection. Wait for independent results and dispatch in batches within the session's agent limit. A no-history fork still permits runtime instructions and tool metadata to be included. Use direct API calls when authorization covers only specific excerpts.

Confirm `subAgentActivity` or the child in Codex, the Magpie `collab_spawn` route to the requested vendor, and a result that addresses the task. A model picker entry alone only establishes that Codex knows the model. If Magpie reports a sealed task, the originating backend controls that message. Use an available plaintext Code Mode route or the direct helper. Magpie's **Codex subagents on any model** is its V1 option for a separate chat. [Codex subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents) · [Magpie agent wiring](https://github.com/yetone/magpie/blob/main/docs/subsystems/agent-wiring.md)

### Reproducing the Windows Desktop V2 test

The tested Desktop runtime reported Codex CLI `0.171.0-alpha.13` and used Magpie `0.1.4652`. An existing conversation used `gpt-6.2-sol` with ChatGPT sign-in. Both the lead and four external children recorded `multi_agent_version = v2`. The provider names in the table were checked against live HTTP 200 routes. A subsequent test exercised a read-only log search, a design decision, a separately tested code draft, and a copy revision. The workers ran sequentially in one chat.

On that setup, the Magpie-generated Codex catalog already declared Sol as `code_mode_only` and V2. The working configuration added `"multi_agent_tools_in_code_mode": true` to Sol's entry in a user-owned copy of that catalog, selected that copy as `model_catalog_json`, and used the following runtime settings:

```toml
# Merge individual keys into existing tables on a compatible runtime.
[features]
code_mode = true
code_mode_host_grpc = true

[features.multi_agent_v2]
enabled = true
non_code_mode_only = false
expose_spawn_agent_model_overrides = true
wait_agent_enabled = true
```

Keep the existing model provider, gateway, and other user settings. These switches depend on the installed Codex release. Check the schema and availability before changing them, back up the user config, then restart Desktop and reopen the existing conversation. Refresh the user-owned catalog from the Magpie catalog when the upstream model list changes. MYGO installation does not apply this example configuration. [Codex tool exposure source](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/spec_plan.rs)

## Direct vendor API

Run the Python 3 helper with the appropriate provider credentials in environment variables. On Windows it can also read the corresponding user environment variable. It sends the approved task and inline excerpts to the provider's official endpoint and returns the result to the current chat as JSON. It does not create a native Codex child or scan the workspace.

```powershell
python <SKILL_PATH>/scripts/consult.py --check
python <SKILL_PATH>/scripts/consult.py --smoke deepseek glm
python <SKILL_PATH>/scripts/consult.py --jobs <approved-jobs.json> --allow-external
```

`--check` makes no network requests. `--smoke` sends synthetic markers to the selected providers, or all four when none are named. For actual jobs, use explicit text approved for each destination:

```json
[
  {"id":"audit","provider":"kimi","task":"Compare these two designs and list the unknowns.","context":"Approved summary of the options."},
  {"id":"copy","provider":"gemini","task":"Draft two labels for this button.","context":"Approved UI description."},
  {"id":"docs","provider":"deepseek","web":"search","task":"Find the official Python pathlib documentation."}
]
```

DeepSeek Flash supports `web: "search"`, `"fetch"` for public URLs in the task, or `"both"`. Use only public queries and links. Check `web_actions`, opened URLs, and citations. `web_unverified` means the response lacks evidence that the requested operation ran. These are DeepSeek's hosted web tools. The other direct routes accept text tasks and excerpts. [DeepSeek Web Tools](https://api-docs.deepseek.com/guides/web_tools/)

Inspect `route`, `status`, and `served_model` for each result. Keep successful results in a mixed batch. Diagnose failures before sending another request, especially when a previous request timed out and its outcome is unknown.

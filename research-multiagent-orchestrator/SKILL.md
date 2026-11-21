---
name: research-multiagent-orchestrator
description: Use MYGO to coordinate Codex, DeepSeek Flash, GLM, Kimi, and Gemini for research and coding, including evidence gathering, design, implementation, execution, and review. Use when the user asks for MYGO, multi-model delegation, or the existing scientific planner-worker-reviewer workflow.
---

# MYGO multi-model orchestration

The current Codex model leads the task. It decides whom to delegate to, reviews evidence and diffs, integrates changes, and validates the result. Honor the user's explicit assignments and the project's existing instructions. Ask through a Codex question card when an unresolved choice would materially change the result, cost, or write scope.

| Model | Default assignment |
| --- | --- |
| DeepSeek Flash | Search logs, map context, and find and read public sources. Return line numbers or links. |
| GLM-5.3-Flash | Draft a bounded implementation, test cases, or an independent candidate when it saves work. |
| Luna | Use a native Codex child for scoped writes, focused code edits, and verification. Let Luna finish a clear task end to end when a separate draft adds little. |
| Kimi K3 / K3.1 | Compare design options or independently review a risky implementation. |
| Gemini | Draft copy, structure a narrative, or advise on visual direction. Prefer small text edits and variants with the verified Flash-Lite model. |

Use the smallest team that helps the task. Give each worker an independent question, allowed context, and a result to return. Send external models only the context approved for the selected provider. External models normally gather evidence, suggest changes, or review. Set concrete file boundaries for write-capable workers and verify changes against the task.

## Choose the path

- **Magpie V2** suits an existing Codex chat whose Code Mode can spawn the requested external model with a plaintext task. Send only the approved task and use a no-history fork. Confirm both a native child and the actual vendor route. See [model routing](references/model-routing.md).
- **Direct vendor API** handles approved text-only tasks when the V2 route is unavailable, when a task is sealed to ChatGPT, or when only specific excerpts may leave Codex. Use the same requested vendor through the bundled helper and report that this was a direct call. Keep any successful native results.
- **PowerShell project workflow** applies to projects using MYGO's existing model map and task/binding/state protocol. Read [the PowerShell workflow](references/legacy-workflow.md) before using its installer, project roles, write workers, or fallback procedures. Follow the project's binding and review requirements when choosing a route.

For local observations, verify the cited evidence in the workspace. For scientific changes, apply [scientific invariants](references/scientific-invariants.md). Report the models and routes that actually ran, the verified result, and any remaining limitation.

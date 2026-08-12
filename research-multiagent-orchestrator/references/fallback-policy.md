# Latency and fallback policy

## Reduce avoidable latency

Run `scripts/worker-preflight.ps1` before spawning. Include the canonical root,
binding path, task hash, allowed files, validation commands, compact evidence bundle,
expected duration, and first observation point in the initial message.

Use a no-history custom-agent fork. Check binding and hash once before the first
write and once before return. Combine related file, runtime, and Git reads. Do not
repeat preflight, task discovery, or authorization checks before every command.

Use the low-reasoning context worker for inventory and deterministic extraction.
Use the high-reasoning context worker only for cross-file inference. Do not delegate
tiny scans whose context volume cannot amortize agent startup.

Use `luna_medium_worker` as the normal coding route. Use `luna_high_worker` only
when complexity warrants it, and reserve `luna_max_worker` for an explicit
quality-first escalation. Keep work with the primary agent when it is likely to
finish in about one minute and gains no isolation or specialist benefit.

For long-context work, inventory first, exclude irrelevant directories, and read
coherent batches. Reuse stable prompt prefixes when the provider cache supports it.

## Observe quickly without declaring failure

- Observe at 30 seconds by default; this is not a timeout.
- For Luna medium, a silent first 30-second observation can be normal; inspect at
  about 60 seconds and diagnose only after two silent windows or hard evidence.
- For Luna high/max, allow roughly 90 seconds for the first tool or progress signal
  before diagnosis unless a hard error appears.
- Use at least about 3 minutes before declaring an ordinary worker stalled.
- Use at least about 5 minutes for broad scientific or long-context scans.
- Expand the budget using input size, tool count, expected output, worker estimate,
  and historical duration.
- Extend the window whenever messages, task state, files, stdout, CPU, PID, cell ID,
  or timestamps show progress.
- Enter diagnosis only after two consecutive observation windows show no progress.

An explicit HTTP, authentication, quota, rate-limit, process-exit, permission, or
binding-mismatch error may justify earlier diagnosis.

## Diagnose before fallback

Classify provider/API, agent initialization, message delivery, binding, tool
scheduling, external runtime, sandbox, state-return delay, or unknown. A generated
artifact plus stale chat status is a state-return delay until contrary evidence
appears, not a failed worker.

Before fallback, confirm all of:

1. two silent windows or explicit hard error;
2. no live external process or active tool cell;
3. no recent writes or heartbeats;
4. the previous worker is completed or interrupted;
5. partial changes are inspected and the new task describes their state.

## Sequential fallback routes

Use a new task ID and binding for every fallback.

```text
DeepSeek context failure
  -> retry once with smaller coherent batches when the provider is healthy
  -> terra_readonly_fallback_worker for a bounded read-only reconstruction
  -> primary agent

DeepSeek batch failure
  -> inspect partial diff and confirm no writer remains
  -> luna_medium_worker for clear bounded completion
  -> luna_high_worker when the remainder requires difficult reasoning
  -> terra_fallback_worker for routine bounded completion
  -> primary agent

Luna medium failure
  -> retry once only when diagnosis identifies a correctable prompt/tool issue
  -> luna_high_worker only when the failure is reasoning quality, not latency
  -> terra_fallback_worker when the task can be simplified or decomposed
  -> primary agent

Luna high failure
  -> luna_max_worker only for a still-bounded quality-first reasoning problem
  -> terra_fallback_worker when the task can be simplified or decomposed
  -> primary agent

Luna max failure
  -> terra_fallback_worker when the task can be simplified or decomposed
  -> primary agent
```

Choose `terra_readonly_fallback_worker` whenever reconstruction needs no writes;
its sandbox is actually read-only. Use write-capable `terra_fallback_worker` only
after the primary agent approves explicit files and validation commands. Never run
fallback workers concurrently on the same files. Never interpret slowness alone as
a provider failure.

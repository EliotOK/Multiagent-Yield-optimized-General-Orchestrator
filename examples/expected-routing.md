# Expected routing

| Request | Route | Why |
| --- | --- | --- |
| Rename one function | Primary agent | Startup cost dominates |
| Read 100 R files and map inputs/outputs | DeepSeek context reasoning | Broad cross-file inference |
| Apply an approved mechanical edit to 40 files | DeepSeek batch | Repetitive bounded writes |
| Fix an isolated failing test | Luna medium | Clear local implementation |
| Diagnose a subtle spatial CRS regression | Luna high | High local reasoning density |
| Resolve a quality-critical algorithmic edge case after high fails | Luna max | Explicit escalation |

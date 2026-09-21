# MYGO

**Multi-agent Yield-optimized General Orchestrator**

简体中文 | [English](README.md)

MYGO 是一个面向科研编程项目、优先支持 Windows 的 Codex skill。每次会话首次
调用时，它会让用户选择 Astra primary 或 Sol primary；随后把长上下文任务交给
DeepSeek V4.1 Flash（正式模型 ID：`deepseek-flash`），并按难度把收敛的编码任务
交给 Luna medium、high 或 max。

发布用 skill 保留内部名称 `research-multiagent-orchestrator`，以便 Codex 能够
明确识别它的用途和触发条件。

> 当前状态：`v0.1.0-beta.4`。这是非官方社区项目，与 OpenAI 或 DeepSeek
> 不存在隶属或背书关系。

## 工作方式

每个会话只允许一个选定的主 Agent，独占任务理解、科研判断、架构、worker 派发、
验收标准、最终代码审核和独立验证权。另一旗舰模型只能做有限的只读交叉复核，
不能成为第二控制器。

| 主控配置 | 可选交叉复核 |
| --- | --- |
| Astra primary | `sol_review_worker`，仅用于高风险或用户明确要求的第二意见 |
| Sol primary | `astra_review_worker`，默认 medium reasoning、单轮、只读 |

其余工作默认按下表路由：

| 任务类型 | 默认执行者 |
| --- | --- |
| 预计一分钟内的小任务 | 主 Agent |
| 大范围文件清单、日志和元数据梳理 | DeepSeek context（low） |
| 数据 lineage、schema 和跨文件变量审计 | DeepSeek context reasoning（high） |
| 已批准的重复性批量修改 | DeepSeek batch |
| 边界清楚的普通实现 | Luna medium |
| 困难的局部 debug 或重构 | Luna high |
| 明确以最高质量为先的升级任务 | Luna max |
| 失败任务的只读证据重建 | `terra_readonly_fallback_worker` |
| 失败任务的已批准有限写入恢复 | `terra_fallback_worker` |

MYGO 还会安装不可变 task/binding/state 协议、回退规则、等待策略以及 Windows
PowerShell 辅助脚本。

## 环境要求

- 支持自定义 subagent 的 Codex Desktop 或 Codex CLI；
- Windows PowerShell 5.1+ 或 PowerShell 7+；
- 安装本身不需要 Node.js 或 Python；只有发布验证需要 Python 3.11+。R、Python、
  Node.js、GIS 工具和 Git 仅在具体委派任务需要时安装；
- 只有使用 DeepSeek worker 时才需要环境变量 `DEEPSEEK_API_KEY`；
- Luna worker 需要当前 Codex 账户能够使用相应模型。

API key 不应写入项目文件、prompt、task 文件或 GitHub 仓库。

## 安装

### 可直接粘贴给 Codex 的安装 prompt

在新设备的 Codex 中新建一个任务，然后完整粘贴以下内容：

```text
请使用 $skill-installer 从下面的 GitHub 仓库安装 skill：
https://github.com/EliotOK/Multiagent-Yield-optimized-General-Orchestrator/tree/v0.1.0-beta.4

安装其中的 research-multiagent-orchestrator skill。安装后阅读它的 SKILL.md，
并为当前项目配置 MYGO 工作流。先以 preview 模式运行 install-workflow.ps1，
核对拟修改的路径和内容，再执行 apply，最后运行 verify-workflow.ps1。
不要输出、读取、保存或复制我的 DeepSeek API key。

先只检查 DEEPSEEK_API_KEY 是否存在，不得读取或输出其值。如果缺失，在 apply
之前停止，并让我本人在交互式 PowerShell 终端运行 scripts/set-deepseek-key.ps1，
随后彻底重启 Codex。不要要求我把 key 粘贴进聊天。如果我明确拒绝 DeepSeek，
或者现有规则明确暂停 DeepSeek，请在 install-workflow.ps1 和
verify-workflow.ps1 中都使用 -LunaOnly，不要要求我重新启用 DeepSeek。
如果没有修改全局 Codex 配置的授权，再同时使用 -ProjectOnly；不得修改
~/.codex/config.toml、~/.codex/agents 或全局 AGENTS.md。ProjectOnly 只改变安装
范围：若用户级 DeepSeek provider、全部兼容 agents 和 key 已存在，保留完整
DeepSeek 路由；否则写入前停止。LunaOnly 才会禁用 DeepSeek，并由主 Agent承担
长上下文任务。首次调用 MYGO 时让我选择 Astra primary 或 Sol primary；不要声称
skill 能静默切换当前任务的 root model。Terra 仅在失败已确认后顺序接替。最后告诉我是否需要彻底重启
Codex Desktop。
```

### 没有 DeepSeek API key 时

完整模式在没有 key 时仍可 preview，但 apply 会在写入任何文件之前停止并说明
处理方法。请用户本人在交互式终端运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\set-deepseek-key.ps1
```

输入过程不可见，key 不会出现在命令历史或脚本输出中。脚本会把 key 存为 Windows
用户环境变量，因为 Codex provider 需要从环境变量读取。Windows 环境变量并不是
加密密码库。请保护 Windows 账户，也不要将 key 放进聊天、命令行、项目文件或
日志。设置完成后必须彻底重启 Codex Desktop。

如果用户明确选择 `-LunaOnly`，则无需 key，仍然可以安装和使用：

- Codex 主 Agent；
- Luna medium/high/max；
- Terra 顺序兜底；
- task、binding、状态记录、验证和归档机制。

DeepSeek context、context reasoning 和 batch worker 暂时不可用。以后设置
`DEEPSEEK_API_KEY` 后，需要不带 `-LunaOnly` 重新运行项目安装并彻底重启 Codex
Desktop，才能启用 DeepSeek 路由；无需重新下载 skill。

使用 `-LunaOnly` 时，安装器不会写入 DeepSeek provider，也不会安装或启用任何
DeepSeek worker。若再加 `-ProjectOnly`，安装器只修改当前项目，完全不触碰用户级
Codex 配置。项目描述符会记录 `deepseek_enabled = false`，任务创建脚本也会拒绝
误派发 DeepSeek 任务。`ProjectOnly` 只安装项目协议和路由说明；设备必须已经配置
好本次选择的 Luna/Terra agents；完整模式还要求 DeepSeek agents 和 provider 已
存在。安装器只读验证这些前置条件，不会修改用户级文件。

### 手动安装到项目

Skill 安装完成后，在项目根目录先预览修改：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\install-workflow.ps1 `
  -ProjectRoot "D:\path\to\project" `
  -ForceAgentUpdate
```

核对输出后增加 `-Apply` 再运行一次。安装器只更新受管理的配置块，将可恢复
备份写入 `.codex\diagnostics\backups` 或用户 Codex 备份目录，并拒绝自动覆盖
检测到的旧版 singleton 全局协议。

彻底重启 Codex 后运行验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\verify-workflow.ps1 `
  -ProjectRoot "D:\path\to\project"
```

## 使用

在 Codex 中可以这样开始科研任务：

```text
请使用 $research-multiagent-orchestrator 处理这个科研编程任务。
如果这是本会话第一次调用，请让我选择 Astra primary 或 Sol primary。科研解释、
派发、整合和最终审核只能由选定的一个主 Agent负责；仅派发能够覆盖 worker 启动成本的工作；
主 Agent必须审核全部 worker diff 并独立运行适当验证。
```

更多示例见 [examples](examples)。

### 不改变拓扑，快速更换模型

MYGO 会创建 `.codex/mygo-model-map.json`。随附默认值为
`default_primary = ASK`、Astra 使用 `gpt-6-astra / medium`、Sol 使用
`gpt-5.6-sol / high`。`ASK` 表示不存在静默默认主控：每次会话首次调用时询问一次。

每个 worker 都保留稳定的技术角色，同时拥有一个来自 MyGO!!!!! 或 Ave Mujica 的
显示代号。代号只用于子任务线程名称，不会把角色人格注入科研判断。修改 map 中的
model、provider、reasoning effort 或 codename 后，先预览再应用：

子任务名称由“角色代号 + 简短任务描述”组成，例如用户可读形式
`Anon — schema audit`，Codex 派发接口中为 `anon_schema_audit`。随机后缀只保留在
不可变审计 ID 中，不再作为子任务显示名；同一会话出现重复描述时，使用
`anon_schema_audit_2` 这样的可读序号。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\configure-model-map.ps1 -ProjectRoot "D:\path\to\project"

powershell -NoProfile -ExecutionPolicy Bypass -File `
  <SKILL_PATH>\scripts\configure-model-map.ps1 -ProjectRoot "D:\path\to\project" -Apply
```

随后彻底重启 Codex 并运行 `verify-workflow.ps1`。map 不保存 API key。稳定角色键和
文件名属于协议标识；改变节点数量或职责仍需进行版本化的 skill 迁移。

## 科研安全原则

- DeepSeek worker 会把选中的 prompt 和文件上下文发送给第三方 provider。只读
  sandbox 只能阻止本地写入，不能阻止数据传输。参与者级数据、未公开受限数据、
  合同或保密材料、凭据默认必须留在主 Agent/Luna 路由；只有数据政策明确允许时
  才可交给 DeepSeek。创建任务默认 `LOCAL_ONLY`，DeepSeek 路由必须显式标记为
  `APPROVED_EXTERNAL` 或 `PUBLIC`；
- 原始数据视为不可变；
- 不得静默改变行数、单位、CRS、缺失值、分类学映射或分析假设；
- 同时只运行一个 delegated worker；该协议有意采用严格串行；
- 交叉复核 agent 只读且仅提供建议；只有选定的主 Agent可以派发写任务、整合和验收；
- 每次委派使用不可变 task 和 binding；
- worker 可能仍在写入时不得删除协调证据。

## 已知限制

- 当前确定性辅助脚本使用 PowerShell，因此优先支持 Windows；
- 某些 Codex 版本可能丢失 DeepSeek 自定义 Agent 的初始消息，binding fallback
  可以恢复任务，但会增加启动延迟；
- Luna 首次启动耗时可能波动，普通任务优先使用 medium，只有明确需要更高推理
  密度时才使用 high 或 max；
- skill 无法切换现有会话的 root model。若所选配置与当前 composer 模型不同，应
  先切换模型或新建匹配任务。Astra 交叉复核默认使用 medium reasoning 且只运行一轮，
  以控制额度消耗；
- 独立的临时“暖机”worker 通常不能预热后续的新 worker 会话。同线程复用仍是
  实验功能，只有 A/B 测试证明有效后才会默认启用。

## 开发与验证

在 Windows 上运行离线测试：

```powershell
powershell -NoProfile -File .\tests\validate-package.ps1
powershell -NoProfile -File .\tests\install-smoke.ps1
powershell -NoProfile -File .\tests\security-regression.ps1
```

PowerShell 7 用户可将 `powershell` 替换为 `pwsh`。GitHub Actions 会在 Windows
PowerShell 5.1 和 PowerShell 7 上运行全部三项测试，不需要 API key，也不会调用模型。

## 安全与许可证

安全问题请参阅 [SECURITY.md](SECURITY.md)。提交 issue 时不要包含 API key、原始
科研数据或私人项目路径。

本项目采用 MIT 许可证，见 [LICENSE](LICENSE)。

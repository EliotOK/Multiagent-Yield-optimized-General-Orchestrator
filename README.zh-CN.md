# MYGO

**Multi-agent Yield-optimized General Orchestrator**

简体中文 | [English](README.md)

MYGO 是一个面向科研编程项目、优先支持 Windows 的 Codex skill。它由 Codex
主 Agent 负责规划和审核，将长上下文任务交给 DeepSeek V4 Flash，并按难度将
收敛的编码任务交给 Luna medium、high 或 max。

发布用 skill 保留内部名称 `research-multiagent-orchestrator`，以便 Codex 能够
明确识别它的用途和触发条件。

> 当前状态：`v0.1.0-beta.2`。这是非官方社区项目，与 OpenAI 或 DeepSeek
> 不存在隶属或背书关系。

## 工作方式

Codex 主 Agent 始终负责任务理解、科研判断、架构、验收标准、最终代码审核和
独立验证。其余工作默认按下表路由：

| 任务类型 | 默认执行者 |
| --- | --- |
| 预计一分钟内的小任务 | 主 Agent |
| 大范围文件清单、日志和元数据梳理 | DeepSeek context（low） |
| 数据 lineage、schema 和跨文件变量审计 | DeepSeek context reasoning（high） |
| 已批准的重复性批量修改 | DeepSeek batch |
| 边界清楚的普通实现 | Luna medium |
| 困难的局部 debug 或重构 | Luna high |
| 明确以最高质量为先的升级任务 | Luna max |

MYGO 还会安装不可变 task/binding/state 协议、回退规则、等待策略以及 Windows
PowerShell 辅助脚本。

## 环境要求

- 支持自定义 subagent 的 Codex Desktop 或 Codex CLI；
- Windows PowerShell 5.1+ 或 PowerShell 7+；
- 示例冒烟测试需要 Node.js；科研项目建议另外安装 R 和 Python；
- 只有使用 DeepSeek worker 时才需要环境变量 `DEEPSEEK_API_KEY`；
- Luna worker 需要当前 Codex 账户能够使用相应模型。

API key 不应写入项目文件、prompt、task 文件或 GitHub 仓库。

## 安装

### 可直接粘贴给 Codex 的安装 prompt

在新设备的 Codex 中新建一个任务，然后完整粘贴以下内容：

```text
请使用 $skill-installer 从下面的 GitHub 仓库安装 skill：
https://github.com/EliotOK/Multiagent-Yield-optimized-General-Orchestrator

安装其中的 research-multiagent-orchestrator skill。安装后阅读它的 SKILL.md，
并为当前项目配置 MYGO 工作流。先以 preview 模式运行 install-workflow.ps1，
核对拟修改的路径和内容，再执行 apply，最后运行 verify-workflow.ps1。
不要输出、读取、保存或复制我的 DeepSeek API key。

如果当前环境没有 DEEPSEEK_API_KEY，或者现有规则明确暂停 DeepSeek，请在
install-workflow.ps1 和 verify-workflow.ps1 中都使用 -LunaOnly，不要要求我重新
启用 DeepSeek。如果没有修改全局 Codex 配置的授权，再同时使用 -ProjectOnly；
不得修改 ~/.codex/config.toml、~/.codex/agents 或全局 AGENTS.md。在受限模式中，
长上下文任务由主 Agent处理；编码任务按难度交给 Luna medium/high/max；Terra
仅在 Luna 已确认失败后顺序接替。最后告诉我是否需要彻底重启 Codex Desktop。
```

### 没有 DeepSeek API key 时

仍然可以安装和使用：

- Codex 主 Agent；
- Luna medium/high/max；
- Terra 顺序兜底；
- task、binding、状态记录、验证和归档机制。

DeepSeek context、context reasoning 和 batch worker 暂时不可用。以后设置
`DEEPSEEK_API_KEY` 并彻底重启 Codex Desktop 后即可启用，不需要重新安装 skill。

使用 `-LunaOnly` 时，安装器不会写入 DeepSeek provider，也不会安装或启用任何
DeepSeek worker。若再加 `-ProjectOnly`，安装器只修改当前项目，完全不触碰用户级
Codex 配置。项目描述符会记录 `deepseek_enabled = false`，任务创建脚本也会拒绝
误派发 DeepSeek 任务。`ProjectOnly` 只安装项目协议和路由说明；设备必须已经通过
其他方式配置好兼容的 Luna agents，否则它不会自行提供可调用的 Luna worker。

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
科研解释和最终审核由主 Agent负责；仅派发能够覆盖 worker 启动成本的工作；
主 Agent必须审核全部 worker diff 并独立运行适当验证。
```

更多示例见 [examples](examples)。

## 科研安全原则

- 原始数据视为不可变；
- 不得静默改变行数、单位、CRS、缺失值、分类学映射或分析假设；
- 同时最多允许一个可写 worker；
- 每次委派使用不可变 task 和 binding；
- worker 可能仍在写入时不得删除协调证据。

## 已知限制

- 当前确定性辅助脚本使用 PowerShell，因此优先支持 Windows；
- 某些 Codex 版本可能丢失 DeepSeek 自定义 Agent 的初始消息，binding fallback
  可以恢复任务，但会增加启动延迟；
- Luna 首次启动耗时可能波动，普通任务优先使用 medium，只有明确需要更高推理
  密度时才使用 high 或 max；
- 独立的临时“暖机”worker 通常不能预热后续的新 worker 会话。同线程复用仍是
  实验功能，只有 A/B 测试证明有效后才会默认启用。

## 开发与验证

在 Windows 上运行离线测试：

```powershell
pwsh -NoProfile -File .\tests\validate-package.ps1
pwsh -NoProfile -File .\tests\install-smoke.ps1
```

GitHub Actions 会运行相同测试，不需要 API key，也不会调用模型。

## 安全与许可证

安全问题请参阅 [SECURITY.md](SECURITY.md)。提交 issue 时不要包含 API key、原始
科研数据或私人项目路径。

本项目采用 MIT 许可证，见 [LICENSE](LICENSE)。

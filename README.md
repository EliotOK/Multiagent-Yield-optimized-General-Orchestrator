# MYGO

![白龙 GPT 举着喇叭催稿，DeepSeek 抱来资料，GLM 写代码，Gemini 画图，Kimi 审稿。](docs/images/mygo-cover.png)

[English](README.en.md)

MYGO 是一个 Codex 插件，让你在同一个聊天里找不同模型一起干活。比如排查一个失败的测试，可以让 DeepSeek 找报错、GLM 想修法、Luna 改代码。你继续和当前的 Codex 对话，由它分工、检查结果，再告诉你改了什么。

## 安装插件

在要安装的电脑上打开 Codex，把下面这句话发给它：

> 帮我从 GitHub 仓库 EliotOK/Multiagent-Yield-optimized-General-Orchestrator 安装并配置 MYGO 插件。先检查本机已有的 Magpie 和模型密钥，需要我输入密钥或重启时提醒我。配好后，在当前聊天派一个 DeepSeek 原生子代理算 17 × 23。

Windows x64 支持自动配置，需要较新的 Codex Desktop 和 Python 3.11 或更高版本。密钥只在本机密码窗口输入。看到 **DeepSeek 的子代理记录**，点开能看到它回答 **391**，就跑通了。macOS 和 Linux 需要先自行配置 Magpie。[手动配置说明](mygo/references/model-routing.md)

<details>
<summary>自己用命令安装或更新</summary>

在终端运行：

```powershell
codex plugin marketplace add EliotOK/Multiagent-Yield-optimized-General-Orchestrator
codex plugin add mygo@mygo
```

安装后重新打开 Codex，发送 `$mygo 打开 MYGO 设置`。按面板提示接入供应商、启用原生子代理。以后更新只需运行 `codex plugin marketplace upgrade mygo`。

</details>

## 平时怎么用

在请求前加上 `$mygo`，直接说你想做什么。可以让 Codex 自己分工，也可以点名：

> $mygo 这次更新后有个测试挂了。让 DeepSeek 从这份公开的测试日志里找出第一处报错，GLM 提一个最小改法，Luna 改好并重跑测试。最后告诉我原因和结果。

默认让 **DeepSeek** 查日志、找资料，**GLM** 写代码草案，**Luna** 改文件、跑测试，**Kimi** 做方案和复核，**Gemini** 写文案、看设计。想换型号或职责，发送 `$mygo 打开 MYGO 设置`，在「模型与分工」里选好后点「保存分工」。

要用 Qwen 等其他模型，先在「供应商密钥」里点「添加供应商」，填完密钥后刷新。再从已接入的型号里选一个分配职责。需要时，点「同步所选模型」。

交给外部模型的材料会发给对应供应商。只想分享一段日志时，可以在请求里写明「只把这段日志发给 DeepSeek」。

[旧版 PowerShell 工作流](mygo/references/legacy-workflow.md) · [安全问题反馈](SECURITY.md) · [代码许可证](LICENSE)

封面为 AI 绘制，角色形象参考 [ZipZipPipe 的 AI 娘系列](https://www.bilibili.com/opus/1233069202138464289)。DeepSeek 鲸鱼娘原角色由上善无形创作。

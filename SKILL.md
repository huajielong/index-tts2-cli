---
name: index-tts2-cli
description: 用 IndexTTS2 在本地把文本合成为语音。当用户需要合成语音、文本转语音、TTS、配音、朗读、克隆音色、生成旁白、给视频配解说、或调整说话的情感语气时使用。支持零样本音色克隆（用一段参考音频复制音色）与四种情感控制方式（音色自带情感 / 情感参考音频 / 八维情感向量 / 情感描述文本），中英文混合与拼音注音。
---

# IndexTTS2 语音合成

本地部署的 IndexTTS2（Bilibili 零样本 TTS）。用 `scripts/indextts2.*` 驱动，**默认走常驻守护进程**，模型只加载一次。

## 快速开始

Windows 用 `.cmd`，bash / Git Bash 用 `.sh`：

```bash
D:\index-tts2-cli\scripts\indextts2.cmd say "你好，欢迎使用。" --voice voice_01 --json
bash /d/index-tts2-cli/scripts/indextts2.sh say "你好，欢迎使用。" --voice voice_01 --json
```

成功时 stdout 是**一行 JSON**（全 ASCII），进度和提示都在 stderr：

```json
{"ok": true, "output_path": "D:\\...\\a.wav", "audio_seconds": 3.23, "warnings": [], "daemon": {"was_cold_start": true}}
```

读 `output_path` 拿音频（22050 Hz / 单声道 / 16-bit PCM）。

## 平台支持

| 平台 | 环境 | 状态 |
|---|---|---|
| Windows + NVIDIA | 自带打包 venv，开箱即用 | ✅ 已实测 |
| Linux + NVIDIA | 首次 `setup` 用 uv 现场建 | ✅ 已实测 |
| Docker | 镜像内 uv 建 | ✅ 已实测 |
| macOS Apple Silicon | 首次 `setup`，走 MPS | ⚠️ 实验性，未验证 |

模型权重（8.5 GB）可跨平台复制，Python 环境不行。没有可用环境时 `say` / `serve` 会自动 `setup`（`config.json` 的 `auto_bootstrap`）。细节见 `references/deployment.md`。

## 五条硬规则

1. **不要凭空猜音色名。** 先跑 `indextts2 voices list --json`。`examples/` 下的 `voice_01`…`voice_12` 已自动注册，开箱可用。
2. **长文本一律走 `--text-file`**，不要硬塞进命令行——中文长文本里的引号、`!`、`&`、`%` 在 conhost / bash / PowerShell 多层转义下极易走样。
   ```bash
   indextts2 say --text-file script.txt --voice voice_01 --json
   echo "从管道读也行" | indextts2 say --text-file - --voice voice_01 --json
   ```
3. **第一次调用约 30 秒是正常的**，那是在加载模型；`daemon.was_cold_start` 会是 `true`，看到它就别重试。之后每次约 6 秒。新机器首次还要先建环境（可能几分钟到几十分钟），显式跑 `indextts2 setup` 进度更可见。
4. **预计超过 60 秒的任务用 `--background`**，拿 `job_id` 后用 `wait` 收结果：
   ```bash
   indextts2 say --text-file long.txt --voice voice_01 --background --json
   indextts2 wait j_abc123def456 --json
   indextts2 estimate --text-file long.txt --json   # 秒级估时，不加载模型
   ```
5. **`ok: true` 不等于音频完整**——截断等静默劣化只会出现在 `warnings` 里。每次都检查这个字段。

## 常用命令

| 目的 | 命令 |
|---|---|
| 看有哪些音色 | `indextts2 voices list --json` |
| 基础合成 | `indextts2 say "文本" --voice voice_01 --json` |
| 指定输出路径 | `… -o D:\out\a.wav` |
| 快速试听某音色 | `indextts2 voices preview voice_05 --json` |
| 补齐缺失的模型/权重 | `indextts2 setup`（齐备时秒回、不联网） |
| 环境自检 | `indextts2 doctor` |
| 守护进程状态/显存 | `indextts2 status` |
| 释放显存 | `indextts2 stop` |
| 浏览器工作台 | `indextts2 webui --open`（默认 `127.0.0.1:8790`） |
| 对外 HTTP API | `indextts2 api --api-key <key>`（默认 `127.0.0.1:8791`） |
| 全部参数说明 | `indextts2 schema` |

### 浏览器工作台与 HTTP API

两个服务都复用常驻守护进程，**不会额外加载模型**：

```bash
# 浏览器工作台：选音色 / 四种情感 / 调参 / 波形 / 试听 / 历史
indextts2 webui --open

# HTTP API：OpenAI 兼容 /v1/audio/speech + 原生 /v1/tts、/v1/jobs、/v1/voices
indextts2 api --api-key my-secret
```

默认只监听 `127.0.0.1`。要从别的机器访问，显式加 `--host 0.0.0.0`；API 请同时设置 `--api-key`（或 `INDEXTTS2_API_KEY`）。WebUI 没有内置登录，建议只在本机使用，或放在 VPN/带鉴权的反向代理后面。Docker 用法、端点细节和安全说明见 `references/webui.md` 与 `references/rest-api.md`。

## 情感控制速览

不传情感参数时用音色自带的情感。三种控制方式**互斥**（同时给会直接报错）：

```bash
# 模式1：另一段音频当情感参考（默认强度 0.65）
indextts2 say "文本" --voice voice_01 --emo-audio emo_sad --emo-alpha 0.65

# 模式2：八维向量，顺序 喜/怒/哀/惧/厌恶/低落/惊喜/平静（默认强度 1.0）
indextts2 say "文本" --voice voice_01 --emo-vec 哀=0.8

# 模式3：情感描述文本（默认强度 0.6，多花约 30% 时间）
indextts2 say "文本" --voice voice_01 --emo-text "委屈巴巴"
```

向量的两种写法、bias 归一化与完整规则见 `references/emotion.md`。想加速可加 `--fast`（beam 3→1，约快 3 倍，代价是韵律随机性下降）。

## 音色库

```bash
indextts2 voices add 旁白女声 D:\samples\a.wav --notes "女声，语气平稳" --json
indextts2 voices list --json
indextts2 voices rename 旁白女声 narrator
indextts2 voices rm narrator
```

`--voice` 接受音色名、内容 id 或音频文件路径。参考音频超过 15 秒会自动截断。细节见 `references/voices.md`。

## 参考文件（按需读取）

| 需要什么 | 读哪份 |
|---|---|
| 完整命令面、全局选项、`say` 全部生成参数 | `references/cli.md` |
| 情感模式细节、八维向量、bias 归一化 | `references/emotion.md` |
| 音色增删改查、自动发现、参考音频缓存 | `references/voices.md` |
| JSON 输出字段、错误结构、退出码 | `references/output-contract.md` |
| 浏览器工作台、上传音色、端口与安全 | `references/webui.md` |
| 对外 HTTP API、OpenAI 兼容、curl/SDK 示例 | `references/rest-api.md` |
| 直接调用守护进程的内部 HTTP 接口 | `references/http-api.md` |
| 报错、变慢、显存不足、音频截断 | `references/troubleshooting.md` |
| 换平台、Linux/macOS/Docker、环境变量 | `references/deployment.md` |
| 架构、状态目录、改代码前的实现约束 | `references/internals.md` |

正常合成只需要本文件；上表里的文档**只在对应场景出现时读**。

## 出错时

退出码可以直接分流：`2` 用法/参数、`3` 音色不存在、`4` 守护进程启动失败、`5` 队列满、`6` 显存不足、`7` 推理失败、`8` 守护进程被毒化后退役。完整表见 `references/output-contract.md`。

失败时 JSON 的 `error.hint` 是一条**可执行的下一步**，`error.log_tail` 已内联日志尾部——多数情况下照做即可，不必再跑诊断命令。疑难症状先查 `references/troubleshooting.md` 的症状速查表。

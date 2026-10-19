# 命令行参考

完整的命令面、全局选项与 `say` 参数。日常合成看 `SKILL.md` 的命令速查就够了；需要调参、写脚本或确认某个参数的边界时再读这份。

## 1. 命令面

```
indextts2 [全局选项] <命令> [命令选项]

say       把文本合成为语音
wait      等待一个后台任务并取回结果
voices    音色库：list / add / rm / rename / preview
serve     前台运行守护进程（客户端以 detached 方式拉起同一个命令）
stop      停止守护进程（--force 强制）
status    守护进程状态 / 显存 / 队列
doctor    环境自检
estimate  只算分句与预估耗时，不加载模型
schema    输出机器可读的参数说明
webui     启动浏览器语音合成工作台（默认 127.0.0.1:8790）
api       启动对外 HTTP API（默认 127.0.0.1:8791）
```

### 全局选项

| 选项 | 说明 |
|---|---|
| `--json` | stdout 只输出一行 JSON。**可以写在命令前或命令后**，两种位置等价 |
| `--pretty` | 配合 `--json`，缩进输出便于人读 |
| `--timeout <秒>` | 客户端等待任务的秒数上限（默认 3600） |
| `--project-dir <路径>` | 覆盖 IndexTTS2 项目目录 |
| `--port <端口>` | 覆盖守护进程端口（默认 8788，被占用时向上扫到 8800） |
| `--allow-network` | 允许 Hugging Face 联网（默认离线，只读本地缓存） |

## 2. `say` 的参数

### 输入

| 选项 | 说明 |
|---|---|
| `<text>`（位置参数） | 要合成的文本 |
| `--text-file <路径>` | 从文件读文本；`-` 表示从 stdin 读。**长文本推荐** |
| `--voice` / `-v` | 音色名、内容 id、或音频文件路径 |
| `--output` / `-o` | 输出 wav 路径。默认写到 `<skill>/runtime/out/indextts2_<时间戳>_<pid>.wav` |

### 生成参数

全部显式传给上游，结果里的 `params` 字段会回显真正生效的值。

| 参数 | 范围 | 默认 | 说明 |
|---|---|---|---|
| `--top-p` | 0.0–1.0 | 0.8 | 核采样累积概率阈值 |
| `--top-k` | 0–100 | 30 | `0` 表示禁用（等价于 `None`） |
| `--temperature` | 0.05–2.0 | 0.8 | 越低越稳定 |
| `--length-penalty` | −2.0–2.0 | 0.0 | |
| `--num-beams` | 1–10 | 3 | **默认 3 意味着三倍 GPT 自回归开销** |
| `--repetition-penalty` | 0.1–20.0 | 10.0 | 偏高是上游默认 |
| `--max-mel-tokens` | 50–1815 | 1500 | 单段生成上限；太小会截断音频（见 `warnings`） |
| `--max-text-tokens-per-segment` | 20–600 | 120 | 分句 token 上限，越大分句越长 |
| `--interval-silence` | 0–10000 | 200 | 段间静音毫秒数 |
| `--seed` | 任意整数 | 无 | 用于复现同一段输出 |
| `--fast` | 开关 | 关 | 等价于 `--num-beams 1`，速度约快 3 倍 |

上限的来源：`max_text_tokens` = 600 和 `max_mel_tokens` = 1815 都来自 `checkpoints/config.yaml` 的 `gpt` 段，超过会让位置编码越界或突破 s2mel 的 `setup_caches(max_seq_length=8192)`。这些边界在**客户端本地**就会被拦下，不会走到 GPU。

### 运行方式

| 选项 | 说明 |
|---|---|
| `--background` | 提交后立刻返回 `job_id`，用 `indextts2 wait <job_id>` 收结果 |
| `--no-daemon` | 本进程直接加载模型跑一次，不碰守护进程（与 `--background` 互斥） |

### 情感参数

`--emo-audio` / `--emo-vec` / `--emo-text` / `--emo-alpha` / `--emo-mode` 见 `references/emotion.md`。

## 6. `webui` / `api`

两个命令都是**前台常驻服务**，复用常驻守护进程，不会第二次加载模型。Ctrl+C 只停止前端服务，不停止守护进程（用 `indextts2 stop` 释放显存）。

```bash
indextts2 webui [--open] [--host HOST] [--listen-port PORT]
indextts2 api   [--api-key KEY] [--cors] [--host HOST] [--listen-port PORT]
```

| 选项 | 说明 |
|---|---|
| `--host` | 监听地址，默认 `127.0.0.1`；`0.0.0.0` 才对外开放 |
| `--listen-port` | 前端服务端口。默认 webui `8790`、api `8791`；**不是**守护进程端口 |
| `--preload` / `--no-preload` | 是否在启动时后台加载守护进程（默认开） |
| `--request-timeout` | 同步请求最多等待秒数（默认 1800；异步 job 不受限制） |
| `--open` | 仅 webui：就绪后自动打开浏览器 |
| `--api-key` | 仅 api：Bearer/`X-API-Key` 鉴权，也可用 `INDEXTTS2_API_KEY` |
| `--cors` | 仅 api：允许浏览器跨域访问 |

端口语义不要混淆：**全局 `--port` 始终是守护进程端口**，`--listen-port` 才是 WebUI/API 自己的端口。端口被占用时命令直接以退出码 4 失败并提示换端口，不会静默扫描。

完整端点与示例见 `references/webui.md` 和 `references/rest-api.md`。

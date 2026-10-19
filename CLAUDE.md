# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

这是 IndexTTS2（Bilibili 零样本 TTS）的本地封装，提供三套入口：

- `scripts/indextts2.py`：面向智能体的 CLI（`say`/`voices`/`wait`/`doctor`/...）
- `indextts2 webui`：零依赖浏览器工作台（默认 `127.0.0.1:8790`）
- `indextts2 api`：对外 HTTP API（默认 `127.0.0.1:8791`，含 OpenAI 兼容端点）

核心设计是**客户端 / 常驻守护进程分离**：CLI、WebUI、API 都不加载模型，只通过本机 HTTP 把请求交给 `serve` 守护进程。模型只加载一次，这是所有性能与架构决策的前提。

文档语言是中文；用户可见输出、注释、文档保持中文风格。面向用户看 `README.md`，面向智能体看 `SKILL.md`，实现细节看 `references/`。

## 常用命令

本仓库不是标准 Python 包开发环境，**没有 pytest / ruff / flake8 配置，也没有自动化测试套件**。验证依赖 `py_compile` 和真实端到端命令。

Windows 使用 bundled venv：`venv/python.exe`。Linux/macOS 使用 `venv/bin/python`。启动器等价关系：

```text
scripts\indextts2.cmd  ≡  bash scripts/indextts2.sh
scripts\indextts2-webui.cmd  ≡  bash scripts/indextts2-webui.sh
scripts\indextts2-api.cmd    ≡  bash scripts/indextts2-api.sh
```

### 编译 / 静态检查

```bash
venv/python.exe -m py_compile scripts/indextts2.py scripts/itts/*.py
```

这是当前唯一的静态检查。改动后至少跑这个。

### 环境与资源

```bash
venv/python.exe scripts/indextts2.py doctor --quick   # 不 import torch，约 1 秒
venv/python.exe scripts/indextts2.py doctor           # 含 GPU/torch 检查，约 8 秒
venv/python.exe scripts/indextts2.py setup            # 补齐环境/模型，已齐备时不联网
venv/python.exe scripts/indextts2.py status
venv/python.exe scripts/indextts2.py stop --json
```

### CLI 烟测（推荐顺序）

```bash
venv/python.exe scripts/indextts2.py voices list --json
venv/python.exe scripts/indextts2.py estimate "测试。" --json
venv/python.exe scripts/indextts2.py say "回归测试。" --voice voice_01 --fast --json
venv/python.exe scripts/indextts2.py say "向量测试。" --voice voice_01 --emo-vec 哀=0.8 --fast --json
```

首次 `say` 会拉起守护进程并加载模型，约 **25~45 秒**；之后每次约 **5~10 秒**。`--fast`（beam 3→1）用于加快测试。没有“单个测试”命令；单点验证就是上述某一条命令。

### WebUI / API 烟测

`api` / `webui` 是前台长驻服务：在 Claude Code 里用 Bash 工具的 `run_in_background` 启动，或另开终端。测试完记得停掉前端进程；守护进程可用 `stop` 单独释放显存。

```bash
# 后台起 API（--no-preload 可避免测试时加载模型）
venv/python.exe scripts/indextts2.py api --listen-port 8791 --api-key test-key --json

curl -s http://127.0.0.1:8791/health
curl -s -H "Authorization: Bearer test-key" http://127.0.0.1:8791/v1/voices
curl -s -X POST http://127.0.0.1:8791/v1/tts \
  -H "Authorization: Bearer test-key" -H "Content-Type: application/json" \
  -d '{"text":"API smoke.","voice":"voice_01","fast":true}'

# OpenAI 兼容（默认 mp3，需要 ffmpeg）
curl -s -X POST http://127.0.0.1:8791/v1/audio/speech \
  -H "Authorization: Bearer test-key" -H "Content-Type: application/json" \
  -d '{"input":"OpenAI smoke.","voice":"voice_01","response_format":"mp3","fast":true}' \
  -o /tmp/speech.mp3

# WebUI
venv/python.exe scripts/indextts2.py webui --listen-port 8790 --no-preload --json
curl -s http://127.0.0.1:8790/api/status
curl -s http://127.0.0.1:8790/api/config
```

Windows 中文控制台用 `curl -d` 直接传中文可能按 GBK 发出，服务端会报 UTF-8 解码错误；改用 UTF-8 文件 + `--data-binary @body.json`，或用 Python `requests`。

### Docker

```bash
docker build -t indextts2:cu128 .
docker run --rm --gpus all \
  -v /host/checkpoints:/app/checkpoints \
  -v "$PWD/out:/data/out" \
  indextts2:cu128 say "容器测试。" --voice voice_01 -o /data/out/a.wav
```

## 架构

### 请求主链路

```text
scripts/indextts2.py                 argparse + dispatch
  └─ itts/cmds.py                    cmd_say / cmd_webui / cmd_api / ...
       └─ itts/reqs.py               build_request：参数白名单、音色解析、情感模式、输出路径
            └─ itts/cli_net.py       ensure_daemon → POST /jobs → wait_for_job
                 └─ itts/srv.py      常驻守护进程：实例锁、HTTP、单 worker 队列、生命周期
                      └─ itts/engine.py  Engine.run → indextts/infer_v2.py:IndexTTS2.infer
                           └─ 原子写 wav（.partial-<job_id>.wav → os.replace）
```

`reqs.build_request` 是 CLI/WebUI/API 的唯一请求构造入口；改生成参数、情感模式、输出命名时优先改这里，不要在三个入口各写一份。

`--no-daemon` 是唯一绕过守护进程的路径：当前进程直接 `Engine.load()` 并跑一次，用于排障。

### 守护进程（`srv.py`）

- 先抢内核字节锁（`instance.lock`），再绑定端口、开始服务 `/health`，最后加载模型。加载期间 `/health` 已可用，`state=loading` 与 `state=failed` 可区分。
- 单 worker 串行执行；队列上限 `config.json.max_pending`（默认 4），超出返回 503。
- `idle_timeout` 默认 3600 秒；空闲时自动退出释放显存，下一个客户端命令会重新拉起。
- 端口不是身份标识：Windows 上 `allow_reuse_address` 必须关闭，客户端用 `instance_id` 校验实际连到的是不是同一个守护进程。
- 状态目录由 `project_dir` 派生，保证同一份模型目录永远只有一个守护进程。不要在 skill 目录里放锁/状态。

### 前端服务（`websrv.py` / `api.py` / `webui.py`）

- `ServiceApp`：共享任务代理、音色增删、历史、健康快照、预加载线程、`job_meta`。
- `ServiceHandler`：JSON/二进制响应、Range（206）、鉴权、CORS、错误映射。
- `run_service`：绑定端口 → 后台 `serve_forever` → `on_ready` → 可选预加载 → SIGINT/SIGTERM 优雅退出。
- **前端进程绝对不 import torch**；所有合成走 `reqs` → `cli_net` → 守护进程。
- WebUI 页面是 `webui_page.py` 里的单个 HTML/CSS/JS 字符串，无 gradio、无外部 CDN；CSP 严格，Playwright 的 `wait_for_function` 会被 CSP 拦，测试时用轮询 `is_enabled`/`inner_text` 或 `locator.wait_for`。
- API 同时提供 OpenAI 兼容（`/v1/audio/speech`、`/v1/models`）和原生接口（`/v1/tts`、`/v1/jobs`、`/v1/voices`、`/v1/history`）。OpenAI 端点默认 `response_format=mp3`，非 wav 用 ffmpeg 转码。
- 端口语义：全局 `--port` 是**守护进程**端口；`--listen-port` 是 WebUI/API 自己的端口。默认 8788 / 8790 / 8791。
- 默认只监听 `127.0.0.1`。API 用 `--api-key` / `INDEXTTS2_API_KEY` 做 Bearer/`X-API-Key` 鉴权；WebUI 没有内置登录，`--host 0.0.0.0` 时必须自行加反向代理/VPN。

### 配置、环境与资源（`conf.py`）

- 路径优先级：`--project-dir` > `INDEXTTS2_HOME` > `config.json.project_dir` > 项目自身。
- `load_config()` 解析配置；`refresh_paths()` 在 `--project-dir` 变更后重算 state/out/python。
- `setup_child_env()` 在任何 torch/HF import 之前设置离线、UTF-8、MPS fallback 等环境变量。
- `activate_project()` 做三件事：`os.chdir(project_dir)`、设置 HF 缓存绝对路径、把项目根插入 `sys.path` 并清理 cwd/空串项。
- `bootstrap_env()` 用 `uv sync --frozen`（不要用 `--locked`，随包 lock 与 pyproject 在 uv 0.11 下不一致）；新环境建到 `venv.new/`，验证后换名。
- `ensure_resources()`：资源齐备时只做本地文件检查、零网络；缺失且 `auto_download` 时只补缺口（HF 失败回退 ModelScope）。

### 参数与音色

- `spec.py` 是参数白名单/范围/情感模式契约。未知参数必须提前在本地拒绝，不能透传给 `infer()`（会在模型加载后才抛 transformers 的 `ValueError`）。
- `spec.EMO_VECTOR_ORDER` 顺序与 `infer_v2.py` 的 `desired_vector_order` 严格一致；不能改。
- 模式 2 必须由 `Engine._build_infer_kwargs` 调 `normalize_emo_vec(apply_bias=True)`，上游 `infer()` 不会自己调。
- `voices.py` 把参考音频归一化成单声道 16-bit PCM WAV，按内容哈希缓存在 `state_dir/voices/<sha1>.wav`；上游缓存按路径字符串比较，所以必须这样做。
- 音色名会作为文件名：`validate_voice_name` 拦路径分隔符、Windows 保留设备名、首尾点等；`output_name` 复用同一规则。

### 输出契约

- `--json` 时 stdout **恰好一行 JSON**，`ensure_ascii=True`（全 ASCII）；进度/提示全部走 stderr。
- 失败时 stdout 仍是一行 `{"ok":false,"error":{...}}`，并以约定退出码结束：2 用法、3 音色、4 守护进程、5 队列满、6 OOM、7 推理、8 毒化、9 强制中断。
- `ok: true` 不代表音频完整；截断等静默劣化只在 `warnings` 里。改动 `engine.run` 时不要吞掉 warnings。
- 改退出码/字段必须同步 `references/output-contract.md`；改 CLI 参数必须同步 `spec.py`、`references/cli.md`、`SKILL.md`/`README.md`。

## 实现约束（改代码前必读）

- `indextts/infer_v2.py` 在 import 时**无条件**把 `HF_HUB_CACHE` 覆写成相对路径 `./checkpoints/hf_cache`，所以必须先 `activate_project()`（chdir）再 import。
- 脚本模式下 `sys.path[0]` 是脚本目录，不包含 cwd；`chdir` 和 `sys.path.insert` 是两件独立的事。
- `venv/Lib/site-packages/indextts/` 可能有一份打包副本；`import_infer_v2()` 会断言命中的模块在 `project_dir` 下。不要绕过它。
- Windows bundled venv 不是标准 virtualenv：解释器是 `venv/python.exe`，不是 `venv/Scripts/python.exe`；`venv/` 也在 PATH 上，ffmpeg 由此找到。
- `infer_v2.py` 里 `do_sample=True` 是硬编码的，不要暴露 `do_sample`；`verbose` 会打印整个 token 张量，也不要暴露。
- 上游 `infer()` 先 `os.remove(output_path)` 再写；engine 必须写 `.partial-<job_id>.wav` 再 `os.replace`。临时名**仍要 `.wav` 结尾**，因为 `torchaudio.save` 按扩展名分派编码器。
- `torch.cuda.synchronize()` 在推理后要做：CUDA 错误是异步的，不同步会以误导性形式在下一个任务爆出来。
- CUDA device-side assert / illegal memory access 是粘性的：守护进程必须退役换进程；OOM 不是，回收缓存后可以继续服务。
- Windows 控制台默认 GBK：入口已把 stdout/stderr 重配置为 UTF-8；JSON 一律 `ensure_ascii=True`。不要往 stdout 打调试信息。
- 参考音频超过 15 秒会被上游静默截断；engine 会把它写进 warnings。
- API/WebUI 只从 `out_dir` 提供 wav，必须做 `resolve()` 后的父目录检查和路径穿越检查；上传大小限制 20 MiB，请求体 32/64 MiB。
- 前端服务里 `ensure_daemon` 是串行化的（`daemon_lock`）；不要并发 spawn 守护进程。
- 不要修改 `checkpoints/`、`venv/` 这些大目录的内容；`.dockerignore` 已排除它们。模型/环境是平台绑定的，跨平台要重建。

## 关键文件

| 文件 | 作用 |
|---|---|
| `scripts/indextts2.py` | CLI 入口、argparse、全局选项、子命令注册 |
| `scripts/itts/cmds.py` | 子命令实现、dispatch、`Output` 输出分流 |
| `scripts/itts/reqs.py` | 共享请求构造、JSON 请求体解析、OpenAI 字段映射、任务调用 |
| `scripts/itts/cli_net.py` | 客户端 HTTP、按需拉起守护进程、错误翻译 |
| `scripts/itts/srv.py` | 守护进程：锁/端口/队列/worker/看门狗 |
| `scripts/itts/engine.py` | 模型加载、`infer()` 参数翻译、异常分类、原子输出 |
| `scripts/itts/conf.py` | 配置、解释器探测、自举、资源补齐、项目激活 |
| `scripts/itts/spec.py` | 参数白名单、情感模式、schema |
| `scripts/itts/voices.py` | 音色注册表、自动发现、内容寻址缓存 |
| `scripts/itts/websrv.py` | WebUI/API 共享 `ServiceApp`/`ServiceHandler`/`run_service`/转码 |
| `scripts/itts/api.py` | API 路由、OpenAI 兼容、OpenAPI |
| `scripts/itts/webui.py` + `webui_page.py` | WebUI 路由 + 单页 HTML/CSS/JS |
| `indextts/infer_v2.py` | 上游推理实现（vendored），不要轻易改 |
| `references/internals.md` | 实现约束的完整版 |
| `references/output-contract.md` | JSON 字段、退出码契约 |

## 改动检查清单

- 新增/修改 CLI 参数：`spec.py` → `indextts2.py` 参数 → `reqs.build_request` → `references/cli.md` / `SKILL.md` / `README.md`。
- 新增/修改 API/WebUI 端点：对应 handler → `references/rest-api.md` 或 `references/webui.md` → OpenAPI（API）→ README 端点表。
- 修改错误码/退出码：`errs.py` → `http_status_for`（前端）→ `references/output-contract.md`。
- 修改输出字段：`engine.run`/`cmds.cmd_say`/`reqs._finish` → `references/output-contract.md` / `references/rest-api.md`。
- 修改端口/环境变量：`indextts2.py` 参数 → `api.py`/`webui.py` → `references/deployment.md`/`README.md` → Dockerfile。
- 修改音色逻辑：`voices.py` → `references/voices.md`；注意并发写临时文件必须唯一命名。
- 改完至少跑：`py_compile` + `doctor --quick` + 一条 `say --fast --json`，以及受影响的 WebUI/API 端点。

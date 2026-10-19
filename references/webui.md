# 浏览器工作台（WebUI）

`indextts2 webui` 提供一个零依赖的单页工作台：选音色、四种情感控制、调参、异步生成、波形、试听、下载和最近历史。页面由 Python 标准库直接提供，不需要 gradio，也不访问任何外部 CDN。

## 启动

```bash
# Windows
scripts\indextts2-webui.cmd --open

# bash / Git Bash / Linux / macOS
bash scripts/indextts2-webui.sh --open

# 等价写法
indextts2 webui --open
```

默认地址：`http://127.0.0.1:8790`。`--open` 会在就绪后尝试打开默认浏览器；也可以在浏览器里手动打开。

```bash
# 指定端口（注意：不是守护进程的 --port）
indextts2 webui --listen-port 9000

# 只启动页面、不预先加载模型
indextts2 webui --no-preload

# 局域网访问（会警告没有内置登录）
indextts2 webui --host 0.0.0.0
```

端口被占用时会直接报 `LISTEN_BIND_FAILED`（退出码 4）并提示换 `--listen-port`，不会静默扫描。

## 界面功能

- **输入文本**：中英文混合；长文本自动分段。`Ctrl/⌘ + Enter` 直接生成。中文/English/情感示例可一键填入。
- **音色**：下拉选择 `examples/`、`prompts/` 和已登记音色；`试听` 用当前音色快速合成一句；`上传` 把参考音频登记为命名音色。
- **情感**：
  - `00 音色自带`：不额外传情感参数。
  - `01 情感参考`：选另一段音频作为情感参考，强度用 alpha 控制（默认 0.65）。
  - `02 八维向量`：喜/怒/哀/惧/厌恶/低落/惊喜/平静 八个滑块；服务端会做 bias 归一化。
  - `03 文字描述`：例如「委屈巴巴」；留空则使用正文。会多跑一次情感分类模型。
- **高级参数**：`top_p` / `top_k` / `temperature` / `length_penalty` / `num_beams` / `repetition_penalty` / `max_mel_tokens` / `max_text_tokens_per_segment` / `interval_silence`；另有 `seed` 和 `output_name`。
- **快速模式**：等价于 `num_beams=1`，约快 3 倍；勾选后 beam 滑块会被禁用。
- **异步生成**：提交后立刻返回 `job_id`，页面轮询守护进程进度，显示阶段、百分比和排队位置；排队中的任务可以取消。
- **监听器**：从生成的 wav 解码真实波形；显示音频时长、耗时、RTF、分段数、音色、情感模式和 warnings；可展开原始结果 JSON。
- **最近生成**：`runtime/out`（或 `INDEXTTS2_OUT_DIR`）里的 wav，可播放/下载。

## 上传参考音频

页面把文件读成 base64，POST 到 `/api/voices`，服务端先尝试真正解码一次（需要 ffmpeg；失败不会登记），再复制进 `<skill>/voices/` 并写入 `voices/voices.json`。

- 支持 `wav/mp3/flac/m4a/aac/ogg/opus/webm`。
- 上限 20 MiB；参考音频 3~15 秒就够（超过 15 秒会被上游截断）。
- Docker 镜像里的 `voices/` 在只读镜像层；要上传就挂载：`-v /host/voices:/app/voices`。
- 音色名会作为文件名使用，不能包含 `/ \ : * ? " < > |`，也不能是 Windows 保留设备名。

## 后端端点（调试用）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/` | 单页 HTML |
| GET | `/api/config` | 音色、参数元数据、情感默认值 |
| GET | `/api/status` | 本服务 + 守护进程快照（未运行时也返回 200） |
| GET | `/api/voices` | 音色列表 |
| POST | `/api/voices` | base64 上传并登记音色 |
| DELETE | `/api/voices/<name>` | 删除已登记音色 |
| POST | `/api/jobs` | 异步提交 → 202 `{job_id, queue_position}` |
| GET | `/api/jobs/<id>` | 查询进度/结果 |
| DELETE | `/api/jobs/<id>` | 取消排队中的任务 |
| GET | `/api/audio/<job_id>` | 任务音频（支持 Range 和 `?download=1`） |
| GET | `/api/audio-file/<name>` | 按文件名取 out_dir 内的 wav |
| GET | `/api/history?limit=12` | 最近产物 |

页面与服务同源，所以不需要 CORS。音频响应支持 `Range`（206），浏览器播放器才能拖动进度。

## 与守护进程的关系

- 页面进程**不 import torch**，所有合成请求都转发给常驻守护进程。
- `--preload`（默认）在后台拉起守护进程；页面打开时就能在右上角看到「加载中 phase」或「就绪」。
- 守护进程只有单 worker，多个标签页/请求会排队；页面会显示排队位置。
- 前端 Ctrl+C 只停止 WebUI，守护进程继续运行；需要释放显存时执行 `indextts2 stop`。
- 守护进程默认空闲 1 小时后退出（`config.json` 的 `idle_timeout`）；下一次生成会自动重新拉起。

## 安全

默认只监听 `127.0.0.1`，且 WebUI **没有内置登录**。`--host 0.0.0.0` 会打印警告——任何能访问该端口的人都可以上传音色和发起合成。需要远程访问时，请放在 VPN 或带鉴权的反向代理后面；只给程序调用时优先用 `indextts2 api --api-key`。

## Docker

```bash
docker run --rm -p 8790:8790 --gpus all \
  -v /host/checkpoints:/app/checkpoints \
  -v /host/voices:/app/voices \
  -v /host/out:/data/out \
  indextts2:cu128 webui --host 0.0.0.0
```

然后访问 `http://<宿主机>:8790`。注意必须显式 `--host 0.0.0.0`，否则容器内只绑 `127.0.0.1`，端口映射访问不到。`INDEXTTS2_OUT_DIR` 在镜像里已设为 `/data/out`，挂载后历史记录会持久化。

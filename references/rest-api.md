# 对外 HTTP API

`indextts2 api` 启动一个面向外部程序的 HTTP 服务，同时提供两套接口：

- **OpenAI 兼容**：`POST /v1/audio/speech`、`GET /v1/models`
- **原生**：`/v1/tts`、`/v1/jobs`、`/v1/voices`、`/v1/history`

服务复用常驻守护进程，不额外加载模型。默认只监听 `127.0.0.1:8791`。

## 启动

```bash
# 本机 + 鉴权
indextts2 api --api-key my-secret

# 等价写法
scripts\indextts2-api.cmd --api-key my-secret       # Windows
bash scripts/indextts2-api.sh --api-key my-secret   # bash

# 对外开放
indextts2 api --host 0.0.0.0 --api-key my-secret

# 浏览器跨域（前端直连 API 时）
indextts2 api --api-key my-secret --cors
```

环境变量：`INDEXTTS2_API_KEY`、`INDEXTTS2_API_PORT`。`--listen-port` 是 API 自己的端口，**不是**守护进程端口（后者仍用全局 `--port`）。

> 生产/常驻场景优先用 `INDEXTTS2_API_KEY`，不要把 key 写在命令行里（会出现在进程列表和 shell history 中）。

鉴权覆盖 `/v1/*`；`/health`、`/`、`/openapi.json` 免鉴权。支持：

```
Authorization: Bearer <key>
X-API-Key: <key>
```

未设置 key 时不鉴权；如果监听在非本机地址且没有 key，启动时会打印警告。

## 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 服务 + 守护进程快照（恒 200） |
| GET | `/` | 端点索引 JSON |
| GET | `/openapi.json` | OpenAPI 3 描述 |
| GET | `/v1/models` | OpenAI 风格模型列表（`indextts2`） |
| POST | `/v1/audio/speech` | OpenAI 兼容，返回音频二进制 |
| POST | `/v1/tts` | 原生同步，返回结果 JSON |
| POST | `/v1/jobs` | 异步提交 → 202 |
| GET | `/v1/jobs/<job_id>` | 查询任务 |
| DELETE | `/v1/jobs/<job_id>` | 取消排队中的任务（推理中返回 409） |
| GET | `/v1/audio/<job_id>` | 任务音频（Range / `?download=1`） |
| GET | `/v1/audio-file/<name>` | 按文件名取 out_dir 内的 wav |
| GET | `/v1/voices` | 音色列表 |
| POST | `/v1/voices` | base64 上传并登记音色 |
| DELETE | `/v1/voices/<name>` | 删除已登记音色 |
| GET | `/v1/history?limit=20` | 最近产物（上限 100） |

## 合成请求体（原生）

```json
{
  "text": "要合成的文本",
  "voice": "voice_01",
  "output_name": "optional.wav",
  "emo_mode": 2,
  "emo_vec": {"哀": 0.7, "平静": 0.2},
  "emo_alpha": 0.9,
  "seed": 42,
  "fast": false,
  "params": {
    "top_p": 0.8,
    "top_k": 30,
    "temperature": 0.8,
    "num_beams": 3,
    "max_mel_tokens": 1500,
    "max_text_tokens_per_segment": 120,
    "interval_silence": 200
  }
}
```

| 字段 | 说明 |
|---|---|
| `text` / `input` | 必填；`input` 是 OpenAI 风格别名。上限 20000 字符 |
| `voice` | 音色名、内容 id 或本机音频路径；省略时用 `default_voice` → `voice_01` → 第一个音色 |
| `output_name` | 只能是文件名（固定 `.wav`），落在输出目录；重名自动追加短哈希 |
| `emo_mode` | `0` 音色自带 / `1` 情感参考 / `2` 八维向量 / `3` 文字描述；不传则自动推断 |
| `emo_audio` | 模式 1 的音色名或音频路径 |
| `emo_vec` | 模式 2：8 元数组、`{"哀": 0.7}` 对象、或 `"哀=0.7"` 字符串；分量 0~1 |
| `emo_text` | 模式 3 的描述；留空用正文 |
| `emo_alpha` | 情感强度 0~1；默认 mode1 0.65 / mode2 1.0 / mode3 0.6 |
| `emo_random` | 模式 2 随机采样情感权重 |
| `seed` | 整数，用于复现 |
| `fast` | 等价于 `num_beams=1` |
| `params` | 生成参数对象；上面的生成参数也可以平铺在顶层（平铺优先） |

未知字段会返回 400，不会静默丢弃。`do_sample`、`verbose` 等上游死参数会被明确拒绝。

## 原生示例

```bash
curl -s -X POST http://127.0.0.1:8791/v1/tts \
  -H "Authorization: Bearer my-secret" \
  -H "Content-Type: application/json" \
  -d '{"text":"你好，这是 API 测试。","voice":"voice_01","fast":true}'
```

> **Windows 中文控制台注意**：Git Bash / cmd 可能会把 `-d` 里的中文按 GBK 发送，服务端会报 `'utf-8' codec can't decode...`。把 JSON 写进一个 UTF-8 文件，用 `curl --data-binary @body.json`，或者改用 Python `requests`。

响应是 `say --json` 的同一套字段，另外补了 `audio_url`：

```json
{
  "ok": true,
  "schema": 1,
  "job_id": "j_163a60fdd4cc",
  "output_path": "D:\\...\\api_20261019_210502_2216_0d0edd.wav",
  "audio_url": "/v1/audio/j_163a60fdd4cc",
  "fs_verified": true,
  "output_bytes": 100396,
  "sample_rate": 22050,
  "channels": 1,
  "audio_seconds": 2.276,
  "duration_s": 4.055,
  "rtf": 1.782,
  "text_segments": 1,
  "warnings": [],
  "params": { "emo_mode": 0, "num_beams": 1, "...": "..." },
  "voice": { "name": "voice_01", "id": "c7960075...", "source": "..." },
  "daemon": { "pid": 27848, "port": 8788, "was_cold_start": false }
}
```

> **`warnings` 必须检查**：`max_mel_tokens` 截断等静默劣化时任务仍然是 `ok: true`。

## 异步任务

```bash
JOB=$(curl -s -X POST http://127.0.0.1:8791/v1/jobs \
  -H "Authorization: Bearer my-secret" -H "Content-Type: application/json" \
  -d '{"text":"异步任务。","voice":"voice_01","fast":true}' \
  | python -c "import sys,json;print(json.load(sys.stdin)['job_id'])")

curl -s -H "Authorization: Bearer my-secret" \
  http://127.0.0.1:8791/v1/jobs/$JOB
```

`state` 取值：`queued` → `running` → `done` / `failed`。完成后 `result.audio_url` 指向 `/v1/audio/<job_id>`。排队中的任务可以 `DELETE /v1/jobs/<id>`；推理中的任务返回 409。

同步请求超过 `--request-timeout`（默认 1800 秒）会返回 504，并在错误体里带 `job_id`——任务仍在守护进程里继续执行，可以改走 `GET /v1/jobs/<id>` 继续等。

## OpenAI 兼容

```bash
curl -s -X POST http://127.0.0.1:8791/v1/audio/speech \
  -H "Authorization: Bearer my-secret" \
  -H "Content-Type: application/json" \
  -d '{"model":"indextts2","input":"OpenAI 兼容测试。","voice":"voice_01","response_format":"mp3"}' \
  -o speech.mp3
```

字段映射：

| OpenAI 字段 | 行为 |
|---|---|
| `input` | → `text` |
| `voice` | 本地音色名（不是 alloy/echo 之类的 OpenAI 音色） |
| `instructions` | 未显式给其它情感参数时 → `emo_text`（模式 3） |
| `model` | 忽略 |
| `speed` | 只支持 `1.0`；其它值返回 400（模型本身不支持变速） |
| `response_format` | `mp3`（默认，与 OpenAI 对齐）/ `wav` / `flac` / `opus` / `aac` / `pcm` |
| `stream_format` | 只支持 `"audio"` |

**`/v1/audio/speech` 的默认 `response_format` 是 `mp3`**（与 OpenAI 对齐），非 wav 会用 `ffmpeg` 转码；没有 ffmpeg 时请显式传 `response_format=wav`。原生 `/v1/tts` 始终返回 wav 路径。

Python OpenAI SDK：

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8791/v1", api_key="my-secret")
with client.audio.speech.with_streaming_response.create(
    model="indextts2",
    voice="voice_01",
    input="你好，这是一段语音。",
    response_format="mp3",
) as response:
    response.stream_to_file("hello.mp3")
```

`GET /v1/models` 也返回 OpenAI 风格的列表，方便客户端做模型发现。

## 音色上传

```bash
python - <<'PY'
import base64, json, requests
raw = open("examples/emo_sad.wav", "rb").read()
r = requests.post(
    "http://127.0.0.1:8791/v1/voices",
    headers={"Authorization": "Bearer my-secret"},
    json={
        "name": "旁白女声",
        "filename": "emo_sad.wav",
        "audio_base64": base64.b64encode(raw).decode(),
        "notes": "女声，语气平稳",
        "tags": ["旁白"],
    },
)
print(r.status_code, r.json())
PY
```

- 支持 `wav/mp3/flac/m4a/aac/ogg/opus/webm`，上限 20 MiB。
- 服务端会先尝试真正解码一次（需要 ffmpeg），坏文件不会登记。
- 音色复制进 `<skill>/voices/`；Docker 需要挂载 `-v /host/voices:/app/voices`。

## 音频下载与 Range

`GET /v1/audio/<job_id>` 和 `GET /v1/audio-file/<name>` 都支持：

- `Range: bytes=0-99` → `206` + `Content-Range`，方便浏览器/播放器拖动。
- `?download=1` → `Content-Disposition: attachment`。
- 只提供 `out_dir` 内的 wav；路径穿越和 `..` 会被拒绝。

## 错误结构

原生端点：

```json
{
  "ok": false,
  "schema": 1,
  "error": {
    "code": "CUDA_OOM",
    "message": "显存不足（阶段：infer）…",
    "hint": "调小 --max-text-tokens-per-segment…",
    "retriable": false
  }
}
```

`/v1/audio/speech` 使用 OpenAI 错误形状：

```json
{
  "error": {
    "message": "…",
    "type": "invalid_request_error",
    "param": null,
    "code": "BAD_USAGE"
  }
}
```

HTTP 状态映射：参数错误 400、音色/任务不存在 404、音色已存在/任务未完成/无法取消 409、请求体过大 413、队列满 429、守护进程不可用/OOM 503、同步等待超时 504。

## 限制与并发

- 守护进程单 worker，请求串行执行；队列上限默认 4（`config.json` 的 `max_pending`），超出返回 429。
- 首次请求若守护进程未启动，会先冷启动（约 30~45 秒）；`--preload` 默认会在后台提前加载。
- 文本上限 20000 字符（API/WebUI 层）；超长文本请拆段或用 CLI 的 `--text-file`。
- 守护进程默认空闲 1 小时后退出；下一次请求自动重启。
- 所有请求都会在输出目录留下 wav（即使 OpenAI 端点最终返回 mp3），可在 `/v1/history` 查看。

## Docker

```bash
docker run --rm -p 8791:8791 --gpus all \
  -v /host/checkpoints:/app/checkpoints \
  -v /host/voices:/app/voices \
  -v /host/out:/data/out \
  indextts2:cu128 api --host 0.0.0.0 --api-key my-secret
```

必须显式 `--host 0.0.0.0`，否则容器内只监听 `127.0.0.1`，端口映射访问不到。

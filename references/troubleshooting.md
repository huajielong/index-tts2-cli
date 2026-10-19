# 故障排查与性能

**先看症状表定位，再读对应小节。** 正常合成不必读这份。

## 症状速查

| 症状 | 先做什么 |
|---|---|
| 第一次调用约 30 秒 | 正常（模型加载）。`daemon.was_cold_start=true`，不要重试 |
| 每次调用都 30 秒以上 | `indextts2 status` 看守护进程是否在跑，或 `idle_timeout` 是否太短 |
| 突然变慢但不报错 | 查显存与 WDDM 系统内存回退（见下文） |
| 音频被截断 / 不完整 | 检查 `warnings`，调大 `--max-mel-tokens` |
| 显存不足（退出码 6） | 见 `CUDA_OOM` 小节 |
| 权重缺失 | `indextts2 doctor --fetch` |
| 并发发起多个合成反而更慢 | 守护进程单 worker，请求只会排队 |
| 守护进程卡住 / 坏了 | 见 `DAEMON_STUCK` 与退出码 8 小节 |
| WebUI/API 端口被占用（退出码 4） | 换 `--listen-port`；`--port` 是守护进程端口，不要混用 |
| API 返回 401 | 加 `Authorization: Bearer <key>` 或 `X-API-Key`；key 来自 `--api-key` / `INDEXTTS2_API_KEY` |
| WebUI 上传音色失败（Docker） | `voices/` 是只读镜像层；挂载 `-v /host/voices:/app/voices` |
| WebUI/API 第一次生成很慢 | 守护进程冷启动；等右上角变「就绪」，或启动时加 `--preload` |
| OpenAI 端点报 ffmpeg 缺失 | 传 `response_format=wav`，或安装 ffmpeg（Docker 镜像已内置） |

## 性能实测

环境：RTX 5070 Ti Laptop（11.94 GB 可用）、fp16、`num_beams=3`。

| 场景 | 耗时 |
|---|---|
| 模型加载（冷启动付一次） | 22–27 秒 |
| 首次调用总耗时（含加载） | 约 31 秒 |
| 守护已就绪，短句 | 约 6 秒 |
| 短句合成的 RTF | 2.2（冷）/ 1.6（参考音频缓存命中后） |
| 264 字长文本 → 5 段 → 58.9 秒音频 | 87 秒（RTF 1.47） |
| 显存占用 | 约 7.6 GB |
| `stop` 后显存 | 约 0.2 GB |

- 冷启动的 22–27 秒里，大头是 `qwen0.6bemo4-merge` 情感模型 + 3.5GB 的 `gpt.pth`。文件在系统缓存里时靠近下限。
- **参考音频缓存命中**对重复使用同一音色的场景影响明显：切换参考音频会让上游的单槽缓存失效并触发一次 `torch.cuda.empty_cache()`。
- 内存加载时间是**首次**冷启动时体感最明显的一项；`HF_HUB_OFFLINE=1`（默认）去掉了最多 6 次 × 10 秒的 ETag 网络往返。
- **多任务串行**：守护进程单 worker，并发请求会排队（最多 4 个，超出返回 503）。不要为了"加速"并发发起多个合成，那只会排队。

## 故障排查

### 每次调用都很慢（30 秒以上）

守护进程没在跑，每次都在冷启动。`indextts2 status` 看 `running` 字段。如果它反复自动退出，检查 `config.json` 的 `idle_timeout`（默认 3600 秒，空闲一小时后自动退出）。

### `MODEL_FILES_MISSING` / 权重缺失

```bash
indextts2 doctor --fetch     # 允许联网补齐 Hugging Face 缓存
```

默认是离线的（`HF_HUB_OFFLINE=1`）。这是刻意的：它同时避免了网络往返、把"cwd 设错了"从静默下载 2.8GB 变成秒级报错、并钉住权重 revision。

`--fetch` 的两条行为约束（都是踩过坑才加的）：

1. **已经齐了就完全不联网。** 先查本地 `snapshots/` 里四个仓库各自需要的文件在不在；全在就直接跳过。这不是偷懒——这些仓库上游 revision 一变，整仓下载会拖下十几 GB，还会把 `refs/main` 悄悄切到新 revision，那就把离线默认想守住的可复现性毁掉了。
2. **只拉推理真正用到的文件。** 四个仓库加起来 14.3 GB，实际只需要 2.8 GB：

   | 仓库 | 全量 | 需要 | 差在哪 |
   |---|---|---|---|
   | `facebook/w2v-bert-2.0` | 4436 MB | 2215 MB | `conformer_shaw.pt` 是另一种格式的重复权重 |
   | `amphion/MaskGCT` | 6276 MB | 169 MB | 只用 `semantic_codec/` |
   | `nvidia/bigvgan_v2_22khz_80band_256x` | 3614 MB | 430 MB | 两个 1.38 GB 的 discriminator/optimizer 检查点是**训练用**的 |
   | `funasr/campplus` | 27 MB | 27 MB | — |

   不加 `allow_patterns` 的话，一次 `--fetch` 会白下 11.5 GB。

判定"已缓存"时只看文件在不在、以及 JSON 能否解析——**不要用尺寸阈值**。早先这里用过 `>1024 字节` 的经验阈值，结果把只有 275 字节的合法 `preprocessor_config.json` 误判成缺失，导致已缓存的仓库仍被重新拉取。另外也不需要"防半截下载"的检查：huggingface_hub 把未完成的下载放在 `blobs/*.incomplete`，只有下载完整才移入 `snapshots/`。

### `WRONG_INDEXTTS_COPY`

import 到的是 `venv/Lib/site-packages/indextts/` 里打包安装的那份，而不是仓库副本。检查 `config.json` 的 `project_dir`。

### `DAEMON_STUCK`

守护进程卡在某个加载阶段超过 180 秒。最常见的原因是 Hugging Face 的文件锁被挂住（上游的 `WeakFileLock` 没有超时）。`indextts2 stop --force` 清理后重试。

### `CUDA_OOM`（退出码 6）

按性价比依次尝试：

1. 确认 fp16 已开（`config.json` 的 `fp16`，默认 `true`）
2. 调小 `--max-text-tokens-per-segment`（例如 80）
3. 把文本拆短分多次合成
4. `indextts2 stop` 释放显存后重试

**守护进程不会因为 OOM 退役。** OOM 是可恢复的：PyTorch 的 caching allocator 抛出异常时已经回收了自己的块，CUDA context 本身完好。所以发生 OOM 后只把缓存还给驱动（`torch.cuda.empty_cache()`），进程继续服务——改完参数能立刻重试（秒级），不必重付 30 秒的模型加载。把 OOM 也当成毒化会导致"一次参数没调好就白等半分钟，而且重试时显存压力一模一样，照样失败"。

两个环境陷阱：

- Windows 上 `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` **无效**（torch 2.8 会打印不支持并忽略），不要指望它。
- **WDDM 驱动可能开启系统内存回退**（sysmem fallback）：超额分配会被放到系统内存而不是立即报错。实测在 RTX 5070 Ti Laptop（11.94 GB）上，一个进程能一路分配到 42 GB 才真的 OOM。所以本机上更常见的症状是**合成突然变得极慢**（数据在 PCIe 上来回搬），而不是报 OOM。遇到莫名变慢时，先看 `indextts2 status` 的显存数字和有没有别的进程在占卡。

### 音频被截断

`--max-mel-tokens` 设太小会截断音频，但任务仍然是 `ok: true`，只在 `warnings` 里提示。**必须检查 `warnings`**，不要只看 `ok`。上限 `max_mel_tokens` = 1815、`max_text_tokens_per_segment` = 600，越界会在客户端本地被拦下。

### 守护进程"活着但坏了"（退出码 8）

CUDA 的 **device-side assert / illegal memory access** 这类错误是**粘性**的——它们会永久污染 CUDA context，之后所有操作都会失败。所以：

- 每个任务结束都会在 try/except 内 `torch.cuda.synchronize()`，把异步错误钉到当前任务的边界（否则第 N 个任务的错误会在第 N+1 个任务里以误导性的形式爆出来）。
- 识别出这类错误后，守护进程写墓碑（`daemon.json` 里 `state: "degraded"`、`exit_code: 8`、`last_error`），`os._exit(8)` 自我退役；客户端会自动换一个新进程并**只重试一次**。

实测触发的真实错误长这样（`torch.AcceleratorError`，注意它**不是** `RuntimeError`，靠消息里的 `CUDA error: device-side assert triggered` 匹配）：

```
CUDA error: device-side assert triggered
CUDA kernel errors might be asynchronously reported at some other API call
```

### 想看日志

```bash
indextts2 status --json   # → log_path
indextts2 doctor          # → state_dir / log_path
```

或者手动前台运行 `indextts2 serve`，日志直接打在控制台。

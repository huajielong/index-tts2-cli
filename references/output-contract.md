# 输出契约

`--json` 的 stdout 格式、错误结构与退出码。**写解析代码或排查失败时读这份。**

## 成功（`--json`）

stdout **恰好一行**，`ensure_ascii=True`（纯 ASCII，无论经过 conhost、PowerShell 管道还是任何编码转换都不会乱码）。进度和提示都在 stderr。

```json
{
  "ok": true,
  "schema": 1,
  "output_path": "D:\\...\\a.wav",
  "fs_verified": true,
  "output_bytes": 142380,
  "sample_rate": 22050,
  "channels": 1,
  "audio_seconds": 3.228,
  "duration_s": 7.266,
  "rtf": 2.251,
  "text_segments": 1,
  "text_chars": 11,
  "warnings": [],
  "params": { "emo_mode": 0, "fp16": true, "num_beams": 3, "...": "..." },
  "voice": { "name": "voice_01", "id": "c7960075...", "source": "D:\\...\\voice_01.wav" },
  "job_id": "j_163a60fdd4cc",
  "daemon": { "pid": 39236, "port": 8788, "was_cold_start": true, "model_load_s": 22.07 }
}
```

值得注意的字段：

- **`fs_verified`** —— 已经确认文件真的存在且大小 > 44 字节。给出一个不存在或 0 字节的路径是最恶劣的失败，所以这里显式校验。
- **`warnings`** —— 上游的静默劣化都会落到这里，最重要的是 `max_mel_tokens` 截断。**务必检查这个字段**：音频被截断时任务依然是 `ok: true`。
- **`daemon.was_cold_start`** —— 为 `true` 表示这次付了模型加载的钱。看到它不要重试。
- **`recovered`** —— 仅当守护进程在任务完成后才退出、客户端直接从磁盘上的产物恢复结果时出现。

## 失败（`--json`）

```json
{
  "ok": false,
  "schema": 1,
  "error": {
    "code": "CUDA_OOM",
    "message": "显存不足（阶段：infer）：torch.OutOfMemoryError: ...",
    "hint": "按性价比依次尝试：1) 确认已开 --fp16；2) 调小 --max-text-tokens-per-segment…",
    "retriable": false,
    "stage": "infer",
    "log_tail": ["...", "..."]
  }
}
```

- **`hint`** 是一条**可执行的下一步**，不是错误复述。多数情况下它能直接决定智能体的下一个动作。
- **`retriable`** 决定重试还是换路。
- **`log_tail`** 内联了 `daemon.log` 的最后 40 行，省掉一次诊断往返。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 未归类的内部错误 |
| 2 | 用法错误 / 参数越界 |
| 3 | 音色不存在或不可读 |
| 4 | 守护进程启动失败或超时 |
| 5 | 队列已满 |
| 6 | CUDA 显存不足 |
| 7 | 推理失败 |
| 8 | 守护进程被 CUDA 错误毒化后退役 |
| 9 | 被强制中断 |
| 130 | 被 Ctrl+C 中断 |

> 守护进程内部用退出码 17 表示"抢锁失败"，它**不会**泄漏给调用方——客户端会把它翻译成"连上赢家"。

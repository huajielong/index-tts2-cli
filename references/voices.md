# 音色库

音色的注册、发现、删除，以及参考音频的缓存与截断规则。日常选音色只需 `indextts2 voices list --json`。

## 命令

```bash
indextts2 voices list [--json]
indextts2 voices add <名称> <音频路径> [--notes "..."] [--tags "a,b"] [--json]
indextts2 voices rm <名称> [--json]
indextts2 voices rename <旧名> <新名> [--json]
indextts2 voices preview <名称> [文本] [-o <路径>] [--json]
```

注册表在 `<skill>/voices/voices.json`。`voices add` 会把音频**复制**进 `<skill>/voices/`；`voices rm` 只删除复制进来的那份，不动用户原路径的文件。

WebUI 的「上传」和 API 的 `POST /v1/voices` 最终都调用同一套登记逻辑（参考音频上限 20 MiB；Docker 里需要挂载 `voices/`）。细节见 `references/webui.md` 与 `references/rest-api.md`。

`voices list` 除了注册表，还会自动发现：

- `<project>/examples/*.wav`（即 `voice_01`…`voice_12`、`emo_sad`、`emo_hate`）
- `<project>/prompts/*.wav`
- `<skill>/voices/*.wav`

自动发现的条目标 `"source": "auto"`，只记录路径不复制文件。

## `--voice` 的三种写法

`--voice` 接受音色名（`voice_01`）、内容 id（`c79600751b…`）、或直接的音频文件路径。给错了会报错并列出可用音色。

## 内容寻址的参考音频缓存

任何参考音频（音色的和情感的）在送进模型前，都会先用项目的 `venv\ffmpeg.exe` 归一化成单声道 16-bit PCM WAV，落在 `<状态目录>/voices/<sha1>.wav`。

这一步同时解决四个问题：

1. **上游的缓存是按路径字符串比较的**，同一路径换了内容不会失效；用内容哈希当键就自然修好了。
2. **路径写法不同会被当成两个键**（大小写、斜杠方向），每次都要重跑 wav2vec2-bert + CAMPPlus 并 `torch.cuda.empty_cache()`；归一化后路径唯一。
3. **ffmpeg 不在 PATH 上**（`venv\ffmpeg.exe` 存在但目录没入 PATH），读 mp3 之类会失败；这里用绝对路径显式调用。
4. 给智能体一个稳定可引用的 `voice.id`。

**刻意不重采样**：音色参考音频还要拿去算 22050 Hz 的 `ref_mel`，降到 16k 会丢掉 8~11kHz 的内容。只统一容器、声道数和位深，保留原采样率。

参考音频超过 15 秒会被自动截断（上游 `_load_and_cut_audio` 的行为），此时 `warnings` 里会有提示。格式不限（wav/mp3/flac/m4a…），会自动归一化。

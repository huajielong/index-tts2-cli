# 部署与平台

平台支持、环境自举、资源自动补齐、Linux/macOS/Docker 部署与环境变量。**只在换机器、换系统、用 Docker 或排查环境问题时读这份。**

## 目录

1. 部署形态与平台支持
2. 第三方资源的自动补齐
3. Windows
4. Linux
5. macOS
6. Docker
7. 环境变量
8. 验证覆盖

## 1. 部署形态与平台支持

skill 目录里有一部分内容**与平台无关**，另一部分**与平台绑定**：

| 内容 | 位置 | 大小 | 跨平台？ |
|---|---|---|---|
| 模型权重（gpt/s2mel/qwen/feat/bpe） | `checkpoints/` | 5.7 G | ✅ 直接复制 |
| Hugging Face 权重缓存 | `checkpoints/hf_cache/` | 2.8 G | ✅ 直接复制（无符号链接） |
| 推理源码 | `indextts/` | 24 M | ✅ |
| CLI 代码 | `scripts/` | 0.3 M | ✅（已用 3.8 语法校验，可在旧系统 Python 上启动） |
| 示例音色 | `examples/` | 12 M | ✅ |
| 依赖锁 | `pyproject.toml` / `uv.lock` / `.python-version` | 632 K | ✅ |
| **Python 环境** | `venv/` | 9 G | ❌ **平台绑定** |

| 平台 | `venv/` 来源 | 状态 |
|---|---|---|
| Windows + NVIDIA | 随包分发的打包发行版（`venv\python.exe`） | ✅ 已实测 |
| Linux + NVIDIA | `setup` 用 uv 现场建（`venv/bin/python`） | ✅ 已实测（WSL2） |
| macOS Apple Silicon | `setup` 用 uv 现场建（`venv/bin/python`），MPS | ⚠️ 实验性，未验证 |
| Docker | 镜像构建时 uv 建（`/opt/venv`） | 见 §6 |

由此得到：

- **Windows 上开箱即用**，`venv/` 可整体搬迁（没有 `pyvenv.cfg`、没有 `_pth`，`sys.prefix` 由解释器位置推导；实测搬路径后 torch/CUDA 正常）。
- **换系统必须重建环境**：Windows 的 `venv/python.exe` 是 PE32+，在 Linux 上执行会 `Exec format error`。`setup` 会真实执行一次解释器来识别这种情况，并自动重建。
- **模型不用重下**：把 `checkpoints/` 一起拷过去即可；`setup` 只补缺失项。
- **可以指向另一份 IndexTTS2 安装**：改 `config.json` 的 `project_dir` 或设 `INDEXTTS2_HOME`。
- **状态目录跟着 `project_dir` 走**（用 `resolve()` 归一化），同一份模型目录无论被多少个 skill 副本驱动，都只有一个守护进程。

> `venv/` 与 `checkpoints/` 曾用硬链接做过一次（省空间、删源目录也能用），但那是共享 inode，不是物理独立副本。现在是**真复制**。

## 2. 第三方资源的自动补齐

设计目标是"**存在就用缓存，不存在才下载**"：

| 情况 | 行为 |
|---|---|
| 资源齐备 | 只做本地文件检查（`stat` 9 个模型文件 + 4 个缓存目录），**零网络请求**，实测 0.14 秒 |
| 资源缺失 + `auto_download: true`（默认） | 自动下载缺口，然后再继续原来的命令 |
| 资源缺失 + `auto_download: false` | 立刻报 `RESOURCES_MISSING` 并给出指引，不会偷偷下几 GB |

`say` 和 `serve` 在启动前会自动跑一次这项检查；`indextts2 setup` 可以手动触发。

**Python 环境也遵循同一原则**（`config.json` 的 `auto_bootstrap`，默认开）：

| 情况 | 行为 |
|---|---|
| 当前系统有可执行且版本 ≥3.10 的解释器 | 直接使用，不联网 |
| 没有可用环境（新机器 / 换系统 / venv 损坏） | 用 uv 建到 `venv.new/`，验证通过后换名；旧的保留为 `venv.old-<时间戳>` |
| `auto_bootstrap: false` | 报 `PYTHON_NOT_FOUND` 并提示先跑 `setup` |

自举完成后会**用新解释器重新执行同一条命令** —— 因为引导阶段跑在系统 Python 上，
没有 `huggingface_hub` 等依赖，后续下载模型必须换环境。

### 数据来源与回退

| 资源 | 来源 | 大小 |
|---|---|---|
| `checkpoints/`（gpt.pth / s2mel.pth / qwen 情感模型 / bpe.model / feat*.pt / config.yaml） | HF `IndexTeam/IndexTTS-2`，失败自动回退 **ModelScope** 同名仓库 | 5.49 GB / 22 文件 |
| `checkpoints/hf_cache/`（w2v-bert / MaskGCT / campplus / bigvgan） | HF 四个独立仓库，按文件白名单拉取 | 2.8 GB |

HF 下不动时（国内网络常见）会自动切 ModelScope —— 两个都用 `snapshot_download(local_dir=...)`，已存在的文件不会重下。

### 为什么下载 5.49 GB 而不是更多

`IndexTeam/IndexTTS-2` 这个仓库本身就只有 5.49 GB，且全部是运行必需的；`pinyin.vocab` 只是给人看的参考清单，代码不加载，所以不下载。HF 缓存那四个仓库则做了精确白名单（全量 14.3 GB，实际只需 2.8 GB），详见 `references/troubleshooting.md` 的 `MODEL_FILES_MISSING` 一节。

### 实测

- 删掉 `feat1.pt`（57 KB）→ `setup` 4.2 秒补回，md5 一致，其余 21 个文件走缓存跳过
- 删掉 `feat1.pt` 后直接 `say` → 自动补齐并完成合成，无需手动 setup
- 挪走 `models--funasr--campplus`（27 MB）→ `setup` 自动重新拉取
- `auto_download: false` → 报 `RESOURCES_MISSING`，文件保持缺失，不会静默下载

## 3. Windows

开箱即用（自带打包 venv）。换机器时：

1. 把整个 skill 目录拷过去（**不要**只拷 `scripts/`）
2. 目标机装好 NVIDIA 驱动（cu128 建议 ≥ 570.65）
3. `scripts\indextts2.cmd doctor`

`venv\` 可以整体搬迁；若目标机没有 NVIDIA，环境能起来但会退回 CPU（极慢）。

## 4. Linux (x86_64 + NVIDIA)

前置：NVIDIA 驱动（cu128 建议 ≥ 570.26）、`python3.10` 或让它由 uv 托管。

```bash
# 1) 拷 skill（模型可一起拷，省 8.5 GB 下载）
rsync -a /path/to/index-tts2-cli ~/index-tts2-cli

# 2) 装 uv（官方只支持 uv 安装依赖）
curl -LsSf https://astral.sh/uv/install.sh | sh
source "$HOME/.local/bin/env"

# 3) 建环境 + 补资源（模型齐全时这一步不联网）
cd ~/index-tts2-cli
bash scripts/indextts2.sh setup

# 4) 自检 + 合成
bash scripts/indextts2.sh doctor
bash scripts/indextts2.sh say "Linux 上跑通了。" --voice voice_01 -o /tmp/a.wav
```

说明：

- `scripts/indextts2.sh` 会自动跳过 `venv/python.exe`（Windows PE 文件），选中 `venv/bin/python`。
- **系统 Python 是 3.12 也没关系**：`.python-version` 指定 3.10，uv 会自动下载一份托管的 CPython 3.10（约 30 MB）。这是因为 `numba 0.58.1`/`llvmlite 0.41.1` 没有 cp312 wheel —— 不要试图用 3.12 建环境。
- Linux 走 `WeTextProcessing`（依赖 `pynini`），与 Windows/macOS 的 `wetext` 互斥，由 `uv.lock` 的 marker 自动选择。
- 首次运行会在 `indextts/utils/tagger_cache/` 写缓存，**目录需要可写**。
- 国内加速：`export INDEXTTS2_PYPI_INDEX=https://mirrors.aliyun.com/pypi/simple`、`export HF_ENDPOINT=https://hf-mirror.com`。
- **ARM64 Linux 不支持**：`pynini` 没有 aarch64 wheel，cu128 也没有 aarch64 wheel。
- **不要把 `checkpoints/` 放在网络盘或 WSL 的 `/mnt/` 上**：9p/网络文件系统的读取很慢。实测同一份模型在 `/mnt/d` 上加载要 **180 秒**，本地 ext4 约 25 秒。WSL 里测试时请先 `cp` 到 `~` 下。

## 5. macOS (Apple Silicon)

⚠️ **实验性支持，未在本项目验证。** 上游没有官方 MPS 认证；社区更常用 MLX 方案。

```bash
brew install uv ffmpeg
cd ~/index-tts2-cli
bash scripts/indextts2.sh setup
bash scripts/indextts2.sh doctor      # 应显示 MPS
bash scripts/indextts2.sh say "你好" --voice voice_01 -o /tmp/a.wav
```

- 只支持 Apple Silicon；`torch 2.8.0` 没有 macOS x86_64 wheel。
- 自动设置 `PYTORCH_ENABLE_MPS_FALLBACK=1`（未实现的算子回退到 CPU）。
- 内存建议 24 GB 以上（权重 8.5 GB + fp32 激活 + KV cache）；16 GB 会大量 swap。
- 失败时：`export INDEXTTS2_DEVICE=cpu`（非常慢，但能验证链路）。
- `kaldifst` 的 macOS arm64 wheel 对 cp310 覆盖不完整；若 `setup` 报无 wheel，用 Python 3.11 建立环境（删掉 `.python-version` 或改成 `3.11` 后重跑 `setup`）。

## 6. Docker (linux/amd64 + NVIDIA)

镜像**不含模型**（实测 21.3 GB：CUDA 基础镜像 7.32 GB + Python 环境 8.73 GB + 其余运行时）。模型用 volume 挂载，或首次进容器 `setup` 下载。

```bash
docker build -t indextts2:cu128 .

# 一次性合成（入口会自动注入 --no-daemon）
docker run --rm --gpus all \
  -v /host/checkpoints:/app/checkpoints \
  -v "$PWD/out:/data/out" \
  indextts2:cu128 say "容器里合成。" --voice voice_01 -o /data/out/a.wav

# 长驻服务 + docker exec（多次合成推荐）
docker run -d --name tts --gpus all --restart unless-stopped \
  -v /host/checkpoints:/app/checkpoints \
  -v tts-state:/var/lib/indextts2 \
  -v "$PWD/out:/data/out" \
  indextts2:cu128 serve

docker exec -i tts /opt/venv/bin/python /app/scripts/indextts2.py \
  say "第二次调用。" --voice voice_01 -o /data/out/b.wav
```

需要浏览器工作台或对外 API 时，启动**前端服务**并显式绑定 `0.0.0.0`：

```bash
# WebUI（无内置登录，建议只在内网/VPN 使用）
docker run --rm -p 8790:8790 --gpus all \
  -v /host/checkpoints:/app/checkpoints -v /host/voices:/app/voices \
  -v /host/out:/data/out \
  indextts2:cu128 webui --host 0.0.0.0

# HTTP API（设 API key）
docker run --rm -p 8791:8791 --gpus all \
  -v /host/checkpoints:/app/checkpoints -v /host/voices:/app/voices \
  -v /host/out:/data/out \
  indextts2:cu128 api --host 0.0.0.0 --api-key my-secret
```

挂载 `voices/` 才能从 WebUI/API 上传音色（镜像层只读）。`INDEXTTS2_OUT_DIR` 在镜像里已是 `/data/out`，挂载后历史与产物会持久化。

**不要用 `-p 8788:8788`**：守护进程只监听容器内的 `127.0.0.1`，端口映射访问不到。这是刻意的安全设计（该 HTTP 端点没有鉴权）。容器内用 `docker exec`，或一次性用 `--no-daemon`；对外请走上面的 8790/8791 前端服务。

国内网络构建（apt 与 uv 分开控制，避免代理抖动拖垮整层）：

```bash
docker build \
  --build-arg APT_MIRROR=https://mirrors.aliyun.com/ubuntu \
  --build-arg UV_PROXY=http://host.docker.internal:7890 \
  -t indextts2:cu128 .
```

- `APT_MIRROR`：只改 apt 源，不传则用 Ubuntu 官方源。
- `UV_PROXY`：只给 `uv sync` 设代理；apt 仍直连。Docker Desktop 下可用 `http://http.docker.internal:3128`（它转发到宿主机代理）。
- 也可以直接传标准的 `--build-arg HTTP_PROXY=... HTTPS_PROXY=...`，但它对**所有** RUN 生效，apt 也会走代理。

其他注意：

- 容器内 `idle_timeout` 默认 3600，长驻容器空闲一小时后会退出；需要常驻就设 `config.json` 的 `idle_timeout: 0` 或依赖 restart policy。
- `checkpoints/` 必须**可写**（HF 的 `.locks`/`.cache`）。
- `voices/` 默认在只读的镜像层里；要 `voices add` 就挂载 `-v /host/voices:/app/voices`。
- 只用 CPU 时改基础镜像并重新 `uv lock`（cu128 会拉数 GB 的 CUDA 运行时）。

## 7. 环境变量

| 变量 | 作用 |
|---|---|
| `INDEXTTS2_HOME` | 覆盖 `project_dir` |
| `INDEXTTS2_PYTHON` | 强制指定解释器（不可用会报错，不静默回退） |
| `INDEXTTS2_STATE_DIR` | 覆盖状态目录（Docker/多用户必用） |
| `INDEXTTS2_OUT_DIR` | 覆盖默认输出目录 |
| `INDEXTTS2_WEBUI_PORT` | WebUI 监听端口（默认 8790） |
| `INDEXTTS2_API_PORT` | API 监听端口（默认 8791） |
| `INDEXTTS2_API_KEY` | API 的 Bearer/`X-API-Key` 鉴权 key；不设则不鉴权 |
| `INDEXTTS2_FFMPEG` | 指定 ffmpeg |
| `INDEXTTS2_DEVICE` | `auto` / `cuda:0` / `mps` / `cpu` |
| `INDEXTTS2_PYPI_INDEX` | uv 安装依赖时的 PyPI 镜像 |
| `PYTORCH_ENABLE_MPS_FALLBACK` | macOS 自动设为 1 |

## 8. 验证覆盖

| 平台 | 验证程度 |
|---|---|
| **Windows + CUDA** | 完整回归：合成、四种情感、并发、优雅退出、崩溃恢复、资源补齐、自举换名逻辑 |
| **Windows + CUDA（webui/api）** | 端到端实测：页面渲染与 4 种情感模式、上传音色、异步进度、波形、历史；API 鉴权、OpenAI mp3/wav、异步 job、Range、音色上传/删除、CORS、端口占用、环境变量 |
| **Linux + CUDA** | 端到端实测（WSL2 Ubuntu 24.04）：系统 Python 3.12 → uv 自举出 3.10.20 + torch 2.8.0+cu128 → `doctor` 全绿 → 合成出声（pcm_s16le/22050/mono） |
| **Docker（Windows + Docker Desktop/WSL2）** | 端到端实测：构建镜像 → `doctor` 10/10 → 一次性合成（4.23s 音频）→ `serve` + `docker exec` 二次合成（3.91s 音频，热调用 10.7s）。GPU 直通正常（RTX 5070 Ti，torch 2.8.0+cu128） |
| **macOS MPS** | **未实测**。仅验证了依赖解析（`uv sync --dry-run --python-platform aarch64-apple-darwin` 能解出 torch 2.8.0 + wetext + kaldifst），代码路径未在真机运行 |

Linux 实测的原始数据：

```
环境自举：系统 Python 3.12.3 → uv 下载 3.10.20 → venv 8.0 GB
torch 2.8.0+cu128 | cuda True | NVIDIA GeForce RTX 5070 Ti Laptop GPU
doctor：10/10 通过（venv/bin/python3、/usr/bin/ffmpeg、XDG 状态目录）
合成：ok=true, fs_verified=true, 2.786s 音频, RTF 3.43
```

> **注意**：这次测试把 `checkpoints/` 用符号链接放在 `/mnt/d`（Windows 盘），模型加载耗时 **180 秒**（Windows 本地盘约 25 秒）。9p 文件系统的随机读很慢，**生产环境不要把模型放在网络/跨系统挂载点上**。

Docker 实测的原始数据（Windows 11 + Docker Desktop 4.43.1 / WSL2，RTX 5070 Ti Laptop）：

```
基础镜像：nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04  7.32 GB
venv 层：8.73 GB（清掉 /root/.cache/uv 后；不清是 17.3 GB，镜像会到 34 GB）
最终镜像：21.3 GB（不含模型）
doctor：10/10 通过（/opt/venv/bin/python、/usr/bin/ffmpeg、torch 2.8.0+cu128）
一次性合成：ok=true, fs_verified=true, 2.914s 音频, RTF 2.67, 模型加载 98s
serve + docker exec：3.913s 音频, RTF 2.49, 热调用 10.7s, 模型加载 109s
```

两个只影响 Windows 宿主的细节：

- **Git Bash/MSYS2 会改写容器内绝对路径**（`/data/out/x.wav` → `C:/Program Files/Git/data/out/x.wav`，`/bin/sh` 同理）。在 Git Bash 里跑 Docker 命令前先 `export MSYS_NO_PATHCONV=1`；PowerShell / cmd 没有这个问题。
- **Docker Desktop 的 bind mount 慢**：模型放在 Windows 盘挂载进容器时，加载约 100–170 秒（virtiofs 随机读），Linux 原生路径没有这个开销。容器要反复启动时，建议先用 `docker cp` 把 `checkpoints/` 放进 named volume（如 `docker run -v tts-models:/models ...`），或直接把模型放在 Linux 本地盘。

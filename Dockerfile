# 不使用 `# syntax=docker/dockerfile:1`：它要求构建时联网解析前端镜像，
# 在受限网络下会卡住；本文件只用到内置前端的标准语法。
#
# IndexTTS2 CLI — Linux CUDA 镜像
#
# 只支持 linux/amd64：cu128 的 PyTorch wheel 与 NVIDIA 基础镜像都没有 arm64。
# Apple Silicon 上构建会走模拟且没有 GPU，不建议。
#
# 构建时**不**打包模型（镜像约 21 GB）；模型在运行时用 volume 挂载，或首次
# 进容器跑 `setup` 自动下载（约 8.5 GB）。

FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu22.04

# INDEXTTS2_PYTHON 必须显式给出：解释器自动探测只认 <project>/venv，
# 而镜像把环境建在 /opt/venv。不设的话 serve / doctor 会退到系统 python3。
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONUTF8=1 \
    PYTHONIOENCODING=utf-8 \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_HTTP_TIMEOUT=120 \
    UV_PROJECT_ENVIRONMENT=/opt/venv \
    INDEXTTS2_HOME=/app \
    INDEXTTS2_PYTHON=/opt/venv/bin/python \
    INDEXTTS2_STATE_DIR=/var/lib/indextts2 \
    INDEXTTS2_OUT_DIR=/data/out \
    HF_HOME=/app/checkpoints/hf_cache \
    HF_HUB_OFFLINE=1 \
    PYTORCH_CUDA_ALLOC_CONF= \
    HOME=/root

# python3.10 来自 Ubuntu 22.04；libGL 供 opencv，libsndfile 供 librosa，
# libgomp 供 torch 的 OpenMP 运行时。ffmpeg 用于参考音频归一化。
#
# 可选构建参数：
#   APT_MIRROR  国内构建时换成 https://mirrors.aliyun.com/ubuntu 等镜像
#   UV_PROXY    只有 uv 下载依赖时走代理；apt 仍直连，避免代理抖动拖垮整层
ARG APT_MIRROR=
ARG UV_PROXY=
# 代理/镜像抖动会让单个 .deb 断流（unexpected EOF）；重试比整层重建便宜得多
RUN if [ -n "$APT_MIRROR" ]; then \
        sed -i "s|http://archive.ubuntu.com/ubuntu|$APT_MIRROR|g; \
                s|http://security.ubuntu.com/ubuntu|$APT_MIRROR|g" /etc/apt/sources.list; \
    fi \
    && apt-get update && apt-get install -y --no-install-recommends \
        -o Acquire::Retries=5 -o Acquire::http::Timeout=60 \
        python3.10 python3.10-venv \
        ffmpeg libsndfile1 libgomp1 libgl1 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# 固定版本的 uv，避免 curl 脚本和版本漂移
COPY --from=ghcr.io/astral-sh/uv:0.11.30 /uv /usr/local/bin/uv

WORKDIR /app

# 先只拷依赖描述文件再 sync：源码改动不会让这一层缓存失效
COPY pyproject.toml uv.lock .python-version /app/
# --frozen：随包的 uv.lock 与 pyproject.toml 在 uv 0.11 下并不一致，
# --locked 会直接失败。--frozen 按现有锁安装，行为可复现。
# uv 的下载缓存（HOME=/root/.cache/uv）默认会留在镜像层里，约等于把
# 整个 wheel 集合再存一份；同一个 RUN 内删除不会进入最终层。
RUN if [ -n "$UV_PROXY" ]; then export HTTP_PROXY="$UV_PROXY" HTTPS_PROXY="$UV_PROXY"; fi; \
    uv sync --frozen --no-dev --no-install-project --no-install-workspace --project /app \
    && rm -rf /root/.cache/uv

COPY indextts/ /app/indextts/
COPY examples/ /app/examples/
COPY scripts/ /app/scripts/
COPY SKILL.md config.json /app/
COPY LICENSE LICENSE_ZH.txt NOTICE.md README.md /app/
COPY references/ /app/references/

# 预热 Linux 文本规范化缓存：front.py 会在 indextts/utils/ 下建 tagger_cache，
# 只读镜像里运行时创建会失败，所以构建期先把它生成好。
RUN mkdir -p /app/runtime/out /app/voices /var/lib/indextts2 /data/out \
    && /opt/venv/bin/python -c "\
import sys; sys.path.insert(0, '/app');\
from indextts.utils.front import TextNormalizer;\
TextNormalizer().load(); print('tagger_cache warmed')" \
    && chmod +x /app/scripts/docker-entrypoint.sh

# WebUI / API 的前端服务端口。守护进程本身仍只监听容器内 127.0.0.1:8788，
# 对外访问请用 `webui --host 0.0.0.0` / `api --host 0.0.0.0 --api-key ...`
# 并映射这两个端口。
EXPOSE 8790 8791

VOLUME ["/app/checkpoints", "/var/lib/indextts2", "/data/out"]

ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
CMD ["--help"]

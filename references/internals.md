# 架构与实现约束

守护进程怎么跑、状态放在哪、改代码前必须知道的硬约束。**做普通合成不需要读；改 `scripts/` 或排查守护进程异常时再读。**

## 1. 架构

```
客户端进程 (indextts2 say ...)
   │  HTTP/1.0 on 127.0.0.1:<port>
   ▼
守护进程 (indextts2 serve)  ── 常驻，模型只加载一次
   │
   ▼
IndexTTS2 (<project_dir>\indextts\infer_v2.py)
```

默认每次合成都会复用常驻守护进程。首次调用会自动把它拉起来（detached），付一次约 25 秒的模型加载；之后每次调用的开销只有进程启动 + HTTP 往返，约 1 秒。

`--no-daemon` 可以让当前进程直接加载模型跑一次后退出，完全不碰守护进程。用于排障或一次性脚本。

## 2. 状态目录

不在 skill 目录里，而是由 `project_dir` 派生：

```
%LOCALAPPDATA%\indextts2\<sha1(normcase(project_dir))[:8]>\
├── instance.lock      内核字节锁，守护进程终身持有
├── daemon.json        端口 / pid / 状态 / 退出墓碑
├── daemon.log         守护进程日志（>8MB 时轮转到 daemon.log.1）
└── voices\<sha1>.wav  内容寻址的参考音频缓存
```

刻意由 `project_dir` 派生是为了保证**同一份模型目录永远只有一个守护进程**。如果锁放在 skill 目录，把 skill 复制成两份（项目级 + 用户级）就会各起一个守护进程，2 × 7.6GB 显存直接打爆 12GB 卡。

用 `indextts2 doctor` 或 `indextts2 status` 可以打印实际路径。

## 3. 单实例与启动竞态

守护进程的启动顺序本身就是防竞态设计：

1. **先抢内核字节锁**（`msvcrt.locking`），失败者打印赢家的信息后以退出码 17 秒退（约 150ms，零显存）。锁由系统在进程终止时自动释放，所以不存在"陈旧锁判定"和 pid 复用的问题。
2. **先绑定端口并开始服务 `/health`，再加载模型**。于是"正在加载"和"已经死了"在协议层面就是可区分的，客户端不必靠超时去猜。
3. 加载完成后写入 `state: ready`。

客户端不做任何加锁，只是"乐观启动 + 发现输家后连上赢家"。

## 4. 环境要点（实现约束，改代码前先读）

| 事实 | 影响 |
|---|---|
| `indextts/infer_v2.py:4` 在 import 时**无条件**覆写 `HF_HUB_CACHE='./checkpoints/hf_cache'`（相对路径） | 必须在 import 前 `os.chdir(项目根)` |
| `venv/` 不是虚拟环境（无 `pyvenv.cfg`、无 `Scripts\python.exe`） | 必须硬编码 `venv\python.exe` 并把 `venv\` 加进 PATH（这也是 ffmpeg 的来源） |
| 脚本模式下 `sys.path[0]` 是脚本目录，**不含 cwd** | `sys.path.insert(0, 项目根)` 与 `chdir` 是两件独立的事 |
| `venv/Lib/site-packages/indextts/` 有一份打包安装的副本 | 所以要断言 `infer_v2.__file__` 在项目根下 |
| `infer_v2.py:507` 硬编码 `do_sample=True` | `do_sample` 是死参数，不暴露 |
| `infer_v2.py` 内部从不调用 `normalize_emo_vec` | 模式 2 必须在 CLI 层自己调 |
| `infer_v2.py:620-627` 先 `os.remove` 再写输出 | 中途失败会两个文件都没有 → 写 `<名字>.partial-<job_id>.wav` 再 `os.replace` 原子替换 |
| `torchaudio.save` 按**扩展名**分派编码器 | 临时文件必须仍以 `.wav` 结尾 |
| `infer_v2.py:595` 每个 segment 都 `print(wav.shape)` | 守护进程的 stdout 必须重定向到日志；`--no-daemon` 要把它改道到 stderr |
| Windows 控制台默认 GBK | 强制 UTF-8 stdout；JSON 一律 `ensure_ascii=True` |
| `cmd.exe` 在 `chcp` 生效前按本地代码页解析整个批处理文件 | `indextts2.cmd` 必须保持纯 ASCII |
| `threading.HTTPServer.allow_reuse_address` 在 Windows 上默认为 1 | 必须显式关掉，并用 `instance_id` 而非端口做身份标识 |
| `GetProcessTimes` 的四个 FILETIME 参数都不能是 NULL | 传 `None` 会直接触发访问违例 |
| 随包的 `uv.lock` 与 `pyproject.toml` 在 uv 0.11 下不一致（`uv lock --check` 在原仓库里也失败） | 自举必须用 `uv sync --frozen`；`--locked` 会直接报 "lockfile needs to be updated" |

# HTTP 端点

> 这是**内部守护进程**的 HTTP 接口：只监听 `127.0.0.1`，没有鉴权，客户端协议也不是稳定对外契约。需要给外部程序调用时，请用 `indextts2 api` 提供的公开 API，见 `references/rest-api.md`。

守护进程的本地 HTTP 接口。**只有要手工调试或写自定义客户端时才需要读这份**；正常使用走 CLI。

守护进程只监听 `127.0.0.1`，直接用 `curl` 调试也可以。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 状态快照。**恒返回 200**（只要进程能应答），用 `state` 字段区分 |
| GET | `/status` | `/health` 加上真实的设备级显存信息 |
| POST | `/jobs` | 提交任务 → `202 {job_id, queue_position}` |
| GET | `/jobs/<id>` | 查询任务：`state` / `progress` / `phase` / `result` / `error` |
| DELETE | `/jobs/<id>` | 取消排队中的任务（推理中的无法取消，返回 409） |
| POST | `/say` | 同步端点，阻塞至完成。给 `curl` 手工调试用 |
| POST | `/shutdown[?force=0\|1\|2]` | `0`=优雅排空，`2`=立即终止 |

`state` 取值：`loading` → `ready` → `draining` / `degraded` / `failed` → `stopped`。

几个刻意的设计：

- **`/health` 绝不获取推理锁**，否则推理期间它会挂起，客户端会判定守护进程死亡并再起一个。
- **先绑定端口再加载模型**，所以加载期间 `/health` 就是可用的，`phase` / `phase_index` 让客户端能区分"正在推进"和"卡住了"。
- **`allow_reuse_address = False`**。Windows 上它默认开启，意味着第二个进程能成功绑定别人正在监听的端口——所以端口号不能当身份标识，客户端用每进程生成的 `instance_id` 校验。

# profiles/ —— 本机 worker profile 的可版本化部分

本目录只存放**可公开**的 profile 组成文件。真实运行时状态（会话、记忆、日志、状态库）与秘密（`.env`）
永远留在本机 `$HERMES_HOME/profiles/<name>/`，不入库。

`hermes profile export` 打的是整包 tarball（含 `.env` 与状态库），**不能**用于这里——那条路只适合整机迁移。

## 结构

```
profiles/
├── manifest.conf              # 唯一事实源：每个 profile 的 SOUL 与受管 config 键
├── _shared/SOUL.md            # 所有 worker 共享的纪律（装配时拼到角色 SOUL 之前）
├── impl-codex/SOUL.md         # 角色纪律
└── review/SOUL.md
```

编排者不使用本目录的 profile：编排由操作者直接对话的 Hermes profile 承担（本机缺省为 `default`，
会话可见、行为连续）。

## 同步模型：仓库声明应然，本机承载实然

两侧所有权方向不同，所以这不是双向同步，而是「声明 + 对齐」：

| 对象 | 所有者 | 规则 |
|---|---|---|
| `SOUL.md` | **仓库** | `apply` 每次覆盖；本机手改会被下一次 `apply` 冲掉（有意改动请用 `capture` 收回仓库） |
| `config.yaml` 的受管键 | 仓库声明、本机承载 | 只同步 `manifest.conf` 列出的键；其余键（`_config_version`、平台段落等 Hermes 自写项）不参与 |
| `.env` | 本机 | 永不入库；`apply` 只检查 provider key 是否存在，缺了告警 |
| 状态/会话/日志/缓存 | 本机 | 不参与 |
| 自定义 `skills/` | 仓库 | `apply` 软链进 profile；bundled 副本由 Hermes 自己管理，不镜像 |

profile 目录里混着这三类东西，所以「保持同步」必须先回答**哪一侧是权威**，否则每次都会互相覆盖。

## 三个动词

```bash
scripts/sync.sh plan      # 只读：逐项对比 manifest 与本机，列出 drift（无 drift 退出 0）
scripts/sync.sh apply     # 仓库 → 机器：SOUL 覆盖 + 受管键写入（走 hermes -p <p> config set）
scripts/sync.sh capture   # 机器 → 仓库：偏离写成 *.capture.md / 打印 manifest 建议值，人工合并
```

`plan` 是核心：它把「本机手改过什么」与「仓库模板是否过期」变成可见差异，而不是等换机器那天才发现。
退出码可用于定时巡检或 CI。

## 日常节奏

1. **改角色行为/纪律** → 改 `profiles/` 或 `manifest.conf` → `sync.sh apply` → 过两道门禁 → 提交。
2. **本机临时调参**（例如试两天别的模型档）→ 试完 `sync.sh capture` 看偏离 → 决定写回 manifest（正式化）
   还是 `sync.sh apply` 覆盖回去（撤销）。
3. **换机器/重建** → `git clone` → `sync.sh apply` → 手工注入 `.env`（key 永不入库）。

## 已知约束

- **profile 不继承**主 profile 的 `.env`：每个 worker profile 需自行写入 provider key（`chmod 600`），
  否则冒烟会报 `No usable credentials found for provider ...`。
- `kanban.dispatch_profiles` 写在编排侧配置里，**逗号分隔**（`"impl-codex,review"`）；空格分隔会被当成
  单个 profile 名，卡片会一直卡在 `skipped_nonspawnable`。
- 工具面（toolsets）不入库：用 `hermes -p <name> tools` 在本机确认，避免配置漂移。

## 信息卫生

本仓库是公共仓库。提交前两道门禁缺一不可：

1. `scripts/check-secrets.sh` —— 正则初筛。
2. `scripts/ai-desensitize-review.sh` —— **由 AI agent 通读 diff 判定私有信息**，脚本正则不能替代。

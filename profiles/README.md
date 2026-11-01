# profiles/ —— 本机 worker profile 的可版本化部分

本目录只存放**可公开**的 profile 组成文件；真实运行时状态（会话、记忆、凭据）永远留在本机
`$HERMES_HOME/profiles/<name>/`，不入库。

## 结构

```
profiles/
├── _shared/SOUL.md            # 所有 worker 共享的纪律（bootstrap 时拼到各 profile SOUL 前面）
├── _shared/config.base.yaml   # 通用非敏感配置片段（参考用）
├── impl-codex/{SOUL.md,config.yaml}
└── review/{SOUL.md,config.yaml}
```

编排者不使用本目录的 profile：编排由操作者直接对话的 Hermes profile 承担（本机缺省为 `default`，
会话可见、行为连续）。

## 组成规则

- `SOUL.md`：角色纪律。bootstrap 时以 `_shared/SOUL.md` + 角色 SOUL 的顺序合并写入。
- `config.yaml`：只放**非敏感**项（模型档、超时、并发上限）。令牌一律从本机 `.env` / 环境变量读，
  文件里出现 `<PLACEHOLDER>` 由 bootstrap 替换。
- 工具面（toolsets）不入库：用 `hermes -p <name> tools` 在本机确认，避免配置漂移。
- **profile 不继承主 profile 的 `.env`**：每个 worker profile 需自行写入 provider key
  （`chmod 600`，绝不入库）；否则 smoke 会报 `No usable credentials found for provider ...`。
- `kanban.dispatch_profiles` 只写在该机器编排侧的配置里，**逗号分隔**（`"impl-codex,review"`）；
  空格分隔会被当成单个 profile 名，卡片会一直卡在 `skipped_nonspawnable`。

## 使用

```bash
# 仓库 → 本机（幂等；已存在的 profile 默认跳过）
scripts/bootstrap.sh

# 本机 → 仓库（抓 SOUL/config，脱敏后给人看 diff，不自动提交）
scripts/capture.sh impl-codex

# 提交前两道门禁
scripts/check-secrets.sh            # 初筛：令牌/.env/私钥/内网地址字面量
scripts/ai-desensitize-review.sh    # 强制：AI agent 通读 staged diff 判私有信息
```

## 信息卫生

本仓库是公共仓库。AI 审查（`ai-desensitize-review.sh`）是**必须通过**的门禁，脚本只是初筛：
任何私有项目名、私有仓库名、内部主机/路径、人员姓名、雇主线索都必须拦下并改写为占位符。

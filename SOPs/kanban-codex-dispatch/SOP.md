# SOP: Kanban → Codex 派工闭环

- 版本: 0.1.0
- 状态: draft
- 更新: 2026-10-31

把编码任务从「人 → 编排者」的会话流，改成「人 → 看板卡 → 执行者 → 审查者 → 人拍板」的队列流。
编排者使用操作者直接对话的 Hermes profile（本机缺省为 `default`）；编码本身交给 codex CLI。

## 参与者

| 角色 | 实体 | 职责 |
|---|---|---|
| 人 | 消息平台（Gateway） | 建卡、拍板、裁决 review |
| 编排者 | `default` profile | 拆卡、写卡、路由、汇总；**不做实现** |
| 执行者 | `impl-codex` profile | 卡片 → codex 任务书 → 跑 codex → 自验 → 回写证据 |
| 审查者 | `review` profile | 独立复核 diff + 重跑验收；给 verdict |
| 编码器 | codex CLI（子进程） | 真正改代码；**必须 commit** |
| 总线 | Kanban board（SQLite） | 卡片状态、依赖、评论、事件 |

## 卡片契约（每张实现卡必填）

模板见 `templates/kanban-card.md`，四段不可缺：

1. **目标 / 不做什么** —— 边界写死，避免执行者自行扩题。
2. **仓库与工作区** —— `--workspace worktree:<repo-path>`：一卡一 worktree，隔离且可回滚。
3. **验收命令** —— build / test 的确切命令，不接受「跑过了」。
4. **证据要求** —— 命令 + 退出码 + 关键输出行 + `git log --oneline -1`（证明 commit 存在）。

配套：`--assignee impl-codex`、`--max-retries 2`；需要人工审批的卡用父子链（实现卡 → 审查卡）。

## 执行序列（impl-codex）

1. `kanban_show` 读卡 + 全部评论（评论是跨轮次的上下文，别只看 body）。
2. 生成 `TASK.md`：目标、约束、验收命令、禁止事项、**要求 codex 在仓库内做一次原子 commit**。
3. 调 codex（见下节），workdir = 卡片的 worktree。
4. **自己复跑验收命令**，抓证据（不采信 codex 自述）。
5. 校验 commit：`git log --oneline -1` 且 `git diff --stat HEAD~1` 只覆盖本卡范围。
6. 通过 → `kanban_comment` 贴证据 → `kanban_request_review`（有人审需求）或 `kanban_complete`。
7. 失败 → `kanban_comment` 贴报错与现场 → 视性质 `kanban_block`（额度/环境/歧义）或留 `ready` 重试。

## codex 调用约定

```bash
codex exec --sandbox danger-full-access -m <tier> --skip-git-repo-check < TASK.md
```

- **沙箱必须 `danger-full-access`**：默认只读时 codex 会零改动退出，看起来像「任务失败但没报错」。
- **模型档位三选一**：`gpt-6.1-sol`（复杂/设计判断）、`gpt-6.1-terra`（中等）、`gpt-6-luna`（机械改动）。
  **禁止 `gpt-6-astra`**（成本约前者数倍）。档位可由卡片字段指定，缺省时执行者按改动复杂度判断。
- **必须 commit**：commit 是原子且可回滚的边界；不让 codex commit 会让「改了哪些、算不算完成」变模糊。
  提交信息用 conventional commits，并引用卡片 id。
- **不做 push / 不开 PR**（除非卡片显式要求）：推送与 PR 是编排者/人的决定。

## 并行规则

- **允许并行**：每张卡在自己的 worktree 里跑一个 codex 实例，worktree 之间无共享 git 状态，因此可并发。
- **同一 worktree 内只允许一个 codex 实例**（否则 index / 工作区互相踩）。
- codex 的登录态与额度是**账号级共享**：并行度受额度约束，命中用量上限时执行者应 `kanban_block`，
  不要重试烧额度。
- 卡片数量超过并发能力时，用 `--triage` 建卡，等人或编排者手动放行。

## 审查（review profile）

- 只读卡 + diff + 验收命令，**先看证据是否真实存在**（命令输出、commit hash），再看代码。
- 通过：`kanban_complete`；不通过：`kanban_request_changes` 并写清失败点（打回同一张卡重跑，审计连续）。
- 审查模型独立于执行模型（不同源，避免自己批自己）。

## worktree 生命周期

1. 建卡时 `--workspace worktree:<repo>` 创建。
2. 审查通过（`review` → `done`）后**立即删除**该 worktree 及其分支（未合并的提交由人决定是否保留）。
3. 审查未通过时保留，供打回重跑；连续失败 `block` 后保留现场等人。

## 失败与重试

- 连续失败达 `kanban.failure_limit`（默认 2）时 dispatcher 自动 `block`。
- 品类区分：额度/登录失效 → `block` 等人；环境缺失 → `block` 并写明缺什么；代码不通过 → 留在 `ready` 重试（受 `--max-retries`）。
- 阻塞原因写在 comment，**不静默放弃**。

## 信息卫生（公共仓库硬约束）

配置与文档进本仓库前必须脱敏，且**由 AI agent 执行审查**（脚本只是初筛）：

1. `scripts/check-secrets.sh` —— 正则初筛：令牌前缀、`.env`、私钥块、内网地址字面量。
2. `scripts/ai-desensitize-review.sh` —— **强制门禁**：让 agent 通读 staged diff，列出任何私有项目名、私有仓库名、
   内部主机/路径/人员信息、雇主或客户线索；有则非零退出，禁止提交。
3. 真实值一律 `<PLACEHOLDER>`，运行时从本机 `.env` / 环境变量注入。

## 与 issue-driven-dev 的分工

| | kanban-codex-dispatch | issue-driven-dev |
|---|---|---|
| 总线 | 本机 Kanban（SQLite） | GitHub issue / PR |
| 适用 | 本机、需人实时拍板、多角色协作 | 跨机异步、可无人值守、留 GitHub 审计 |
| 调度 | 网关内 dispatcher（60s tick） | 远端 cron 轮询 label |
| 产物 | 分支 + 本地 commit（可选 PR） | PR |

两者可叠加：看板卡要求执行者开 PR 时，把 `--completion-contract <OWNER/REPO>` 写进卡片，完成门槛交给
GitHub required checks。

## 版本历史

- 0.1.0: 首版。编排者沿用 `default` profile；执行者/审查者独立 profile；codex 必须 commit；并行按 worktree 隔离。

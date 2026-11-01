# SOP: Kanban → Codex 派工闭环

- 版本: 0.3.1
- 状态: draft
- 更新: 2026-11-01

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

## 装配与同步

```bash
scripts/sync.sh plan      # 只读对比 manifest 与本机，列出 drift
scripts/sync.sh apply     # 仓库 → 机器（SOUL 覆盖 + manifest 声明的 config 键）
scripts/sync.sh capture   # 机器 → 仓库（偏离写成候选，人工合并）
```

`profiles/manifest.conf` 是唯一事实源（哪个 profile、哪份 SOUL、哪些 config 键受管）；
不在清单里的键、`.env`、状态库都不参与同步。详见 `profiles/README.md`。

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

## 板拓扑

- **一项目一板**：slug 用 `work-<project>`（kebab-case），每块板自带 DB、工作区目录与独立视图。
  `default` 板不闲置，用作**收件箱**：尚未决定归属的、跨项目的、临时验证的卡片。
- **显式指定板**：`/kanban --board work-<project> ls`。不要依赖 `boards switch` 的「当前板」状态——
  纯聊天场景下很容易忘了自己在哪块板。
- **跨项目依赖**：跨板**不能**建 parent 链接，按三条规则处理：
  1. 默认弱引用——在卡片 body 写「前置：`work-<upstream>` 的 `t_xxx`，未完成不要开始」，由人或编排者把关；
  2. 真需要自动门禁时，把两张卡都放到**消费方**那块板（上游卡作父卡），用正常 `--parent`；
  3. 不做跨板同步、不做镜像卡。
- 板是**软删除**：`boards rm <slug>` 会把目录移到 `<root>/kanban/boards/_archived/<slug>-<ts>`，
  搬回来并删掉墓碑 `board.json` 即可恢复。仍需谨慎，但误删可挽回。

## 归档与检索

- `archive <ids>` 是**软归档**：状态置 `archived`，行与评论、事件全部保留；`ls --archived` 可检索，
  `show <id>` 仍能看到 body/评论/事件。**`archive --rm <ids>` 是永久删除**——除明确要销毁外禁用。
- **没有原生 unarchive 动词**（`promote` 只处理 `todo/blocked → ready`，`edit` 不改状态）。
  复活一张已归档的卡需要直接改库（急救手段，不留事件、不受支持）：

  ```bash
  sqlite3 ~/.hermes/kanban/kanban.db "UPDATE tasks SET status='done' WHERE id='t_xxxxxxxx';"
  # 命名板：~/.hermes/kanban/boards/<slug>/kanban.db
  ```

- **研究型项目**（实验多、卡片短命）按「结题即归档」处理：
  1. 归档前必须 `complete --summary` 写清结论（数据窗、结论、代码分支），summary 是日后检索的唯一入口；
  2. 归档不删分支——worktree 可以删，commit 留在分支上；
  3. 同一主题重新评估时**开新卡**并引用旧卡 id，而不是复活旧卡：数据窗与前提已变，旧卡的价值是结论与审计。

## 运行纪律（并发 / 容器 / 进程）

1. **单会话上游通道必须全局串行。** 如果数据通道是「一个账号一条登录会话」（例如只能单点登录的行情/数据终端），
   所有依赖它的卡片全局串行：动手前先确认没有别的任务占用（既有 guard 或 `flock -n` 探一次）。
   **拿不到占用就不要查**——直接 `kanban_block` 并写明「通道被占用，待时点」，不重试、不空跑烧额度。
   宁可让卡片等人，也不要两个 worker 同时登录把会话挤掉。
2. **容器只在部署/上线阶段出现。** 开发、测试、调试用本地二进制或 venv 直接跑；容器（engine / redis / 依赖编排）
   属于部署线的验收对象。不要为了让测试跑起来先拉起容器——那会把部署问题和业务问题混在一起。
3. **进程纪律：收尾必清，且禁止批量匹配杀进程。**
   - 长任务后台运行时把 PID 记进卡片评论；任务结束（成功或失败）后 `kill <PID>` 并确认退出。
   - **禁止** `pkill -f codex`、`pkill -f python` 这类按名字批量匹配的操作：同一台机器上并行跑着别的 worker，
     一次批量匹配就会把它们一起杀掉，故障现象还会伪装成「worker 莫名退出」。
   - 只允许按记录的 PID、或 `kill <父 PID>` 定向清理。
   - 收尾在评论里留一行「已清理：`<PID 列表>`，无残留」，让下一张卡能判断环境是否干净。
4. **串行用 parent 链实现，不要靠自觉。** `ready → running` 的领取阶段会复查父卡
   （`claim_rejected: parents_not_done`），所以把共享独占资源的卡串成 `A → B → C`，即使多张同时
   处于 `ready` 也只有链头会被派工。链断在一张卡上时整条线停住——这是要的行为，等人处理。
5. **验证依赖边只能读 `show <id>` 的 `parents:`，不能读 `ls --json`**（列表 JSON 不含父卡字段，
   会误报 `parents=0`）；`show` 的 `parents:` 行还可能折行，别按单行做 token 匹配。
6. **种卡前先关 `kanban.auto_decompose`。** 它默认 `True`，而它扫描的正是 `triage` 列：triage 卡会被
   改写、拆分，甚至被补上 assignee 并提升为 todo，然后真的派工。要「种下但不能跑」的静止态用
   `blocked`，不要用 `--triage`。

## 版本历史

- 0.3.1: 串行改用 parent 链（领取阶段复查父卡，链头才派工）；验证依赖边只读 `show <id>`；
  种卡前关 `kanban.auto_decompose`（它默认开着并扫描 `triage` 列，会拆分并派工）
- 0.3.0: 增加运行纪律——单会话上游通道全局串行（拿不到即 block，不重试）、容器只在部署阶段、
  进程收尾必清且禁止批量匹配杀进程（只按记录 PID 定向清理）
- 0.2.0: 增加板拓扑（一项目一板 + 收件箱、跨项目弱引用规则、板软删除）与归档检索（软归档、
  无原生 unarchive、研究型项目结题即归档）
- 0.1.0: 首版。编排者沿用 `default` profile；执行者/审查者独立 profile；codex 必须 commit；并行按 worktree 隔离。

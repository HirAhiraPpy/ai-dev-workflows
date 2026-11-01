# Lesson：Kanban 派工 allowlist、profile 装配与两道脱敏门禁

- 日期: 2026-11-01
- 触发: 首次跑通 `SOPs/kanban-codex-dispatch`（impl → review 双 profile → codex）

## 1. `kanban.dispatch_profiles` 必须逗号分隔

`hermes config set kanban.dispatch_profiles "impl-codex review"`（空格分隔）会被读成**一个**名字：

```
allowlist: frozenset({'impl-codex review'})
```

后果：卡片一直停在 `ready`，事件里只有 `skipped_nonspawnable {'assignee': 'impl-codex'}`，
看起来像「dispatcher 不工作」。正确写法是逗号分隔或 YAML 列表：

```bash
hermes config set kanban.dispatch_profiles "impl-codex,review"   # → frozenset({'impl-codex','review'})
```

**配置修改对运行中的 dispatcher 立即生效**（下一 tick 就认），不需要重启网关——这一点与
「改了 systemd 单元」不同，别多此一举重启。

## 2. `hermes profile create` 自带默认 SOUL/config

新建 profile 时会被塞进一份默认 `SOUL.md` 和 `config.yaml`。若装配脚本写成「已存在就跳过」，
角色人格**永远不会生效**。正确的同步语义：

- `SOUL.md`：仓库为事实源，**每次覆盖**（合并 `_shared/SOUL.md` + 角色 SOUL）。
- `config.yaml`：承载本机状态，默认不覆盖；渲染结果另存 `config.bootstrap.yaml` 供人工比对。

## 3. profile 不继承主 profile 的 `.env`

worker 首次冒烟报 `No usable credentials found for provider '<X>'`：profile 的 `.env` 是独立的。
每个 worker profile 必须自行写入 provider key（600 权限，绝不入库）。

## 4. 两道门禁自身的写法约束

- `check-secrets.sh` 的文件名规则会命中门禁脚本自身 → 对门禁脚本加路径 allowlist。
- `ai-desensitize-review.sh` 的结论解析必须**行首锚定**（`^(CLEAN|PRIVATE-FOUND:)`）：diff 正文里可能
  本身出现同名字面量，宽松匹配会把通过的结论读成不通过。
- 提示词与仓库文本都不要放可被再次引用的内部指代样例；用抽象描述，否则每轮审查都会自判命中。
- 提示词需显式声明「本仓库自身的相对路径不算私有信息」，否则文档只要提到自己的目录结构就会被拦。

## 5. worktree 生命周期（实测）

一卡一 worktree：`.worktrees/<task-id>` + 分支 `wt/<task-id>`，master 不动。审查通过后：

```bash
git merge --ff-only wt/<task-id>
git worktree remove .worktrees/<task-id> --force
git branch -d wt/<task-id>
```

审查未过则保留现场供打回重跑。

## 6. 值得保留的审查动作

review profile 自己加的两步核查很有价值，建议写进卡片的审查验收项：

1. **pristine 复核**：`git archive <commit> | tar -x -C <tmp>` 后在干净副本里复跑，排除工作区残留影响。
2. **变异检查**：故意把被测函数改坏再跑，确认测试会失败（证明用例不是空转）。

## 产物

- 一次完整闭环：`ready → running → done`（impl） → 子卡自动 `ready → done`（review），
  codex 在 worktree 内做原子 commit（`Refs: <card-id>`），执行者自跑验收，审查者独立复核后合并清理。

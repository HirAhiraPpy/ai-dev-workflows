# 卡片模板

复制到 `hermes kanban create --body "$(cat templates/kanban-card.md)"` 或看板 UI 的 body 里。

```markdown
## 目标
<一句话：要达成的结果，不是步骤>

## 不做什么
- <排除范围 1>
- <排除范围 2>

## 现状扫描（要新建分支或 PR 时**必填**）
- 命令：`scripts/pr-overlap-scan.sh <会改动的路径…>`
- 结论：<复用 / 重开 / 合并> + 一行理由
- 已有载体处置：<在哪个 PR/分支上继续，或旧 PR 由谁关闭——不许写「由操作者决定」>

## 验收
- 工作区：worktree:<repo-path>
- 命令：`<build>` ；`<test>`
- 期望：退出码 0；关键输出包含 `<关键行>`

## 证据
- 每条验收命令的退出码与关键输出
- `git log --oneline -1`（原子 commit）
- `git diff --stat HEAD~1`（改动范围）

## 备注
- 相关文件：<path>[, <path>]
- 前置卡片：<card-id>（若本卡依赖它，用 --parent 建依赖，不要只在正文写）
```

## 建卡命令示例

```bash
hermes kanban create "<标题>" \
  --body-file templates/kanban-card.md \
  --assignee impl-codex \
  --workspace worktree:<repo-path> \
  --max-retries 2
```

审查卡：

```bash
hermes kanban create "审查 <实现卡标题>" \
  --body "只读 diff 与证据，重跑验收命令，通过则 complete，否则 request-changes 并写明失败点。" \
  --assignee review \
  --parent <实现卡 id>
```

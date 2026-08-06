# SOP: issue 驱动的 AI 开发闭环

- 版本: 0.2.0
- 状态: draft
- 更新: 2026-08-06

## 参与者

| 角色 | 实体 | 职责 |
|---|---|---|
| 编排者 | 本机 Hermes | 提 issue、收结果、失败升级兜底 |
| 执行者 | EC2 codex worker | 消化 issue、实现、开 PR |
| 总线 | GitHub issue + PR | 异步任务传递，所有状态变化反映在 GitHub 上 |

## 流程

1. **下发**：编排者按 `issue-template.md` 创建 issue，打 label `codex-task`
2. **轮询**：EC2 worker（cron 每 5 分钟）执行 `gh issue list --label codex-task --state open`
3. **命中**：`reset --hard` + `clean` 清理工作区 → 检出最新 `main` → `git submodule update --remote workflows` → 组装提示词 → worker 内 openai SDK agent loop（`shell` + `apply_patch` 工具）实现
4. **成功**：推分支 → `gh pr create`（`Closes #N`）→ issue 评论执行摘要 → 移除 `codex-task` label
5. **失败**：重试 ≤2 次 → 仍失败：issue 加 `needs-help` label + 评论失败原因与现场
6. **升级**：编排者轮询 `needs-help` / 新 PR → 汇报用户 / 本机接手修复

## 硬约定

- 所有 clone 必须 `--recursive`——**项目根 AGENTS.md 是 symlink 直连 submodule 内文件，submodule 缺失即断链**
- **submodule 单向**：内容只改公共仓库；项目内只做 update / pin，禁止在 submodule 目录内 commit
- **串行执行**：一次只处理一个任务（t4g.micro 1GB 内存约束）
- 环境敏感信息一律占位符，真实值在项目私有配置（`GH_TOKEN` / `DEEPSEEK_API_KEY` 运行时 env 注入，worker.py 内 GIT_ASKPASS 读 env 不落盘）
- worker 幂等：重复执行同一 issue 不应产生副作用（已处理的跳过）
- 凭证：git HTTPS 认证走 `GIT_ASKPASS`（从 `GH_TOKEN` 读）；gh CLI 直接识别 `GH_TOKEN` env

## 版本历史

- 0.2.0: codex CLI 调用改为 openai SDK agent loop；git 前置全检查返回码；GIT_ASKPASS 凭证；flock 防并发
- 0.1.0: MVP，本 SOP 首次落地

# 项目 Agent 规范（公共仓库版，被项目根薄 AGENTS.md 指针引用）

codex 等执行 agent 在项目内按本规范执行任务。

## 任务来源

- 任务以 GitHub issue 形式下发，必须包含：目标、约束、验收标准、相关文件
- **完成标准 = issue 验收标准全部满足**，不自行扩大范围

## 开发规范

- 提交信息：conventional commits（`feat:` / `fix:` / `refactor:` / `test:` / `docs:`）
- 变更必须附带测试（如适用），测试必须通过
- 不修改与本任务无关的代码
- 尊重项目现有架构与代码风格；与既有模式冲突时，遵循既有模式

## 完成流程

1. 实现 + 测试（本地运行验证）
2. 推分支 `feature/<issue-no>-<slug>`
3. 开 PR，描述引用 issue（`Closes #N`），格式见 templates/PR-description.md

## 失败处理

- 遇到阻塞（环境、依赖、歧义）：在 issue 评论中说明，不静默放弃
- 尝试 ≤2 次仍失败：停止并保留现场（diff / 错误日志），等待人工接手

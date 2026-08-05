---
name: issue-authoring
description: "为 issue-driven-dev 闭环编写高质量 issue（codex 消化质量的源头）"
version: 0.1.0
---

# Issue 编写规范（编排者侧）

## 触发

向 EC2 codex worker 下发任务时使用。

## 原则

- **验收标准决定成败**：codex 以"验收标准全部满足"为完成。写不清 = 空转或越界
- 一个 issue = 一个任务；可拆则拆
- 标注环境限制（ARM、内存、网络）——执行者是另一台机器

## 结构

用 templates/issue-template.md：目标 → 背景 → 约束 → 验收标准 → 相关文件

## 流程

1. 按模板创建 issue
2. 打 label `codex-task`（worker 的轮询条件）
3. 预期结果：worker 开 PR（`Closes #N`）+ 移除 label；失败则加 `needs-help`

## 失败升级

`needs-help` 的 issue：本机 Hermes 接手（pull 分支 / 本地复现 / 人工介入），
修复后把"为什么会失败"回写 docs/lessons/，驱动 SOP 版本演进。

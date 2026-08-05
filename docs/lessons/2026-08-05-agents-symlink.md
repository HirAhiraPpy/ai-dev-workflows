# Lesson 001: AGENTS.md 引用方式 —— 薄指针 → symlink 直连

- 日期: 2026-08-05
- 来源: 用户设计评审（Phase 0）
- 状态: 已采纳

## 背景

初版设计：项目根放"薄 AGENTS.md 指针"（3 行），完整规范在 submodule `agents/project-default.md`。
理由：担心 agent 生态不解析 symlink、且 AGENTS.md 必须是根目录真实文件。

## 修正

用户指出可直接 `AGENTS.md -> workflows/agents/project-default.md`（symlink）。

## 论证（为何可行且更优）

1. codex / Copilot / Claude Code 读取根 AGENTS.md 均走标准文件 IO，默认 follow symlink —— 已由本机 codex 实测验证可读
2. git 提交 symlink 本身（mode 120000）；`--recursive` clone 后 submodule 实体存在，symlink 即有效
3. 本机 + EC2 均为 Linux，无 Windows symlink 权限问题
4. 收益：项目根**零副本**，单一事实源更纯粹；薄指针方案仍有双份存在且 agent 需多一跳

## 硬约束

- clone 必须 `--recursive`（submodule 缺失时 symlink 断链）
- CI（如 GitHub Actions）需显式 `submodules: recursive` 配置
- symlink 目标是**相对路径**（相对项目根），与仓库磁盘布局无关

## 影响

- 本项目 SOP.md 硬约定已强化
- 后续所有引用 ai-dev-workflows 的项目统一采用此模式

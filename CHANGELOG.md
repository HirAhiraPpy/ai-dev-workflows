# Changelog

## 0.2.0 (2026-08-06)

- worker v0.2：openai SDK agent loop 替代 codex CLI（Responses API + shell/apply_patch 工具）
- git 前置全检查返回码 + reset --hard 清理 + flock 防并发 + 空 diff 检测
- GIT_ASKPASS 凭证（GH_TOKEN env 注入，不落盘）；remote 约束 HTTPS
- run-worker.sh v7.2 入库（启动前 submodule 更新 + 运行后 chown 兜底）
- 镜像 binance-worker:latest 加 openai SDK + patch
- 端到端验证：issue #6 → PR #7（27 steps）→ 合并 → 真实 API 验证通过
- Lesson 002：worker v0.2 踩坑记录

## 0.1.0 (2026-08-05)

- MVP 落地：issue-driven-dev SOP v0.1、worker v0.1、agents 规范 v0.1
- 架构决策：公共仓库 + git submodule 引用（pinned 语义，MVP 期 update --remote 保持 rolling）

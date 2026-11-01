# Changelog

## 0.4.4 (2026-11-01)

- SOP 0.4.1：门禁触发从 cron 改为调度器 tick 上的插件 `kanban-pr-gate`（不用 cron、不发聊天通知，
  结果只落 PR 评论/卡片/日志）；新增「开工前先扫重叠」节与卡片模板必填节「现状扫描」
- scripts/pr-overlap-scan.sh：新建分支或 PR 前扫开放 PR 与远端分支中改到同一批路径的载体，
  退出码 10 = 发现重叠；结论要求贴进卡片评论
- profiles/impl-codex/SOUL.md：开工前先扫重叠、扫完再决定复用/重开

## 0.4.3 (2026-11-01)

- SOP 0.4.0：新增 PR 门禁节——`pr-gate` worker 自动触发（每 5 分钟扫 done 卡的 PR 链接、
  按 head sha 去重、单轮上限 2 张、门禁卡不设 parent）、门禁结论写回 PR 与卡片、合并仍由人拍板；
  新增 PR 形态规则（从 main 切分支、最小 commit，保留合并需写明依赖）；
  脚本 `scripts/pr-gate-trigger.py`

- SOP 0.3.0：新增运行纪律——依赖单登录会话的数据通道必须全局串行（拿不到占用就 block，不重试不空跑）、
  开发测试用本地二进制/venv 而容器只属于部署阶段、进程收尾必须清理且禁止 `pkill -f`/`pgrep` 批量匹配
  （只按记录的 PID 定向清理，避免误杀同机其它 worker）

## 0.4.1 (2026-11-01)

- SOP 0.2.0：板拓扑（一项目一板 `work-<project>` + `default` 收件箱、跨板不建依赖的三条处理规则、
  板软删除可恢复）与归档检索（软归档可查、`--rm` 禁用、无原生 unarchive、研究型项目结题即归档）

## 0.4.0 (2026-11-01)

- 新增 `scripts/sync.sh` 三动词：`plan`（只读对比 manifest 与本机，drift 入退出码）、`apply`（仓库 → 机器，
  SOUL 覆盖 + 只写受管 config 键）、`capture`（机器 → 仓库，偏离写成候选供人工合并）
- 新增 `profiles/manifest.conf`：唯一事实源，声明每个 profile 的 SOUL 与受管 config 键
- `bootstrap.sh` 降级为 `sync.sh apply` 的兼容入口；删除 `capture.sh` 与各 profile 的 `config.yaml` 模板
  （取值统一进 manifest，避免两处漂移）
- `profiles/README.md` 重写为同步模型说明：仓库声明应然、本机承载实然；`.env`/状态/非受管键不参与

## 0.3.0 (2026-10-31)

- 新增 `SOPs/kanban-codex-dispatch/`：本机 Kanban 派工闭环（编排者沿用 default profile，执行者驱动 codex CLI，
  审查者独立 profile）；codex 必须做原子 commit，并行按 worktree 隔离，审查通过后删除 worktree
- 新增 `profiles/`：worker profile 的可版本化组成（`_shared/SOUL.md` 纪律 + `impl-codex` / `review` 角色）
- 新增 `scripts/`：`bootstrap.sh`（仓库→本机装配）、`capture.sh`（本机→仓库抓取）、
  `check-secrets.sh`（初筛）、`ai-desensitize-review.sh`（**AI agent 脱敏门禁**，脚本不可替代）
- 新增 `templates/kanban-card.md` 与 `skills/kanban-card-authoring/`
- README 补充工作流地图与两道门禁

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

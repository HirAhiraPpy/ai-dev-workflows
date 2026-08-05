# ai-dev-workflows

个人 AI 开发工作流知识库：**单一事实源**（Single Source of Truth）。

项目通过 **git submodule** 引用本仓库，获得 SOP / AGENTS 规范 / skills / 模板，避免多项目复制导致的漂移。

## 工作流地图

| 目录 | 内容 | 消费者 |
|---|---|---|
| `SOPs/issue-driven-dev/` | issue 驱动的 AI 开发闭环（issue → codex → PR） | worker / 人 |
| `agents/` | AGENTS.md 指针目标（声明式项目规范） | codex 等执行 agent |
| `skills/` | 给 AI agent 的过程式知识（Hermes-compatible） | 本机 Hermes |
| `templates/` | issue / PR 模板 | 编排者 |
| `docs/lessons/` | 每次运行的复盘（踩坑 → 修复 → 版本化） | 人 |

## 引用矩阵

| 项目 | 引用方式 | 当前 pin |
|---|---|---|
| binance-collector | submodule `workflows/` | 初始 commit |

## 使用方式

```bash
# 项目内添加
git submodule add https://github.com/HirAhiraPpy/ai-dev-workflows.git workflows

# clone 时必须带 --recursive（否则 submodule 为空）
git clone --recursive <repo>

# 更新（MVP 期 rolling 语义；稳定后改为锁 commit）
git submodule update --remote workflows
```

## 信息卫生（硬约束）

本仓库为**公共仓库**，禁止提交任何密钥 / token / IP / 实例 ID / 密钥名。
一律使用 `<PLACEHOLDER>`，真实值放各项目私有配置（gitignore）。

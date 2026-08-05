---
name: codex-deepseek
description: "Codex CLI 配置与坑（DeepSeek 自定义 provider 版）"
version: 0.1.0
---

# Codex CLI + DeepSeek（通用版）

本 skill 是公共仓库的通用版；本机 Hermes 的 codex skill 为带环境细节的实例版，内容同源。

## 安装

```bash
npm install -g @openai/codex
sudo ln -sf "$(npm prefix -g)/bin/codex" /usr/local/bin/codex   # PATH 修正
```

## 配置要点（~/.codex/config.toml）

- **codex 0.146+ 已移除 `wire_api = "chat"`，只能用 `"responses"`** —— provider 必须支持 OpenAI Responses API，否则需 LiteLLM 等代理
- `api_key` 可直接内嵌在 `[model_providers.X]`（无需 env var，cron 友好）
- 补模型元数据消除性能警告：`[model_providers.X.models.<model>]`（context_window / max_output_tokens / reasoning）
- 空 `[approval_policy]` 表非法（"wanted exactly 1 element"），省略即可
- 容器环境 bwrap 沙箱不可用（`RTM_NEWADDR` 权限）→ `sandbox_mode = "danger-full-access"`

## 验证

```bash
curl $BASE_URL/responses -H "Authorization: Bearer $KEY" -d '{"model":"...","input":"hi"}'
```

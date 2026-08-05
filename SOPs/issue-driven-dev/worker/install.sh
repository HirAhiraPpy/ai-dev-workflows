#!/usr/bin/env bash
# EC2 worker 一键安装（MVP v0.1）。幂等，可重复执行。
set -euo pipefail

echo "== 1/5 安装 gh CLI =="
command -v gh >/dev/null || (sudo mkdir -p -m 755 /etc/apt/keyrings \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt-get update -qq && sudo apt-get install -y -qq gh)

echo "== 2/5 安装 codex CLI =="
if ! command -v codex >/dev/null; then
  npm install -g @openai/codex
  sudo ln -sf "$(npm prefix -g)/bin/codex" /usr/local/bin/codex
fi

echo "== 3/5 写入 ~/.codex/config.toml =="
mkdir -p ~/.codex
# key 从环境变量 DEEPSEEK_API_KEY 读取（安装时手动 export，不入库）
cat > ~/.codex/config.toml <<EOF
model = "deepseek-v4-flash"
model_provider = "deepseek"
sandbox_mode = "danger-full-access"

[model_providers.deepseek]
name = "DeepSeek"
base_url = "https://api.deepseek.com/v1"
env_key = "DEEPSEEK_API_KEY"
wire_api = "responses"

[model_providers.deepseek.models.deepseek-v4-flash]
name = "DeepSeek V4 Flash"
context_window = 131072
max_output_tokens = 8192
reasoning = true
EOF
chmod 600 ~/.codex/config.toml
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "!! 请先 export DEEPSEEK_API_KEY=<你的key> 再运行本脚本（或写入 ~/.bashrc）"
  exit 1
fi
grep -q DEEPSEEK_API_KEY ~/.bashrc || echo "export DEEPSEEK_API_KEY='$DEEPSEEK_API_KEY'" >> ~/.bashrc

echo "== 4/5 配置 git 与 GitHub 凭证 =="
git config --global user.name "codex-worker"
git config --global user.email "<PLACEHOLDER>"
echo "!! 需要写权限：请将 EC2 生成的 SSH 公钥添加为 binance-collector 的 deploy key（allow write）"
echo "   生成: ssh-keygen -t ed25519 -f ~/.ssh/worker -N ''"
echo "   添加: gh repo deploy-key add ~/.ssh/worker.pub --repo HirAhiraPpy/binance-collector --allow-write"
echo "   然后: gh auth login（GH_TOKEN 方式，token 需 repo + pull_request 权限）"

echo "== 5/5 安装 cron（每 5 分钟） =="
WORKER_SCRIPT="$(cd "$(dirname "$0")" && pwd)/worker.py"
(crontab -l 2>/dev/null | grep -v issue-driven-dev || true; echo "*/5 * * * * cd $(dirname "$WORKER_SCRIPT") && python3 $WORKER_SCRIPT >> ~/worker.log 2>&1") | crontab -
echo "cron 已安装。日志: ~/worker.log"

echo "== 完成。手动验证: python3 $WORKER_SCRIPT =="

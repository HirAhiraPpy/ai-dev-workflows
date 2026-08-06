#!/usr/bin/env bash
# EC2 worker 一键安装（MVP v0.2）。幂等，可重复执行。
# 依赖变更：v0.2 起不再需要 codex CLI，改用 openai SDK（worker.py 内 agent loop）。
set -euo pipefail

echo "== 1/5 安装 gh CLI =="
command -v gh >/dev/null || (sudo mkdir -p -m 755 /etc/apt/keyrings \
  && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
  && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
  && sudo apt-get update -qq && sudo apt-get install -y -qq gh)

echo "== 2/5 安装 openai SDK + patch =="
command -v python3 >/dev/null || sudo apt-get install -y -qq python3
python3 -c "import openai" 2>/dev/null || (sudo apt-get install -y -qq python3-pip && pip3 install --break-system-packages openai)
command -v patch >/dev/null || sudo apt-get install -y -qq patch

echo "== 3/5 写入环境变量（凭证不入库） =="
if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
  echo "!! 请先 export DEEPSEEK_API_KEY=<你的key> 再运行本脚本（或写入 ~/.bashrc）"
  exit 1
fi
grep -q DEEPSEEK_API_KEY ~/.bashrc || echo "export DEEPSEEK_API_KEY='$DEEPSEEK_API_KEY'" >> ~/.bashrc
if [ -z "${GH_TOKEN:-}" ]; then
  echo "!! 请先 export GH_TOKEN=<fine-grained PAT，需 binance-collector 读写>"
  exit 1
fi
grep -q '^export GH_TOKEN=' ~/.bashrc || echo "export GH_TOKEN='$GH_TOKEN'" >> ~/.bashrc
# gh CLI 识别 GH_TOKEN 环境变量即完成认证
gh auth status >/dev/null 2>&1 || echo "!! gh auth 未生效，请确认 GH_TOKEN 权限"

echo "== 4/5 配置 git 身份 =="
git config --global user.name "codex-worker"
git config --global user.email "<PLACEHOLDER>"
# 凭证由 worker.py 的 GIT_ASKPASS 从 GH_TOKEN 注入，无需额外配置

echo "== 5/5 安装 cron（每 5 分钟） =="
WORKER_SCRIPT="$(cd "$(dirname "$0")" && pwd)/worker/worker.py"
(crontab -l 2>/dev/null | grep -v issue-driven-dev || true; echo "*/5 * * * * cd $(dirname "$WORKER_SCRIPT") && python3 $WORKER_SCRIPT >> ~/worker.log 2>&1") | crontab -
echo "cron 已安装。日志: ~/worker.log"

echo "== 完成。手动验证: python3 $WORKER_SCRIPT =="

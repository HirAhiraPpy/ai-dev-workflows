#!/usr/bin/env bash
# EC2 容器化 worker 运行脚本（v7.1：worker 启动前先更新 submodule，避免旧版 worker.py 被加载）
# 凭证：GH_TOKEN / DEEPSEEK_API_KEY 运行时 env 注入，worker.py 内 GIT_ASKPASS 自管，不落盘
# 用法：DEEPSEEK_API_KEY=xxx GH_TOKEN=xxx bash /home/ubuntu/run-worker.sh
set -euo pipefail

IMAGE="122066463008.dkr.ecr.ap-northeast-1.amazonaws.com/binance-worker:latest"
REPO="/home/ubuntu/binance-collector"

docker run --rm \
  -e DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:?需要 DEEPSEEK_API_KEY}" \
  -e GH_TOKEN="${GH_TOKEN:?需要 GH_TOKEN}" \
  -e WORKER_REPO_DIR="/workspace" \
  -v "${REPO}:/workspace" \
  -w /workspace \
  "$IMAGE" \
  bash -lc '
    set -e
    # 容器内 git 基础配置（宿主文件 owner 是 ubuntu，容器是 root，必须 safe.directory）
    git config --global user.name "codex-worker"
    git config --global user.email "codex-worker@users.noreply.github.com"
    git config --global --add safe.directory /workspace
    git config --global --add safe.directory /workspace/workflows

    # 关键：worker.py 从 submodule 加载，Python 启动即编译 → 必须在启动前更新 submodule
    echo "--- 更新 submodule（保证 worker.py 是最新版）---"
    git submodule update --init --remote workflows
    grep -c "openai SDK" /workspace/workflows/SOPs/issue-driven-dev/worker/worker.py || echo "WARN: worker.py 不是 v0.2"

    echo "--- 启动 worker v0.2（openai SDK agent loop）---"
    python3 /workspace/workflows/SOPs/issue-driven-dev/worker/worker.py
    echo "WORKER_EXIT=$?"
  '

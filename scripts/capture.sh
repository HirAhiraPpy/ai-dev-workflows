#!/usr/bin/env bash
# 本机 → 仓库：把某个 profile 的 SOUL.md / config.yaml 抓回 profiles/ 下，做初步脱敏后给人看 diff。
# **不自动提交**；提交前必须跑 check-secrets.sh + ai-desensitize-review.sh 两道门禁。
#
# 用法：scripts/capture.sh impl-codex
set -uo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}

name=${1:-}
[ -n "$name" ] || { echo "用法: scripts/capture.sh <profile-name>"; exit 2; }
src="$HERMES_HOME/profiles/$name"
[ -d "$src" ] || { echo "${RED}没有这个 profile：$src${NC}"; exit 1; }
dst="$REPO_ROOT/profiles/$name"
mkdir -p "$dst"

# 初步脱敏：家目录与常见私有前缀 → 占位符；不处理语义级私有信息（那是 AI 审查的活）
sanitize() {
  sed -E \
    -e "s|$HOME|<HOME>|g" \
    -e "s|/home/[A-Za-z0-9._-]+|<HOME>|g" \
    -e "s|/Users/[A-Za-z0-9._-]+|<HOME>|g" \
    -e "s|(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|<PRIVATE-IP>|g" \
    -e "s|(sk|ark|ghp|glpat)-[A-Za-z0-9_-]{8,}|<TOKEN>|g" \
    -e "s|Bearer [A-Za-z0-9._-]+|Bearer <TOKEN>|g"
}

if [ -f "$src/SOUL.md" ]; then
  sanitize < "$src/SOUL.md" > "$dst/SOUL.raw.md"
  echo "→ 抓到 SOUL.md（$dst/SOUL.raw.md）"
fi
if [ -f "$src/config.yaml" ]; then
  sanitize < "$src/config.yaml" > "$dst/config.raw.yaml"
  echo "→ 抓到 config.yaml（$dst/config.raw.yaml）"
fi

echo
echo "${YEL}人工/agent 合并步骤${NC}："
echo "  1) 对比 *.raw.* 与仓库里现有的 SOUL.md / config.yaml，把变化部分合并进正式文件（保留占位符与注释）"
echo "  2) 删除 *.raw.* 临时文件"
echo "  3) git add -A && scripts/check-secrets.sh && scripts/ai-desensitize-review.sh"
echo
echo "当前的 raw 差异："
git -C "$REPO_ROOT" --no-pager diff --stat -- "profiles/$name" 2>/dev/null || true

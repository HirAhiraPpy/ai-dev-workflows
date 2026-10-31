#!/usr/bin/env bash
# 初筛：公共仓库提交前的正则扫描（**不是**脱敏门禁的全部）。
# 真正的门禁是 ai-desensitize-review.sh —— 由 AI agent 通读 diff 判定私有信息。
#
# 用法：
#   scripts/check-secrets.sh              # 扫描 staged 变更
#   scripts/check-secrets.sh --all        # 扫描全仓（不含 .git）
# 退出码：0 干净；1 命中。
set -uo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL='\033[0;33m'; NC=$'\033[0m'
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

PATTERNS=(
  'sk-[A-Za-z0-9_-]{16,}'                 # 通用 API key 前缀
  'ark-[A-Za-z0-9-]{16,}'                 # 方舟风格 key
  'ghp_[A-Za-z0-9]{20,}'                  # GitHub PAT
  'github_pat_[A-Za-z0-9_]{20,}'          # GitHub fine-grained PAT
  'glpat-[A-Za-z0-9_-]{16,}'              # GitLab PAT
  'xox[baprs]-[A-Za-z0-9-]{10,}'          # Slack
  'AKIA[0-9A-Z]{16}'                      # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'    # 私钥块
  '(10|127)\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
  '192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
  '172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}'
  'i-[0-9a-f]{8,}'                        # 云实例 ID
  'lhins-[a-z0-9]{8,}'                    # 云实例 ID（另一种命名）
)

if [ "${1:-}" = "--all" ]; then
  FILES=$(git ls-files)
  LABEL="全仓文件"
else
  FILES=$(git diff --cached --name-only --diff-filter=ACM)
  LABEL="staged 文件"
fi

if [ -z "$FILES" ]; then
  echo "${YEL}没有可扫描的${LABEL}${NC}（staged 为空时可先 git add）"
  exit 0
fi

hits=0
for pat in "${PATTERNS[@]}"; do
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -nEI -- "$pat" "$f" >/dev/null 2>&1; then
      echo "${RED}命中${NC} $pat  →  $f"
      grep -nEI -- "$pat" "$f" | head -3 | sed 's/^/    /'
      hits=$((hits+1))
    fi
  done <<< "$FILES"
done

# 文件名本身也不该带敏感标记；本仓库的两个门禁脚本按职责命名，属已知例外
ALLOWLIST=("scripts/check-secrets.sh" "scripts/ai-desensitize-review.sh")
while IFS= read -r f; do
  skip=0
  for a in "${ALLOWLIST[@]}"; do [ "$f" = "$a" ] && skip=1; done
  [ "$skip" = 1 ] && continue
  case "$f" in
    *.env|.env*|*token*|*credential*|*secret*|id_rsa*|*.pem|*.pfx)
      echo "${RED}可疑文件名${NC} $f"; hits=$((hits+1));;
  esac
done <<< "$FILES"

if [ "$hits" -gt 0 ]; then
  echo
  echo "${RED}初筛失败：${hits} 处可疑${NC}。改写为 <PLACEHOLDER> 后重跑。"
  echo "注意：即使这里通过，仍必须跑 scripts/ai-desensitize-review.sh 才能提交。"
  exit 1
fi

echo "${GRN}初筛通过${NC}（${LABEL}）。下一步：scripts/ai-desensitize-review.sh —— 该门禁由 AI agent 判定，脚本不能替代。"

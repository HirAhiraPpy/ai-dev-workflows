#!/usr/bin/env bash
# 脱敏门禁：让 AI agent 通读 diff，判定是否含私有信息。**这是提交前必须有的一道门。**
# 脚本只负责把 diff 喂给 agent 并解析结论；判定本身由 agent 做（人类不逐行看 diff 时尤其重要）。
#
# 用法：
#   scripts/ai-desensitize-review.sh                 # 审 staged 变更（默认）
#   scripts/ai-desensitize-review.sh --range main..HEAD
# 依赖：codex CLI 可用（$CODEX_BIN 可覆盖）。
# 退出码：0 干净；1 有私有信息；2 环境/调用失败。
set -uo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL='\033[0;33m'; NC=$'\033[0m'
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

CODEX_BIN=${CODEX_BIN:-codex}
REVIEW_MODEL=${REVIEW_MODEL:-gpt-6-luna}     # 审查用便宜档即可；不用高价档
DIFF_ARGS=()
case "${1:-}" in
  --range) DIFF_ARGS=(git diff --no-color "${2:?need range}") ;;
  *)       DIFF_ARGS=(git diff --cached --no-color) ;;
esac

command -v "$CODEX_BIN" >/dev/null 2>&1 || { echo "${RED}找不到 $CODEX_BIN${NC}"; exit 2; }

DIFF=$("${DIFF_ARGS[@]}")
if [ -z "$DIFF" ]; then
  echo "${YEL}没有可审的 diff${NC}（staged 为空时可先 git add，或用 --range <a>..<b>）"
  exit 0
fi
printf '%s' "$DIFF" > /tmp/desensitize-diff.$$.txt
trap 'rm -f /tmp/desensitize-diff.$$.txt' EXIT

PROMPT=$(cat <<'EOF'
你是公共仓库的脱敏审查员。审下面这份 git diff，只判断一件事：其中是否出现**不可公开**的信息。

必须报出（逐条给文件 + 行内容片段）：
- 私有/内部项目名、私有仓库名、产品代号、客户或雇主名称
- 内部主机名、内网域名、内网 IP、端口习惯、云实例 ID、账号 ID
- 人员姓名、工号、邮箱、即时通讯 ID
- 任何令牌、密钥、口令、Cookie、私钥、连接串
- 只有内部才懂的含糊指代（不带具体对象名称的说法，读者无法据此定位公开来源）

不算问题：公开 API 域名、通用占位符（<PLACEHOLDER>）、开源项目名、标准命令与路径，
以及本仓库自身的相对路径（`SOPs/`、`profiles/`、`scripts/`、`skills/`、`templates/`、`docs/`、`agents/`）。

以下同样**不算**私有信息（它们就是本仓库自身的内容，不是外部项目的痕迹）：
- 仓库内定义的 profile/角色名：`impl-codex`、`review`、`pr-gate`
- 本仓库脚本名与参数：`gh-bot.sh`、`gh-app-token.py`、`pr-gate-trigger.py`、`sync.sh`、
  `bootstrap.sh`、`capture.sh`、`check-secrets.sh`
- 看板工具自带的状态名与工具名：`triage`、`todo`、`ready`、`running`、`blocked`、`review`、
  `done`、`archived`、`kanban_show`、`kanban_comment`、`kanban_block`、`kanban_complete`
- 本仓库脚本生成的卡片标题前缀：`【PR门禁】`、`【线A·…】` 之类的分类前缀
- 模型档位标识（如 `gpt-6.1-sol`、`gpt-6-luna`）

只输出一行结论（不要引用、回显或总结输入内容，不要解释、不要建议）：
CLEAN
或
PRIVATE-FOUND: <用分号分隔的条目>

diff 如下：
EOF
)

echo "→ 交给 $CODEX_BIN ($REVIEW_MODEL) 审查 $(printf '%s' "$DIFF" | wc -l) 行 diff …"
OUT=$( { printf '%s\n\n' "$PROMPT"; cat /tmp/desensitize-diff.$$.txt; } \
  | "$CODEX_BIN" exec --sandbox read-only --skip-git-repo-check -m "$REVIEW_MODEL" 2>&1 )

if [ $? -ne 0 ] && [ -z "$OUT" ]; then
  echo "${RED}审查调用失败${NC}"; exit 2
fi

# 只认锚定在行首的结论行：diff 正文里可能本身就出现 CLEAN / PRIVATE-FOUND 字样
VERDICT=$(echo "$OUT" | grep -E '^(CLEAN|PRIVATE-FOUND:)' | tail -1)
echo "结论：${VERDICT:-<空>}"

if [ -z "$VERDICT" ]; then
  echo "${RED}无法解析审查结论${NC}——按未通过处理（fail-closed）。原文尾部："
  echo "$OUT" | tail -20
  exit 1
fi
if printf '%s' "$VERDICT" | grep -q '^PRIVATE-FOUND:'; then
  echo
  echo "${RED}脱敏门禁未通过${NC}：把上面列出的内容改写为占位符，重新 stage 后再审。"
  exit 1
fi
echo "${GRN}脱敏门禁通过${NC}（AI 审查）。"
exit 0

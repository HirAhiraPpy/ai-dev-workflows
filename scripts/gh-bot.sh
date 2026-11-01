#!/usr/bin/env bash
# 以指定机器人身份运行命令：设置 GH_TOKEN 与 git 作者/提交者，避免所有 agent 共用一个人身份。
#
# 用法：
#   source scripts/gh-bot.sh pr-gate            # 之后 gh / git 都按机器人身份
#   scripts/gh-bot.sh pr-gate gh pr comment 12 --body-file body.md
#
# 需要（放在本机 secret 目录，600，不入库）：
#   <SECRETS_DIR>/github/app-<role>.id       App ID
#   <SECRETS_DIR>/github/app-<role>.pem      App 私钥
#   <SECRETS_DIR>/github/app-<role>.slug     App slug（用于 bot 邮箱）
# 目标仓库用 GH_BOT_REPO=<owner>/<repo> 指定（默认从 git remote 推断）。
set -euo pipefail

role="${1:?用法: gh-bot.sh <role> [command ...]}"
shift || true

secrets="${SECRETS_DIR:-$HOME/.secrets}/github"
app_id_file="$secrets/app-$role.id"
key_file="$secrets/app-$role.pem"
slug_file="$secrets/app-$role.slug"

for f in "$app_id_file" "$key_file" "$slug_file"; do
  [ -r "$f" ] || { echo "缺少凭据文件: $f" >&2; exit 2; }
done

repo="${GH_BOT_REPO:-$(git config --get remote.origin.url 2>/dev/null \
        | sed -E 's#(git@|https://)github\.com[:/]##; s#\.git$##')}"
app_id="$(tr -d '[:space:]' < "$app_id_file")"
slug="$(tr -d '[:space:]' < "$slug_file")"

token="$(GH_APP_ID="$app_id" GH_APP_KEY="$key_file" \
        "$(dirname "$0")/gh-app-token.py" "$repo")"

export GH_TOKEN="$token"
export GIT_AUTHOR_NAME="$slug[bot]"
export GIT_AUTHOR_EMAIL="$app_id+$slug[bot]@users.noreply.github.com"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

if [ "$#" -eq 0 ]; then
  echo "已切换为 $GIT_AUTHOR_NAME（token 1 小时有效）" >&2
else
  "$@"
fi

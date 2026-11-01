#!/usr/bin/env bash
# 开新分支 / 新 PR 之前先扫：这些路径上是否已经有别的开放 PR 或分支在做同一件事。
#
# 用法：
#   scripts/pr-overlap-scan.sh <path> [path ...]
#     PATH 是仓库相对路径（文件或目录前缀），例：docs/review/2026-10-15-x.md specs/
#   环境：
#     PR_OVERLAP_REPO   owner/repo（缺省从当前仓库 git remote 推断）
#     SECRETS_DIR       GitHub App 凭据目录（配合 GH_BOT_ROLE，缺省 pr-gate）
#     GH_BOT_ROLE       机器人角色名，缺省 pr-gate
# 输出：命中即列出 PR 号/标题/分支/涉及路径，以及本地远端分支中改过这些路径的。
# 退出码：0 = 未发现重叠；10 = 发现重叠（需要人判断复用还是新建）；2 = 环境问题。
set -uo pipefail

[ "$#" -ge 1 ] || { echo "用法: pr-overlap-scan.sh <path> [path ...]" >&2; exit 2; }

REPO="${PR_OVERLAP_REPO:-}"
if [ -z "$REPO" ]; then
  url=$(git config --get remote.origin.url 2>/dev/null || true)
  REPO=$(printf '%s' "$url" | sed -E 's#(git@|https://)github\.com[:/]##; s#\.git$##')
fi
[ -n "$REPO" ] || { echo "无法推断 owner/repo，请设 PR_OVERLAP_REPO" >&2; exit 2; }

SECRETS_DIR="${SECRETS_DIR:-$HOME/.secrets}"
ROLE="${GH_BOT_ROLE:-pr-gate}"
SCRIPTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

ghrun() {
  if [ -x "$SCRIPTS_DIR/gh-bot.sh" ] && [ -r "$SECRETS_DIR/github/app-$ROLE.id" ]; then
    SECRETS_DIR="$SECRETS_DIR" bash "$SCRIPTS_DIR/gh-bot.sh" "$ROLE" gh "$@"
  else
    gh "$@"
  fi
}

echo "== 目标仓库 $REPO，检查路径：$*"
hits=0

echo "-- 开放 PR 中改到这些路径的："
prs=$(ghrun pr list --repo "$REPO" --state open --json number,title,headRefName,files 2>/dev/null) || {
  echo "  (gh 调用失败：检查凭据与网络)" >&2; exit 2; }
printf '%s' "$prs" | python3 -c '
import json,sys
want=sys.argv[1:]
prs=json.load(sys.stdin)
hit=0
for pr in prs:
    files=[f["path"] for f in (pr.get("files") or [])]
    matched=[p for p in files for w in want if p==w or p.startswith(w.rstrip("/")+"/")]
    if matched:
        hit=1
        print(f"  #{pr[\"number\"]} [{pr[\"headRefName\"]}] {pr[\"title\"][:60]}")
        for m in matched[:5]:
            print(f"      {m}")
sys.exit(0 if hit else 1)
' "$@" || hits=1

echo "-- 远端分支中改到这些路径的（相对默认分支）："
base=$(ghrun repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null || echo main)
git fetch --quiet origin "+refs/heads/*:refs/remotes/origin/*" 2>/dev/null || true
for br in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v '^origin/HEAD$' | sed 's#^origin/##'); do
  [ "$br" = "$base" ] && continue
  for path in "$@"; do
    n=$(git log --oneline "origin/$base..origin/$br" -- "$path" 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
      echo "  $br → $path（$n 个提交）"
      hits=1
      break
    fi
  done
done

echo
if [ "$hits" -eq 0 ]; then
  echo "结论：未发现重叠，可新建分支/PR。把这一行贴进卡片评论。"
  exit 0
fi
echo "结论：发现重叠。三选一并写进卡片评论："
echo "  1) 复用：在已有 PR/分支上追加 commit，不新建"
echo "  2) 重开：旧载体形态确实不可救时才重开，且必须写明旧 PR 的去留"
echo "  3) 合并：两个载体内容重叠时先定唯一载体，另一个立即关闭"
exit 10

#!/usr/bin/env bash
# 仓库 → 本机：按 profiles/ 的内容创建/更新 worker profile。
# 幂等：已存在的 profile 默认跳过（不覆盖 live 配置），--force 才覆盖 SOUL 与 config。
#
# 用法：
#   scripts/bootstrap.sh                     # 处理 impl-codex review
#   scripts/bootstrap.sh impl-codex          # 指定
#   scripts/bootstrap.sh --force impl-codex  # 覆盖写入
#
# 环境变量（占位符替换用，缺省值可直接跑）：
#   WORKER_MODEL / WORKER_PROVIDER / WORKER_BASE_URL
set -uo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; NC=$'\033[0m'
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
HERMES_BIN=${HERMES_BIN:-hermes}

WORKER_MODEL=${WORKER_MODEL:-deepseek-flash}
WORKER_PROVIDER=${WORKER_PROVIDER:-deepseek}
WORKER_BASE_URL=${WORKER_BASE_URL:-https://api.deepseek.com/v1}

FORCE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
PROFILES=()
if [ ${#ARGS[@]} -gt 0 ]; then PROFILES=("${ARGS[@]}"); fi
if [ ${#PROFILES[@]} -eq 0 ]; then
  mapfile -t PROFILES < <(find "$REPO_ROOT/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -v '^_shared$' | sort)
fi

command -v "$HERMES_BIN" >/dev/null 2>&1 || { echo "${RED}找不到 $HERMES_BIN${NC}"; exit 2; }

for p in "${PROFILES[@]}"; do
  src="$REPO_ROOT/profiles/$p"
  dst="$HERMES_HOME/profiles/$p"
  [ -d "$src" ] || { echo "${YEL}跳过 $p：仓库里没有 profiles/$p${NC}"; continue; }

  if [ ! -d "$dst" ]; then
    echo "→ 创建 profile $p"
    "$HERMES_BIN" profile create "$p" --no-alias --description "$(printf '%s' "$p") worker (kanban-codex-dispatch)" \
      || { echo "${RED}profile create 失败：$p${NC}"; continue; }
  else
    echo "→ profile $p 已存在（$dst）"
  fi

  # SOUL = 共享纪律 + 角色纪律。仓库是本节的唯一事实源，因此每次都写
  # （config.yaml 才是有状态的那一侧，默认不覆盖）。
  { cat "$REPO_ROOT/profiles/_shared/SOUL.md"; echo; echo "---"; echo; cat "$src/SOUL.md"; } > "$dst/SOUL.md"
  echo "   SOUL.md 写入（$(wc -c < "$dst/SOUL.md") 字节：共享 + 角色）"

  # config：占位符替换；已存在则写成 *.bootstrap.yaml 供人工比对
  if [ -f "$src/config.yaml" ]; then
    rendered=$(sed -e "s|<WORKER_MODEL>|$WORKER_MODEL|g" \
                   -e "s|<WORKER_PROVIDER>|$WORKER_PROVIDER|g" \
                   -e "s|<WORKER_BASE_URL>|$WORKER_BASE_URL|g" "$src/config.yaml")
    if [ "$FORCE" = 1 ] || [ ! -f "$dst/config.yaml" ]; then
      printf '%s\n' "$rendered" > "$dst/config.yaml"
      echo "   config.yaml 写入"
    else
      printf '%s\n' "$rendered" > "$dst/config.bootstrap.yaml"
      echo "   ${YEL}config.yaml 已存在${NC} → 渲染结果写到 config.bootstrap.yaml，人工比对后自行合并"
    fi
  fi

  # skills：仓库为单一事实源，符号链接进去
  mkdir -p "$dst/skills"
  for s in "$REPO_ROOT"/skills/*/; do
    [ -d "$s" ] || continue
    name=$(basename "$s")
    ln -sfn "$s" "$dst/skills/$name"
  done
  echo "   skills 链接：$(ls "$dst/skills" 2>/dev/null | tr '\n' ' ')"
done

cat <<EOF

${GRN}完成${NC}。接下来（编排者 = default profile，需人看得见的那一侧）：

  # 只让 worker profile 接卡，避免 dispatcher 把卡片派给 default（必须逗号分隔）
  hermes config set kanban.dispatch_profiles "impl-codex,review"

  # 冒烟
  hermes -p impl-codex chat -q '用一句话说明你的角色，然后退出'
  hermes -p review     chat -q '用一句话说明你的角色，然后退出'

  # 建第一张卡（示例，真实仓库路径与验收命令自己填）
  hermes kanban create "<标题>" --body-file templates/kanban-card.md --assignee impl-codex --workspace worktree:<repo-path>
EOF

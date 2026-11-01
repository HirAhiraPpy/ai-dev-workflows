#!/usr/bin/env bash
# profile 同步：仓库声明「应然」，本机承载「实然」。
#
#   scripts/sync.sh plan            只读。逐项对比 manifest 与本机，列出 drift；无 drift 退出 0
#   scripts/sync.sh apply [profile] 仓库 → 机器。SOUL 覆盖；config 只写 manifest 声明的键
#   scripts/sync.sh capture [profile] 机器 → 仓库。把受管键/SOUL 的偏离写成 *.capture.* 候选，
#                                    人工合并进 manifest / 角色 SOUL 后再走门禁提交
#
# 设计约束：
#   - 只写 manifest 里声明的键，其余键（Hermes 自写项、平台段落）一律不动。
#   - 秘密（.env）不参与同步；apply 会检查 profile 是否已有对应 provider key，缺了只告警。
#   - 一律通过 `hermes -p <profile> config get|set` 读写，不手改 profile 的 config.yaml。
set -uo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; NC=$'\033[0m'

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
HERMES_BIN=${HERMES_BIN:-hermes}
MANIFEST=${MANIFEST:-$REPO_ROOT/profiles/manifest.conf}
SHARED_SOUL=$REPO_ROOT/profiles/_shared/SOUL.md

WORKER_MODEL=${WORKER_MODEL:-deepseek-flash}
WORKER_PROVIDER=${WORKER_PROVIDER:-deepseek}
WORKER_BASE_URL=${WORKER_BASE_URL:-https://api.deepseek.com/v1}

command -v "$HERMES_BIN" >/dev/null 2>&1 || { echo "${RED}找不到 $HERMES_BIN${NC}"; exit 2; }
[ -f "$MANIFEST" ] || { echo "${RED}缺少清单：$MANIFEST${NC}"; exit 2; }

render() {  # 占位符替换
  sed -e "s|<WORKER_MODEL>|$WORKER_MODEL|g" \
      -e "s|<WORKER_PROVIDER>|$WORKER_PROVIDER|g" \
      -e "s|<WORKER_BASE_URL>|$WORKER_BASE_URL|g" <<< "$1"
}

sections() {  # 清单里的 profile 名
  grep -E '^\[[A-Za-z0-9_-]+\]$' "$MANIFEST" | tr -d '[]'
}

entries() {  # $1=profile → 输出 "key<TAB>value"
  awk -v want="$1" '
    /^\[[A-Za-z0-9_-]+\]$/ { cur = substr($0, 2, length($0) - 2); next }
    cur == want && /^[A-Za-z0-9_.]+[[:space:]]*=/ {
      line = $0
      eq = index(line, "=")
      k = substr(line, 1, eq - 1); v = substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      print k "\t" v
    }' "$MANIFEST"
}

expected_soul() {  # $1=role soul 相对路径 → 合并后的完整 SOUL
  { cat "$SHARED_SOUL"; echo; echo "---"; echo; cat "$REPO_ROOT/$1"; }
}

live_get() {  # $1=profile $2=dotted key
  local out
  out=$("$HERMES_BIN" -p "$1" config get "$2" 2>/dev/null | tail -1)
  [ "$out" = "null" ] && out=""
  printf '%s' "$out"
}

do_plan() {
  local drift=0 p entry key val exp live soul_rel tmp_live tmp_exp
  for p in "${PROFILES[@]}"; do
    echo "◆ $p"
    soul_rel=$(awk -v w="$p" '$0=="[" w "]"{f=1;next} /^\[/{f=0} f&&/^soul[[:space:]]*=/{sub(/^soul[[:space:]]*=[[:space:]]*/,"");print;exit}' "$MANIFEST")
    tmp_live=$(mktemp); tmp_exp=$(mktemp)
    if [ -n "$soul_rel" ]; then
      expected_soul "$soul_rel" > "$tmp_exp"
      if [ -f "$HERMES_HOME/profiles/$p/SOUL.md" ]; then
        cp "$HERMES_HOME/profiles/$p/SOUL.md" "$tmp_live"
        if ! diff -q "$tmp_live" "$tmp_exp" >/dev/null; then
          echo "  ${YEL}SOUL.md 与仓库不一致${NC}（apply 会覆盖；若本机改动是有意的，用 capture 收回）"
          diff -u "$tmp_live" "$tmp_exp" | sed -n '3,12p' | sed "s/^/    ${DIM}/;s/$/${NC}/"
          drift=$((drift+1))
        fi
      else
        echo "  ${YEL}本机缺 SOUL.md${NC}"; drift=$((drift+1))
      fi
    fi
    rm -f "$tmp_live" "$tmp_exp"

    while IFS=$'\t' read -r key val; do
      [ -n "$key" ] || continue
      case "$key" in
        soul) continue ;;
        config.*) ;;
        *) continue ;;
      esac
      exp=$(render "$val")
      live=$(live_get "$p" "${key#config.}")
      if [ "$live" != "$exp" ]; then
        echo "  ${YEL}${key#config.}${NC}: 本机='${live:-<未设置>}'  应然='$exp'"
        drift=$((drift+1))
      fi
    done < <(entries "$p")

    [ "$drift" -eq 0 ] && echo "  ${GRN}一致${NC}"
  done
  echo
  if [ "$drift" -eq 0 ]; then
    echo "${GRN}plan：无 drift${NC}"; return 0
  fi
  echo "${YEL}plan：${drift} 处 drift${NC}——apply 拉到应然，或 capture 把有意偏离收回仓库"
  return 1
}

do_apply() {
  local p soul_rel created key val exp live
  for p in "${PROFILES[@]}"; do
    echo "◆ $p"
    if [ ! -d "$HERMES_HOME/profiles/$p" ]; then
      echo "  → 创建 profile"
      "$HERMES_BIN" profile create "$p" --no-alias --description "$p worker (kanban-codex-dispatch)" >/dev/null \
        || { echo "  ${RED}profile create 失败${NC}"; continue; }
    fi
    soul_rel=$(awk -v w="$p" '$0=="[" w "]"{f=1;next} /^\[/{f=0} f&&/^soul[[:space:]]*=/{sub(/^soul[[:space:]]*=[[:space:]]*/,"");print;exit}' "$MANIFEST")
    if [ -n "$soul_rel" ] && [ -f "$REPO_ROOT/$soul_rel" ]; then
      expected_soul "$soul_rel" > "$HERMES_HOME/profiles/$p/SOUL.md"
      echo "  SOUL.md 写入（$(wc -c < "$HERMES_HOME/profiles/$p/SOUL.md") 字节）"
    fi
    while IFS=$'\t' read -r key val; do
      [ -n "$key" ] || continue
      case "$key" in config.*) ;; *) continue ;; esac
      exp=$(render "$val")
      live=$(live_get "$p" "${key#config.}")
      if [ "$live" = "$exp" ]; then
        continue
      fi
      if "$HERMES_BIN" -p "$p" config set "${key#config.}" "$exp" >/dev/null 2>&1; then
        echo "  ${key#config.} := $exp"
      else
        echo "  ${RED}设置失败：${key#config.}${NC}"
      fi
    done < <(entries "$p")

    # 技能：仓库 skill 链进 profile
    mkdir -p "$HERMES_HOME/profiles/$p/skills"
    for s in "$REPO_ROOT"/skills/*/; do
      [ -d "$s" ] || continue
      ln -sfn "$s" "$HERMES_HOME/profiles/$p/skills/$(basename "$s")"
    done

    # 秘密不参与同步，只提示
    local provider key_env
    provider=$(awk -v w="$p" '$0=="[" w "]"{f=1;next} /^\[/{f=0} f&&/^config\.model\.provider[[:space:]]*=/{sub(/.*=[[:space:]]*/,"");print;exit}' "$MANIFEST")
    provider=$(render "$provider")
    if [ -n "$provider" ]; then
      key_env="$(printf '%s' "$provider" | tr '[:lower:]-' '[:upper:]_')_API_KEY"
      if ! grep -q "^${key_env}=" "$HERMES_HOME/profiles/$p/.env" 2>/dev/null; then
        echo "  ${YEL}提醒${NC}：$p 的 .env 里没有 $key_env（profile 不继承主 profile 的 .env，需手工注入，勿入库）"
      fi
    fi
  done
  echo
  echo "${GRN}apply 完成${NC}。冒烟：$HERMES_BIN -p ${PROFILES[0]} chat -q '用一句话说明你的角色'"
}

do_capture() {
  local p soul_rel tmp_exp tmp_live role_part
  for p in "${PROFILES[@]}"; do
    echo "◆ $p"
    soul_rel=$(awk -v w="$p" '$0=="[" w "]"{f=1;next} /^\[/{f=0} f&&/^soul[[:space:]]*=/{sub(/^soul[[:space:]]*=[[:space:]]*/,"");print;exit}' "$MANIFEST")
    tmp_exp=$(mktemp); tmp_live=$(mktemp)
    if [ -n "$soul_rel" ] && [ -f "$HERMES_HOME/profiles/$p/SOUL.md" ]; then
      expected_soul "$soul_rel" > "$tmp_exp"
      cp "$HERMES_HOME/profiles/$p/SOUL.md" "$tmp_live"
      if diff -q "$tmp_live" "$tmp_exp" >/dev/null; then
        echo "  ${GRN}SOUL.md 一致${NC}"
      else
        # 只保留分隔线之后的角色部分，避免把共享段一起回传
        role_part="$REPO_ROOT/$soul_rel.capture.md"
        awk '/^---[[:space:]]*$/{seen=1;next} seen' "$tmp_live" > "$role_part"
        echo "  ${YEL}SOUL.md 有本机改动${NC} → 候选写入 $soul_rel.capture.md（人工比对后合并进 $soul_rel，再删候选）"
      fi
    fi
    rm -f "$tmp_exp" "$tmp_live"

    while IFS=$'\t' read -r key val; do
      [ -n "$key" ] || continue
      case "$key" in config.*) ;; *) continue ;; esac
      local exp live
      exp=$(render "$val")
      live=$(live_get "$p" "${key#config.}")
      if [ "$live" != "$exp" ]; then
        echo "  ${YEL}${key#config.}${NC}: 本机='${live:-<未设置>}' 应然='$exp'"
        echo "     若要正式化，把 manifest 的 ${key} 改成：$live"
      fi
    done < <(entries "$p")
  done
  echo
  echo "${YEL}capture 不改正式文件${NC}。合并后必须："
  echo "  scripts/check-secrets.sh && scripts/ai-desensitize-review.sh && git commit"
}

MODE=${1:-plan}
shift || true

# profile 选择：命令行指定 > 清单全部
PROFILES=()
if [ "$#" -gt 0 ]; then PROFILES=("$@"); else mapfile -t PROFILES < <(sections); fi
[ ${#PROFILES[@]} -gt 0 ] || { echo "${RED}清单里没有 profile${NC}"; exit 2; }

case "$MODE" in
  plan)    do_plan ;;
  apply)   do_apply ;;
  capture) do_capture ;;
  *) echo "用法: scripts/sync.sh {plan|apply|capture} [profile...]"; exit 2 ;;
esac

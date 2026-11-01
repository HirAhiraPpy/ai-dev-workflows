#!/usr/bin/env bash
# 兼容入口：等价于 scripts/sync.sh apply（保留旧名，避免历史文档里的命令失效）。
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
echo "提示：bootstrap.sh 已并入 sync.sh，等价于 \`scripts/sync.sh apply $*\`"
exec "$REPO_ROOT/scripts/sync.sh" apply "$@"

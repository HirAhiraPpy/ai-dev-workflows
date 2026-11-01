#!/usr/bin/env python3
"""扫 Kanban 板：卡片完成且其产出/评论里出现 PR 链接时，自动派一张 pr-gate 门禁卡。

设计要点：
- 事件语义用状态快照实现（不依赖 hook）：每轮读 DB，只看 status=done 的卡，
  按 (repo, PR, head_sha) 去重——同一个 head 只门禁一次，PR 有推送就再门禁一次。
- 幂等：state 文件记已派过的 head；同一 PR 已有活跃门禁卡时跳过。
- 静默：没有新门禁卡时不输出（cron 里成功即安静）。

用法：
    scripts/pr-gate-trigger.py --dry-run     # 只打印将要发生什么
    scripts/pr-gate-trigger.py               # 真派工
环境：
    KANBAN_HOME  【必填】看板的根目录（内含 boards/<board>/kanban.db 与 kanban.db）
    SECRETS_DIR  GitHub App 凭据目录（需 app-pr-gate.{id,pem,name}），默认 ~/.secrets
    PR_GATE_STATE 去重状态文件，默认 ~/.local/state/pr-gate-trigger.json
    HERMES_BIN   默认 hermes
    https_proxy / http_proxy  访问 GitHub 需要时设置
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import urllib.error
import urllib.request

PR_RE = re.compile(r"https://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)")
# 次级识别：正文只写「PR #36 / pull/36」时，用卡片 workspace 的 git remote 补出 owner/repo
PR_NUM_RE = re.compile(r"(?:PR\s*#|pull/)(\d+)")
GATE_ASSIGNEE = "pr-gate"
LOOKBACK_DAYS = 7
HERMES = os.environ.get("HERMES_BIN", "hermes")
KANBAN_HOME = os.path.expanduser(os.environ.get("KANBAN_HOME", ""))
STATE_PATH = os.path.expanduser(os.environ.get(
    "PR_GATE_STATE", "~/.local/state/pr-gate-trigger.json"))
SECRETS_DIR = os.path.expanduser(os.environ.get("SECRETS_DIR", "~/.secrets"))
# gh-bot.sh 与本脚本同目录，指令文本里用它所在的绝对路径
GHBOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gh-bot.sh")
ACTIVE = ("triage", "todo", "ready", "running", "review")


def load_state() -> dict:
    try:
        with open(STATE_PATH, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=1, sort_keys=True)
    os.replace(tmp, STATE_PATH)


def board_dbs() -> list[tuple[str, str]]:
    out = []
    for path in sorted(glob.glob(os.path.join(KANBAN_HOME, "boards", "*", "kanban.db"))):
        out.append((os.path.basename(os.path.dirname(path)), path))
    default_db = os.path.join(KANBAN_HOME, "kanban.db")
    if os.path.exists(default_db):
        out.append(("default", default_db))
    return out


def done_tasks(db: str) -> list[dict]:
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    # completed_at 是 epoch 秒（不是 datetime 字符串）
    limit = f"strftime('%s','now','-{LOOKBACK_DAYS} days')"
    rows = conn.execute(
        f"SELECT id, title, assignee, status, completed_at, workspace_path, result "
        f"FROM tasks WHERE status='done' AND completed_at > {limit}").fetchall()
    tasks = []
    for row in rows:
        task = dict(row)
        comments = conn.execute(
            "SELECT author, body FROM task_comments WHERE task_id=? ORDER BY created_at",
            (task["id"],)).fetchall()
        task["text"] = "\n".join([task.get("result") or ""] + [c["body"] for c in comments])
        tasks.append(task)
    conn.close()
    return tasks


def active_gate_for(board_db: str, repo: str, pr: int) -> bool:
    conn = sqlite3.connect(f"file:{board_db}?mode=ro", uri=True)
    marks = ",".join("?" * len(ACTIVE))
    rows = conn.execute(
        f"SELECT id, title FROM tasks WHERE status IN ({marks})", ACTIVE).fetchall()
    conn.close()
    needle = f"{repo}#{pr}"
    return any(needle in (title or "") for _, title in rows)


def gh_head_sha(repo: str, pr: int) -> str | None:
    """用 pr-gate bot 身份读 PR head sha（只读）。失败返回 None。"""
    app_id = os.path.join(SECRETS_DIR, "github", f"app-{GATE_ASSIGNEE}.id")
    app_key = os.path.join(SECRETS_DIR, "github", f"app-{GATE_ASSIGNEE}.pem")
    token_script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gh-app-token.py")
    if not (os.path.exists(app_id) and os.path.exists(app_key)):
        return None
    try:
        token = subprocess.run(
            [sys.executable, token_script, repo],
            capture_output=True, text=True, timeout=60,
            env={**os.environ,
                 "GH_APP_ID": open(app_id, encoding="utf-8").read().strip(),
                 "GH_APP_KEY": app_key}).stdout.strip()
    except Exception:
        return None
    if not token:
        return None
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/pulls/{pr}")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["head"]["sha"]
    except (urllib.error.URLError, KeyError, json.JSONDecodeError):
        return None


def repo_root(workspace_path: str | None, repo: str) -> str:
    if workspace_path:
        marker = "/.worktrees/"
        if marker in workspace_path:
            return workspace_path.split(marker)[0]
        return workspace_path
    return os.path.expanduser(f"~/workdir/personal/{repo.split('/')[-1]}")


def remote_slug(path: str | None) -> str | None:
    """从仓库 git remote 推断 owner/repo。"""
    if not path:
        return None
    try:
        url = subprocess.run(["git", "-C", path, "config", "--get", "remote.origin.url"],
                             capture_output=True, text=True, timeout=15).stdout.strip()
    except Exception:
        return None
    m = re.search(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?$", url)
    return f"{m.group(1)}/{m.group(2)}" if m else None


GATE_BODY = """## 目标

对 `{repo}#{pr}`（{url}）做一次 PR 质量门禁初筛，结论写回 PR 与卡片。

## 身份与工具

所有 gh 命令走包装器（token 不常驻）：

```bash
SECRETS_DIR={secrets} bash {ghbot} {assignee} gh pr view {pr} --repo {repo} --json title,body,additions,deletions,changedFiles
SECRETS_DIR={secrets} bash {ghbot} {assignee} gh pr diff {pr} --repo {repo} --patch
```

## 要做的

1. 按三条尺子（代码整洁 → 架构 → 文档可读）给一次初筛，只看相对上一轮门禁的增量时不要重放旧结论。
2. 把评论正文发到 PR：`gh pr comment {pr} --repo {repo} --body-file <文件>`。
3. 结论三选一：`APPROVE` / `REQUEST_CHANGES`（问题 → `文件:行` → 具体改法）/ `ESCALATE`（口径与取舍，附选项与代价）。
4. PR 评论最后一行写 `[gate] verdict=<...> issues=<n>`；卡片评论写一行结论 + PR 链接。
5. 若不通过且需要人改，**不要自己改代码**：在卡片评论列出「给执行者的改动清单」，由编排者派工。

## 不做什么

- 不 push、不改文件、不 merge、不删分支、不做能自动合并的 approve
- 不重复 CI 已说的失败细节（引用链接即可）
- 一次最多 7 条，超过说明该拆 PR

## 验收

- PR 里出现本次评论，且评论带 verdict 行
- 卡片评论有结论与 PR 链接

## 门禁轮次

head sha = `{sha}`（同一 sha 已门禁过则本卡不该存在）
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--verbose", action="store_true", help="打印跳过原因（cron 里保持安静）")
    ap.add_argument("--max", type=int, default=2,
                    help="单轮最多派几张门禁卡（防止一次性把队列塞爆，默认 2）")
    args = ap.parse_args()
    if not KANBAN_HOME:
        sys.exit("需要 KANBAN_HOME（看板根目录）")
    state = load_state()
    created = 0
    for board, db in board_dbs():
        if created >= args.max:
            break
        for task in done_tasks(db):
            if created >= args.max:
                break
            if task.get("assignee") == GATE_ASSIGNEE:
                continue
            # 门禁卡自身不触发门禁（assignee 之外的二道保险：标题前缀）
            if (task.get("title") or "").startswith("【PR门禁】"):
                continue
            seen = set()
            candidates = [(o, n, int(p)) for o, n, p in PR_RE.findall(task["text"])]
            if not candidates:
                slug = remote_slug(repo_root(task.get("workspace_path"), ""))
                if slug:
                    owner, name = slug.split("/", 1)
                    candidates = [(owner, name, int(p)) for p in PR_NUM_RE.findall(task["text"])]
            for owner, name, num in candidates:
                repo, pr = f"{owner}/{name}", num
                key = f"{repo}#{pr}"
                if key in seen:
                    continue
                seen.add(key)
                sha = gh_head_sha(repo, pr)
                if not sha:
                    if args.verbose:
                        print(f"[skip] {board} {key}: 读不到 head sha（凭据/网络）")
                    continue
                if state.get(key, {}).get("sha") == sha:
                    continue
                if active_gate_for(db, repo, pr):
                    continue
                title = f"【PR门禁】{repo}#{pr}"
                body = GATE_BODY.format(
                    repo=repo, pr=pr, url=f"https://github.com/{repo}/pull/{pr}",
                    ghbot=GHBOT, secrets=SECRETS_DIR, assignee=GATE_ASSIGNEE, sha=sha)
                if args.dry_run:
                    print(f"[dry-run] 会派 {board} {key} @{sha[:8]}")
                    continue
                cmd = [HERMES, "kanban", "--board", board, "create", title,
                       "--body", body, "--assignee", GATE_ASSIGNEE,
                       "--workspace", f"dir:{repo_root(task.get('workspace_path'), repo)}"]
                proc = subprocess.run(cmd, capture_output=True, text=True)
                if proc.returncode != 0:
                    print(f"[fail] {board} {key}: {proc.stderr.strip()[:160]}")
                    continue
                card_m = re.search(r"(t_[0-9a-f]+)", proc.stdout)
                if not card_m:
                    print(f"[fail] {board} {key}: 建卡输出无法解析: {proc.stdout.strip()[:160]}")
                    continue
                card = card_m.group(1)
                state[key] = {"sha": sha, "card": card, "board": board}
                save_state(state)
                created += 1
                print(f"[gate] {board} {key} → {card} @{sha[:8]}")
    if not created and not args.dry_run:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())

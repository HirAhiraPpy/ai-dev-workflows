#!/usr/bin/env python3
"""issue-driven-dev worker (MVP v0.1)
轮询 codex-task issue → codex exec 实现 → 推分支开 PR。

依赖: gh CLI + codex CLI + git。串行执行，一次一个任务。
"""
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO_DIR = Path(os.environ.get("WORKER_REPO_DIR", str(Path.home() / "repos" / "binance-collector")))
WORKFLOWS_DIR = "workflows"          # submodule 路径（公共仓库）
LABEL = "codex-task"
MAX_RETRY = 2
POLL_INTERVAL = 5 * 60

def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)

def log(msg):
    print(f"[worker {time.strftime('%H:%M:%S')}] {msg}", flush=True)

def get_issues():
    r = sh(f"gh issue list --repo HirAhiraPpy/binance-collector --label {LABEL} --state open --json number,title --limit 10")
    if r.returncode != 0:
        log(f"gh issue list failed: {r.stderr.strip()}")
        return []
    import json
    return json.loads(r.stdout)

def issue_body(num):
    r = sh(f"gh issue view {num} --repo HirAhiraPpy/binance-collector --json body,title --jq '.title + \"\\n\\n\" + .body'")
    return r.stdout if r.returncode == 0 else ""

def run_codex(num, body):
    prompt = (
        f"实现 GitHub issue #{num}。任务要求（含验收标准）：\n\n{body}\n\n"
        "遵循项目根 AGENTS.md 与 workflows/agents/project-default.md 的规范。"
        "完成后运行测试验证，输出改动摘要。"
    )
    r = sh(f"codex exec -s danger-full-access {prompt!r}", timeout=1800)
    return r.returncode == 0

def main():
    for attempt in range(MAX_RETRY + 1):
        issues = get_issues()
        if not issues:
            time.sleep(POLL_INTERVAL)
            continue
        num = issues[0]["number"]
        log(f"processing issue #{num}: {issues[0]['title']} (attempt {attempt+1})")
        # 检出最新 main + 更新 submodule
        sh(f"git -C {REPO_DIR} fetch origin && git -C {REPO_DIR} checkout -q origin/main")
        sh(f"git -C {REPO_DIR} submodule update --remote {WORKFLOWS_DIR}")
        body = issue_body(num)
        ok = run_codex(num, body)
        if ok:
            branch = f"feature/{num}-codex"
            sh(f"git -C {REPO_DIR} checkout -q -b {branch}")
            sh(f"git -C {REPO_DIR} add -A && git -C {REPO_DIR} commit -qm 'feat: implement #{num} (codex)'")
            push = sh(f"git -C {REPO_DIR} push -u origin {branch}")
            if push.returncode == 0:
                sh(f"gh pr create --repo HirAhiraPpy/binance-collector --head {branch} --title 'feat: #{num} (codex)' --body 'Closes #{num}\n\n自动生成 PR，待人工 review。'")
                sh(f"gh issue edit {num} --repo HirAhiraPpy/binance-collector --remove-label {LABEL}")
                log(f"issue #{num} done -> PR created")
            else:
                log(f"push failed: {push.stderr.strip()}")
            break
        else:
            log(f"issue #{num} attempt {attempt+1} failed")
            if attempt == MAX_RETRY:
                sh(f"gh issue edit {num} --repo HirAhiraPpy/binance-collector --add-label needs-help")
                sh(f"gh issue comment {num} --repo HirAhiraPpy/binance-collector --body 'codex worker 重试 {MAX_RETRY} 次失败，升级人工处理。'")
    if not issues:
        sys.exit(0)

if __name__ == "__main__":
    main()

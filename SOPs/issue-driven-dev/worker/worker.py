#!/usr/bin/env python3
"""issue-driven-dev worker (MVP v0.2)
轮询 codex-task issue → openai SDK 驱动 agent 实现 → 推分支开 PR。

v0.2 变更（2026-08-06）：
- codex CLI 调用 → openai 官方 SDK（Responses API agent loop：shell + apply_patch 工具）
- git 前置操作全部检查返回码，失败即中止
- 启动前 reset --hard + clean 清理工作区，杜绝脏 checkout
- GIT_ASKPASS 从环境变量注入凭证（不落盘、不依赖挂载）
- flock 防并发（cron 5min 与长任务冲突）
- push 失败重试 + 空 diff 检测

依赖: gh CLI + openai>=1.60 + git + patch。串行执行，一次一个任务。
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from openai import OpenAI

REPO_DIR = Path(os.environ.get("WORKER_REPO_DIR", str(Path.home() / "repos" / "binance-collector")))
WORKFLOWS_DIR = "workflows"          # submodule 路径（公共仓库）
LABEL = "codex-task"
MAX_RETRY = 2
POLL_INTERVAL = 5 * 60
MAX_STEPS = int(os.environ.get("WORKER_MAX_STEPS", "30"))
MODEL = os.environ.get("WORKER_MODEL", "deepseek-v4-flash")
BASE_URL = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com/v1")
LOCK_FILE = Path(tempfile.gettempdir()) / "issue-driven-worker.lock"

SYSTEM_PROMPT = """你是资深软件工程师，通过工具在 /workspace 完成代码任务。规则：
1. 先探索仓库（ls / git status / 读关键文件），理解现有代码再动手。
2. 用 shell 工具执行命令；修改代码优先用 apply_patch 工具（unified diff，路径相对工作区根）。
3. 每处修改后自行验证：语法检查、运行相关测试。
4. 严格遵守项目根 AGENTS.md 与 workflows/agents/project-default.md 的规范。
5. 全部完成时输出简洁总结：改了哪些文件、验证方式与结果。不要输出无关内容。"""

TOOLS = [
    {
        "type": "function",
        "name": "shell",
        "description": "在 /workspace 执行 shell 命令，返回 stdout/stderr 与退出码。用于探索仓库、运行测试、查看文件。",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "要执行的 shell 命令"}
            },
            "required": ["command"],
            "additionalProperties": False,
        },
    },
    {
        "type": "function",
        "name": "apply_patch",
        "description": "应用 unified diff 补丁修改文件。补丁路径相对工作区根（a/ b/ 前缀）。只改代码，不做 git 操作。",
        "parameters": {
            "type": "object",
            "properties": {
                "patch": {"type": "string", "description": "unified diff 文本"}
            },
            "required": ["patch"],
            "additionalProperties": False,
        },
    },
]


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, **kw)


def log(msg):
    print(f"[worker {time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------- 凭证 ----------

def setup_git_auth():
    """GIT_ASKPASS：git HTTPS 认证从 GH_TOKEN 环境变量读取，不落盘。"""
    token = os.environ.get("GH_TOKEN")
    if not token:
        log("WARN: GH_TOKEN 未设置，git push 将无法认证")
        return
    script = Path(tempfile.gettempdir()) / "git-askpass.sh"
    script.write_text(
        "#!/bin/sh\n"
        "case \"$1\" in\n"
        "  *[Uu]sername*) echo \"x-access-token\";;\n"
        "  *[Pp]assword*) printf '%s' \"$GH_TOKEN\";;\n"
        "  *) exit 1;;\n"
        "esac\n"
    )
    script.chmod(0o700)
    os.environ["GIT_ASKPASS"] = str(script)
    os.environ["GIT_TERMINAL_PROMPT"] = "0"


# ---------- git 前置 ----------

def git_prepare():
    """清理工作区 + 检出最新 main + 更新 submodule。任一步失败返回 False。"""
    steps = [
        f"git -C {REPO_DIR} reset --hard -q",
        f"git -C {REPO_DIR} clean -fdq",
        f"git -C {REPO_DIR} fetch origin --prune -q",
        f"git -C {REPO_DIR} checkout -q -B main origin/main",
        f"git -C {REPO_DIR} submodule sync -q",
        f"git -C {REPO_DIR} submodule update --init --recursive --remote {WORKFLOWS_DIR}",
    ]
    for step in steps:
        r = sh(step)
        if r.returncode != 0:
            log(f"git 前置失败: {step}\n{r.stderr.strip()}")
            return False
    return True


# ---------- openai SDK agent loop ----------

def exec_tool(name, args_json):
    """执行 agent 请求的工具调用，返回给模型的文本结果（JSON）。"""
    try:
        args = json.loads(args_json) if args_json else {}
    except json.JSONDecodeError:
        return json.dumps({"error": "invalid arguments json"})
    if name == "shell":
        cmd = args.get("command", "")
        if not cmd:
            return json.dumps({"error": "empty command"})
        try:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                               cwd=REPO_DIR, timeout=180)
            out = (r.stdout or "") + (("\n[stderr]\n" + r.stderr) if r.stderr else "")
            return json.dumps({"exit_code": r.returncode, "output": out[-8000:]}, ensure_ascii=False)
        except subprocess.TimeoutExpired:
            return json.dumps({"exit_code": 124, "output": "timeout after 180s"})
        except Exception as e:
            return json.dumps({"exit_code": 1, "output": f"exec error: {e}"})
    if name == "apply_patch":
        patch_text = args.get("patch", "")
        if not patch_text:
            return json.dumps({"error": "empty patch"})
        try:
            r = subprocess.run(["patch", "-p1", "--fuzz=3"], input=patch_text,
                               capture_output=True, text=True, cwd=REPO_DIR, timeout=60)
            out = (r.stdout or "") + (r.stderr or "")
            return json.dumps({"exit_code": r.returncode, "output": out[-4000:]}, ensure_ascii=False)
        except FileNotFoundError:
            # 容器无 patch 命令时 fallback git apply
            r = subprocess.run(["git", "apply", "-"], input=patch_text,
                               capture_output=True, text=True, cwd=REPO_DIR, timeout=60)
            out = (r.stdout or "") + (r.stderr or "")
            return json.dumps({"exit_code": r.returncode, "output": out[-4000:]}, ensure_ascii=False)
        except Exception as e:
            return json.dumps({"exit_code": 1, "output": f"apply_patch error: {e}"})
    return json.dumps({"error": f"unknown tool {name}"})


def run_agent(num, body):
    """openai SDK 驱动 agent 实现 issue。返回 (ok, summary)。"""
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        log("DEEPSEEK_API_KEY 未设置")
        return False, ""
    client = OpenAI(api_key=api_key, base_url=BASE_URL, timeout=600, max_retries=2)
    prompt = (
        f"实现 GitHub issue #{num}。任务要求（含验收标准）：\n\n{body}\n\n"
        "遵循项目根 AGENTS.md 与 workflows/agents/project-default.md 的规范。"
        "完成后运行测试验证，最后输出改动摘要。"
    )
    turn_input = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]
    summary = ""
    for step in range(MAX_STEPS):
        try:
            resp = client.responses.create(model=MODEL, input=turn_input, tools=TOOLS)
        except Exception as e:
            log(f"API 调用失败 (step {step+1}): {e}")
            return False, summary
        outputs = list(resp.output)
        turn_input = turn_input + outputs
        has_call = False
        for o in outputs:
            otype = getattr(o, "type", None)
            if otype == "function_call":
                has_call = True
                name = getattr(o, "name", "?")
                args = getattr(o, "arguments", "") or ""
                log(f"  step {step+1}: tool={name}")
                result = exec_tool(name, args)
                turn_input.append({"type": "function_call_output",
                                   "call_id": o.call_id, "output": result})
            elif otype == "message":
                for c in (getattr(o, "content", None) or []):
                    if getattr(c, "type", None) == "output_text":
                        summary = c.text
        if not has_call:
            log(f"agent 完成于 step {step+1}")
            return True, summary
    log(f"达到 MAX_STEPS={MAX_STEPS}，视为失败")
    return False, summary


# ---------- GitHub 交互 ----------

def get_issues():
    r = sh(f"gh issue list --repo HirAhiraPpy/binance-collector --label {LABEL} --state open --json number,title --limit 10")
    if r.returncode != 0:
        log(f"gh issue list failed: {r.stderr.strip()}")
        return []
    return json.loads(r.stdout)


def issue_body(num):
    r = sh(f"gh issue view {num} --repo HirAhiraPpy/binance-collector --json body,title --jq '.title + \"\\n\\n\" + .body'")
    return r.stdout if r.returncode == 0 else ""


# ---------- 主流程 ----------

def main():
    setup_git_auth()
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        log("另一个 worker 实例在跑，退出")
        return
    try:
        for attempt in range(MAX_RETRY + 1):
            issues = get_issues()
            if not issues:
                time.sleep(POLL_INTERVAL)
                continue
            num = issues[0]["number"]
            log(f"processing issue #{num}: {issues[0]['title']} (attempt {attempt+1})")
            if not git_prepare():
                log("git 前置失败，本次跳过（下轮重试）")
                time.sleep(60)
                continue
            body = issue_body(num)
            ok, summary = run_agent(num, body)
            if ok:
                branch = f"feature/{num}-codex"
                sh(f"git -C {REPO_DIR} checkout -q -B {branch}")
                add = sh(f"git -C {REPO_DIR} add -A")
                if add.returncode != 0:
                    log(f"git add failed: {add.stderr.strip()}")
                    continue
                status = sh(f"git -C {REPO_DIR} status --porcelain")
                if not status.stdout.strip():
                    log("agent 无改动，跳过 PR")
                    sh(f"gh issue comment {num} --repo HirAhiraPpy/binance-collector --body 'agent 完成但未产生代码改动。'")
                    sh(f"gh issue edit {num} --repo HirAhiraPpy/binance-collector --remove-label {LABEL}")
                    break
                commit = sh(f"git -C {REPO_DIR} commit -qm 'feat: implement #{num} (agent)'")
                if commit.returncode != 0:
                    log(f"commit failed: {commit.stderr.strip()}")
                    continue
                pushed = False
                for ptry in range(3):
                    push = sh(f"git -C {REPO_DIR} push -u -f origin {branch}")
                    if push.returncode == 0:
                        pushed = True
                        break
                    log(f"push 失败(第{ptry+1}次): {push.stderr.strip()}")
                    time.sleep(5)
                if not pushed:
                    continue
                pr = sh(f"gh pr create --repo HirAhiraPpy/binance-collector --head {branch} --title 'feat: #{num} (agent)' --body 'Closes #{num}\n\n自动生成 PR，待人工 review。'")
                if pr.returncode == 0:
                    sh(f"gh issue edit {num} --repo HirAhiraPpy/binance-collector --remove-label {LABEL}")
                    if summary:
                        safe = summary.replace("'", "'\\''")[:2000]
                        sh(f"gh issue comment {num} --repo HirAhiraPpy/binance-collector --body '{safe}'")
                    log(f"issue #{num} done -> PR created")
                else:
                    log(f"pr create failed: {pr.stderr.strip()}")
                break
            else:
                log(f"issue #{num} attempt {attempt+1} failed")
                if attempt == MAX_RETRY:
                    sh(f"gh issue edit {num} --repo HirAhiraPpy/binance-collector --add-label needs-help")
                    sh(f"gh issue comment {num} --repo HirAhiraPpy/binance-collector --body 'agent worker 重试 {MAX_RETRY} 次失败，升级人工处理。'")
    finally:
        try:
            fcntl.flock(lock, fcntl.LOCK_UN)
        except OSError:
            pass
        lock.close()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""用 GitHub App 凭据换取 installation access token（有效期 1 小时，打印到 stdout）。

用法：
    GH_APP_ID=<app-id> GH_APP_KEY=<SECRETS_DIR>/github/app-<role>.pem \\
        scripts/gh-app-token.py owner/repo

环境变量：
    GH_APP_ID               App 的 ID（GitHub App 设置页可见）
    GH_APP_KEY              App 私钥 .pem 的路径
    GH_APP_INSTALLATION_ID  可选：已知道 installation id 时跳过查询
    GITHUB_API              可选，默认 https://api.github.com

典型用法（一次性导出机器人身份）：
    eval "$(scripts/gh-app-token.py owner/repo --export)"

依赖：只用到 openssl 命令行与 Python 标准库。
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("GITHUB_API", "https://api.github.com")


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def make_jwt(app_id: str, key_path: str) -> str:
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {"iat": now - 60, "exp": now + 540, "iss": int(app_id)}
    signing_input = f"{b64url(json.dumps(header, separators=(',', ':')).encode())}." \
                    f"{b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.path.expanduser(key_path)],
        input=signing_input.encode(), capture_output=True,
    )
    if proc.returncode != 0:
        sys.exit(f"openssl 签名失败: {proc.stderr.decode()[:200]}")
    return f"{signing_input}.{b64url(proc.stdout)}"


def api(url: str, jwt: str | None = None, method: str = "GET", token: str | None = None):
    req = urllib.request.Request(url, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if jwt:
        req.add_header("Authorization", f"Bearer {jwt}")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        sys.exit(f"GitHub API {exc.code} {url}: {exc.read().decode()[:300]}")


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    export = "--export" in sys.argv
    repo = args[0] if args else os.environ.get("GH_BOT_REPO", "")
    app_id = os.environ.get("GH_APP_ID")
    key_path = os.environ.get("GH_APP_KEY")
    if not (app_id and key_path):
        sys.exit("缺少 GH_APP_ID / GH_APP_KEY")
    jwt = make_jwt(app_id, key_path)

    inst_id = os.environ.get("GH_APP_INSTALLATION_ID")
    if not inst_id:
        if not repo:
            sys.exit("需要 owner/repo 或 GH_APP_INSTALLATION_ID")
        inst_id = api(f"{API}/repos/{repo}/installation", jwt=jwt)["id"]

    token = api(f"{API}/app/installations/{inst_id}/access_tokens",
                jwt=jwt, method="POST")["token"]
    if export:
        print(f'export GH_TOKEN="{token}"; export GH_BOT_INSTALLATION_ID="{inst_id}"')
    else:
        print(token)


if __name__ == "__main__":
    main()

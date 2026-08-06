# Lesson 002: worker v0.2 —— openai SDK agent loop + 容器化部署踩坑

- 日期: 2026-08-06
- 来源: EC2 端到端测试（issue #6 → PR #7，27 steps 全通）
- 状态: 已采纳

## 背景

v0.1 worker 用 subprocess 调 codex CLI。用户指定改为 **openai 官方 SDK 直接驱动 agent**
（不再依赖 codex CLI 二进制），其余按加固思路走。端到端测试暴露 4 个系统性坑。

## 架构变更

| 项 | v0.1 | v0.2 |
|---|---|---|
| 模型调用 | `codex exec` subprocess | `client.responses.create()` agent loop |
| 工具集 | codex 内置 | 自实现 `shell` + `apply_patch`（JSON schema） |
| 凭证 | run-worker.sh 注入 http.extraheader | worker.py 内 GIT_ASKPASS（读 GH_TOKEN env） |
| git 前置 | 不检查返回码 | `git_prepare()` 逐步检查，失败即中止 |
| 并发 | 无防护 | flock 文件锁 |
| 空 diff | 无检测 | status --porcelain 检查 |

agent loop 核心：`turn_input = [system, user] + response.output + function_call_output`，
直到模型不再产生 function_call（或 MAX_STEPS=30 上限）。DeepSeek 原生支持
Responses API（/v1/responses），openai SDK 2.33 可直接驱动。

## 踩坑清单（按杀伤力排序）

### 坑 1：submodule "鸡生蛋" —— 加载旧版 worker.py（最隐蔽）

worker.py 从 submodule `workflows/` 加载，而 submodule 更新逻辑在 worker 内部。
**Python 启动时即编译整个脚本**，所以 worker 内更新 submodule 永远来不及——
实际跑的是磁盘上的旧版字节码。

表象：日志无 step 输出、push 报 `could not read Username`（v0.1 依赖 http.extraheader
而脚本已不再注入）。

修复：**run-worker.sh 在启动 worker 前先 `git submodule update --init --remote workflows`**，
并用 `grep -c "openai SDK" worker.py` 断言版本。

### 坑 2：GIT_ASKPASS 只对 HTTPS 生效

GIT_ASKPASS 是 git 的 HTTPS 认证回调，**SSH 协议不走 askpass**。
若 remote 是 `git@github.com`，容器内 push 会因无 SSH key 失败。

约束：**remote 必须保持 HTTPS**。EC2 宿主用 credential.helper=store + .git-credentials
（PAT 落盘，用户自有机器）；容器内靠运行时 `-e GH_TOKEN` 注入，worker.py 生成
askpass 脚本（/tmp，chmod 700）从 env 读 token，不落盘。

### 坑 3：容器 root 文件权限污染宿主仓库

容器内以 root 操作挂载的仓库 → `.git/objects`、untracked 文件属主变 root →
宿主 `git fetch/checkout` 报 `insufficient permission` / `unable to unlink`。

修复：run-worker.sh 在 docker run 之后 `sudo chown -R ubuntu:ubuntu $REPO`（保留退出码）。

### 坑 4：EC2 公网 IP 漂移 + 网段被墙

实例每次 stop/start 换公网 IP，且部分东京网段（3.113.x）被 GFW 全阻。
解决：**绑定弹性 IP**（EIP 后不再漂移）；连接前 `aws describe-instances` 查当前 IP
并测 22 端口。当前 EIP：13.114.162.82（13.112-13.115 网段可达）。

### 坑 5：慢网络 push 断连

3Mbps 上行 + git 默认 1MB http buffer → `unexpected disconnect while reading sideband`。
修复：`git config http.postBuffer 52428800`（50MB）。

### 坑 6：DeepSeek 一轮多工具调用（非 bug）

DeepSeek 一轮可能返回多个 function_call（并行工具调用），日志同 step 号重复出现是
正常现象——循环内遍历 outputs 逐个执行，全部回灌。

## 验证结果

- issue #6（get_klines）→ agent 27 steps（shell 探索 + apply_patch 改码）→ PR #7
- PR 内容：binance_testnet.py +39 + tests/test_klines.py +101（agent 自写测试）
- 合并后 main 真实 API 验证：klines 3 条字段完整、非法 interval/超限 limit 抛 ValueError
- 旧 PR #3/#5（codex 独立产物）一并合并，三个 issue 自动关闭

## 硬约束

1. git remote 必须 HTTPS（GIT_ASKPASS 依赖）
2. worker 启动前必须更新 submodule（run-worker.sh 负责，勿移除）
3. 容器运行后必须 chown 归还仓库权限
4. 凭证一律运行时 env 注入（GH_TOKEN / DEEPSEEK_API_KEY），镜像零密钥
5. worker.py 从 submodule 加载 → 改 worker.py 后先 push ai-dev-workflows 再跑

## 影响

- SOP.md 更新至 0.2.0（流程 + 凭证说明）
- run-worker.sh v7.2 入库（SOPs/issue-driven-dev/worker/）
- 镜像 binance-worker:latest 含 openai SDK + patch（codex CLI 兼容保留）

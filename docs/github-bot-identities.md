# Agent 的 GitHub 身份

每个提交代码、在 PR 里发言的 agent 用**各自的** bot 身份，而不是全部复用同一个人账号。
目的：PR 里一眼看出「谁写的代码、谁在审、谁的话是结论」，以及能按身份收回权限。

## 两条路线

| | GitHub App（推荐） | 机器账号 + fine-grained PAT |
|---|---|---|
| PR 里的显示 | `<slug>[bot]`，带 bot 标记 | 普通用户名，看不出是机器人 |
| 凭据 | 1 小时 installation token，自动过期 | 长期 token，需轮换 |
| 权限 | 按仓库、按权限项精确授予 | 按仓库授予，粒度略粗 |
| 建造成本 | 网页建 App（一次点击），无需邮箱/验证码 | 每个身份要一个账号 + 邮箱 + 验证 |
| 创建方式 | 只能网页创建（GitHub 无 API 建 App） | 只能网页创建 |

结论：走 GitHub App，一个角色一个 App。

## 建造步骤（每个角色重复一次）

1. 打开 `https://github.com/settings/apps/new`（个人账号）或组织的 Settings → Developer settings → GitHub Apps → New。
2. **Name** 用角色名，例：`<role>`、`<role>`。这个名字决定 PR 里显示的 `<role>[bot]`。
3. **Webhook**：取消 Active（本流程不需要回调）。
4. **Repository permissions**：
   - Contents: Read and write（要 push commit 的角色）；只审不写的角色给 Read
   - Pull requests: Read and write（评论 / review）
   - Issues: Read and write（用 issue 承载任务时需要）
   - Metadata: Read（自动带上）
5. 创建后记下 **App ID**，在页面底部 **Generate a private key** 下载 `.pem`。
6. **Install App** → 只装到需要的仓库（不要 All repositories）。
7. 本机落盘（600，不入库）：
   ```
   <SECRETS_DIR>/github/app-<role>.id      # App ID
   <SECRETS_DIR>/github/app-<role>.pem     # 私钥
   <SECRETS_DIR>/github/app-<role>.slug    # App slug（= name 的小写形式）
   ```

## 使用

```bash
source scripts/gh-bot.sh pr-gate                 # 之后 gh / git 都是该 bot 身份
scripts/gh-bot.sh pr-gate gh pr comment 36 --body-file body.md
scripts/gh-bot.sh pr-gate git commit -m "..."    # 提交者 = <slug>[bot]
```

脚本做的事：用 App ID + 私钥签 JWT → 换 installation token（1h）→ 导出 `GH_TOKEN`
与 `GIT_AUTHOR_*` / `GIT_COMMITTER_*`。commit 的归属靠邮箱
`<app-id>+<slug>[bot]@users.noreply.github.com` 落定，push 用的是 installation token。

## 注意

- installation token 1 小时过期。长任务在开工时换一次不够，重试推送前重新 `source` 一次。
- App 不能改自己没被授予权限的东西；一个角色只给它真正需要的权限，撤销时直接卸载安装。
- 私钥和 App ID 都不入库；仓库里只放脚本与这份说明。
- 现有仓库若已配 branch protection，App 需要被加入 bypass 或被授予对应权限才能推送保护分支。

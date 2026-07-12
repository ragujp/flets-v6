# flets-v6 route-info monitor

NTT 東日本の経路情報配信サーバ (`http://route-info.flets-east.jp:49881/v6/route-info`) を
1日1回チェックし、Prefix の増減を検出したら Discord に Webhook で通知します。

route-info は NGN 網内からしかアクセスできないため、GitHub Actions のランナーから
Tailscale 経由で自宅サーバに SSH し、自宅サーバ上で curl を実行します。
SSH の認証は Tailscale SSH に任せるため、SSH 鍵の管理は不要です。

```
GitHub Actions ──(Tailscale)──> 自宅サーバ ──(NGN 網内 IPv6)──> route-info.flets-east.jp
       │
       └──> Discord Webhook(増減検出時 / ワークフロー失敗時)
```

## 動作

- 毎日 09:07 JST に実行(`workflow_dispatch` で手動実行も可能)
- 取得結果から `0000` 行(データ更新時刻)を除いた経路行を前回と比較
  - 増減があれば Discord に追加/削除された Prefix を通知
  - 最新の状態は `state/route-info.txt` にコミットされる(変更履歴 = 増減の履歴)
- 初回実行は状態ファイルの初期化のみで通知しない
- 取得失敗などワークフローが失敗した場合も Discord に通知

## セットアップ

### 1. Tailscale(タグ・OAuth クライアント・ACL)

1. Tailscale 管理画面の ACL に CI 用タグを追加:

   ```jsonc
   "tagOwners": {
     "tag:github-actions": ["autogroup:admin"],
   }
   ```

2. [OAuth clients](https://login.tailscale.com/admin/settings/oauth) で
   `auth_keys` スコープ・タグ `tag:github-actions` の OAuth クライアントを作成し、
   Client ID と Secret を控える。

3. ACL で「ランナー (tag:github-actions) → 自宅サーバの 22 番」の通信と、
   Tailscale SSH でのログインを許可する:

   ```jsonc
   "acls": [
     {"action": "accept", "src": ["tag:github-actions"], "dst": ["<自宅サーバ>:22"]},
   ],
   "ssh": [
     {
       "action": "accept",           // タグ付きノードからは check モード不可のため accept
       "src":    ["tag:github-actions"],
       "dst":    ["<自宅サーバ>"],    // 例: tag:home や自宅サーバのホスト
       "users":  ["<SSHユーザー名>"],
     },
   ]
   ```

### 2. 自宅サーバ

- Tailscale に参加済みで、Tailscale SSH を有効化しておく(Linux のみ対応):

  ```sh
  sudo tailscale set --ssh
  ```

  認証・認可は上記 ACL の `ssh` ルールで行われるため、SSH 鍵の登録は不要です。

- 取得専用のユーザーを作成する。Tailscale SSH では `authorized_keys` の
  `command=` 制限が使えないため、ログインシェル自体を
  「route-info を取得するだけのスクリプト」に固定して権限を絞る:

  ```sh
  # 専用シェル: SSH で何を要求されてもコマンドは無視し、route-info 取得だけを行う
  sudo tee /usr/local/bin/route-info-shell <<'EOF'
  #!/bin/sh
  exec curl -6 -sS -H 'Connection: close' -A '' \
    --connect-timeout 10 --max-time 30 \
    'http://route-info.flets-east.jp:49881/v6/route-info'
  EOF
  sudo chmod 755 /usr/local/bin/route-info-shell

  # 専用ユーザー(パスワードロック・sudo なし・シェル固定)
  sudo useradd --system --create-home --shell /usr/local/bin/route-info-shell route-getter
  sudo passwd -l route-getter

  # 動作確認
  sudo -u route-getter /usr/local/bin/route-info-shell | head
  ```

  これにより、万一 Tailscale の OAuth Secret が漏洩して第三者が SSH できたとしても、
  route-info の取得以外は何も実行できない。

### 3. GitHub リポジトリの Secrets

| Secret | 内容 |
|---|---|
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth クライアントの Client ID |
| `TS_OAUTH_SECRET` | Tailscale OAuth クライアントの Secret |
| `SSH_HOST` | 自宅サーバの Tailscale ホスト名 (MagicDNS) または 100.x.y.z |
| `SSH_USER` | SSH ユーザー名 |
| `DISCORD_WEBHOOK_URL` | Discord の Webhook URL |

また、ワークフローが `state/` をコミットするため、リポジトリの
Settings → Actions → General → Workflow permissions を
**Read and write permissions** にしておくこと(workflow 内の `permissions: contents: write` でも可)。

## 実行間隔の変更

`.github/workflows/route-info.yml` の cron を変更してください(UTC 指定)。
例: 毎日 09:07 JST → `7 0 * * *`

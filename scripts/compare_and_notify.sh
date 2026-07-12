#!/usr/bin/env bash
# route-info の取得結果を前回の状態と比較し、Prefix の増減があれば Discord に通知する。
#
# 使い方: compare_and_notify.sh <取得した生データ> <状態ファイル>
#
# 状態ファイルには「0000 行(データ更新時刻)を除いた経路行をソートしたもの」を保存する。
# 0000 行は経路が変わらなくても更新されうるため、比較対象から外している。
set -euo pipefail

RAW="$1"
STATE="$2"

CURRENT=$(mktemp)
trap 'rm -f "$CURRENT"' EXIT

grep -E '^[0-9]{4},' "$RAW" | grep -v '^0000,' | LC_ALL=C sort -u > "$CURRENT"

updated_at=$(grep '^0000,' "$RAW" | head -n1 | cut -d, -f2- || true)

mkdir -p "$(dirname "$STATE")"

if [ ! -f "$STATE" ]; then
  echo "初回実行: 状態ファイルを初期化します(通知はしません)"
  cp "$CURRENT" "$STATE"
  exit 0
fi

added=$(comm -13 "$STATE" "$CURRENT")
removed=$(comm -23 "$STATE" "$CURRENT")

if [ -z "$added" ] && [ -z "$removed" ]; then
  echo "変化なし"
  exit 0
fi

echo "変化を検出しました"
[ -n "$added" ] && { echo "--- 追加 ---"; echo "$added"; }
[ -n "$removed" ] && { echo "--- 削除 ---"; echo "$removed"; }

# Discord の embed field は 1024 文字までなので長すぎる場合は切り詰める
truncate_text() {
  local s="$1"
  if [ "${#s}" -gt 900 ]; then
    printf '%s\n…(省略。全体はリポジトリの state を参照)' "$(printf '%s' "$s" | head -c 900)"
  else
    printf '%s' "$s"
  fi
}

added_count=0
removed_count=0
[ -n "$added" ] && added_count=$(printf '%s\n' "$added" | wc -l | tr -d ' ')
[ -n "$removed" ] && removed_count=$(printf '%s\n' "$removed" | wc -l | tr -d ' ')

payload=$(jq -n \
  --arg added "$(truncate_text "$added")" \
  --arg removed "$(truncate_text "$removed")" \
  --arg added_count "$added_count" \
  --arg removed_count "$removed_count" \
  --arg updated_at "$updated_at" \
  '{
    username: "flets-v6 route-info",
    embeds: [{
      title: "FLET'\''S v6 route-info の Prefix に増減がありました",
      color: 16753920,
      fields: (
        (if $added != "" then
          [{name: ("➕ 追加 (" + $added_count + "件)"), value: ("```\n" + $added + "\n```")}]
         else [] end)
        +
        (if $removed != "" then
          [{name: ("➖ 削除 (" + $removed_count + "件)"), value: ("```\n" + $removed + "\n```")}]
         else [] end)
      ),
      footer: {text: ("データ更新時刻: " + $updated_at)},
      timestamp: (now | todate)
    }]
  }')

curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$DISCORD_WEBHOOK_URL" > /dev/null
echo "Discord に通知しました"

cp "$CURRENT" "$STATE"

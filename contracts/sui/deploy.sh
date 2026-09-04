#!/usr/bin/env bash
# Chui 合約一鍵部署（Sui Testnet）。
# 前提：已安裝 sui CLI（https://docs.sui.io/guides/developer/getting-started/sui-install）
#       且 active address 已從 https://faucet.sui.io 領過 Testnet SUI（付 gas 用）。
# 用法：./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "== 檢查環境 =="
sui --version
ACTIVE_ENV=$(sui client active-env)
if [ "$ACTIVE_ENV" != "testnet" ]; then
  echo "目前 env 是 ${ACTIVE_ENV}，切換到 testnet…"
  sui client switch --env testnet 2>/dev/null || {
    sui client new-env --alias testnet --rpc https://fullnode.testnet.sui.io:443
    sui client switch --env testnet
  }
fi
echo "部署地址：$(sui client active-address)"

echo "== 單元測試 =="
sui move test

echo "== 發佈到 Testnet =="
# 新版 CLI 會把發佈紀錄寫進 Published.toml，重跑時看到就拒絕重發
# （Your package is already published）。我們的流程本來就是「每次
# 部署＝全新 package」，所以先清掉上次的紀錄。
rm -f Published.toml Published.lock

# 不把輸出悶在 $() 裡：失敗時完整印出，並給出最常見原因的解法
set +e
PUBLISH_JSON=$(sui client publish --gas-budget 100000000 --json 2>&1)
publish_status=$?
set -e
if [ "${publish_status}" -ne 0 ]; then
  echo "${PUBLISH_JSON}"
  echo ""
  echo "❌ 發佈失敗（exit ${publish_status}）。兩個最常見原因與解法："
  echo "   1. sui CLI 太舊（上方有 protocol version 警告）→ brew upgrade sui"
  echo "   2. 已發佈紀錄擋住（already published）→ 刪掉 contracts/sui/Published.toml 重跑"
  exit 1
fi
# CLI 可能在 JSON 前印警告行——從第一個 { 開始解析
PACKAGE_ID=$(echo "$PUBLISH_JSON" | python3 -c "
import json, sys
raw = sys.stdin.read()
data = json.loads(raw[raw.find('{'):])
for change in data.get('objectChanges', []):
    if change.get('type') == 'published':
        print(change['packageId']); break
")
TX_DIGEST=$(echo "$PUBLISH_JSON" | python3 -c "
import json, sys
raw = sys.stdin.read()
print(json.loads(raw[raw.find('{'):])['digest'])
")

if [ -z "$PACKAGE_ID" ]; then
  echo "找不到 packageId，完整輸出："; echo "$PUBLISH_JSON"; exit 1
fi

echo "== 寫入 deployments/testnet.json =="
mkdir -p ../../deployments
cat > ../../deployments/testnet.json <<EOF
{
  "network": "testnet",
  "package_id": "${PACKAGE_ID}",
  "publish_tx": "${TX_DIGEST}",
  "modules": { "pay": { "settle": "settle" } },
  "settlement_event_type": "${PACKAGE_ID}::pay::SettlementEvent",
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
cat ../../deployments/testnet.json

echo ""
echo "✅ 部署完成。接下來："
echo "   1. 把 package_id 填進 chui-app 的 .env：CHUI_PACKAGE_ID=${PACKAGE_ID}"
echo "   2. explorer：https://suiscan.xyz/testnet/tx/${TX_DIGEST}"
echo "   3. git add ../../deployments/testnet.json && git commit && git push"

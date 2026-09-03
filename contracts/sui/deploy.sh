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
  echo "目前 env 是 $ACTIVE_ENV，切換到 testnet…"
  sui client switch --env testnet 2>/dev/null || {
    sui client new-env --alias testnet --rpc https://fullnode.testnet.sui.io:443
    sui client switch --env testnet
  }
fi
echo "部署地址：$(sui client active-address)"

echo "== 單元測試 =="
sui move test

echo "== 發佈到 Testnet =="
PUBLISH_JSON=$(sui client publish --gas-budget 100000000 --json)
PACKAGE_ID=$(echo "$PUBLISH_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for change in data.get('objectChanges', []):
    if change.get('type') == 'published':
        print(change['packageId']); break
")
TX_DIGEST=$(echo "$PUBLISH_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['digest'])")

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

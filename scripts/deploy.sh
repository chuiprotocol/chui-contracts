#!/usr/bin/env bash
# Chui Protocol 部署腳本。
#
# 用法：
#   scripts/deploy.sh                              # 部署到 testnet（預設）
#   scripts/deploy.sh --network testnet            # 同上
#   scripts/deploy.sh --network mainnet --yes-mainnet
#   scripts/deploy.sh --skip-tests                 # 跳過部署前測試（不建議）
#
# 安全設計：
#   - 預設網路一律是 testnet。
#   - 要部署 mainnet 必須「同時」傳 --network mainnet 與 --yes-mainnet 兩個旗標，
#     缺一即拒絕，避免誤觸真實資金環境。
#   - USDC coin type 是每個網路的設定值（寫入部署紀錄供 chui-app 讀取），
#     鏈上程式碼對幣別完全泛型，切換網路不需要改任何 Move 邏輯。
set -euo pipefail

cd "$(dirname "$0")/.."

# ===== 各網路設定值 =====
TESTNET_RPC="https://fullnode.testnet.sui.io:443"
MAINNET_RPC="https://fullnode.mainnet.sui.io:443"
# Circle 原生 USDC（資料來源：developers.circle.com，2026-08 查證）
TESTNET_USDC="0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC"
MAINNET_USDC="0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"
GAS_BUDGET="${CHUI_GAS_BUDGET:-500000000}"

# ===== 參數解析 =====
NETWORK="testnet"
YES_MAINNET=0
SKIP_TESTS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      NETWORK="${2:?--network 需要一個值}"
      shift 2
      ;;
    --yes-mainnet)
      YES_MAINNET=1
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | head -20
      exit 0
      ;;
    *)
      echo "未知參數：$1" >&2
      exit 1
      ;;
  esac
done

case "$NETWORK" in
  testnet)
    RPC="$TESTNET_RPC"
    USDC_TYPE="$TESTNET_USDC"
    ;;
  mainnet)
    if [[ "$YES_MAINNET" -ne 1 ]]; then
      echo "拒絕部署：mainnet 需要同時傳入 --yes-mainnet 旗標明確確認。" >&2
      exit 1
    fi
    RPC="$MAINNET_RPC"
    USDC_TYPE="$MAINNET_USDC"
    ;;
  *)
    echo "不支援的網路：$NETWORK（只接受 testnet 或 mainnet）" >&2
    exit 1
    ;;
esac

command -v sui >/dev/null || { echo "找不到 sui CLI，請先安裝：https://docs.sui.io/guides/developer/getting-started/sui-install" >&2; exit 1; }
command -v node >/dev/null || { echo "找不到 node（解析部署結果需要）" >&2; exit 1; }

# ===== 切換到目標網路 =====
if ! sui client envs --json 2>/dev/null | node -e '
  const envs = JSON.parse(require("fs").readFileSync(0, "utf8"));
  const list = Array.isArray(envs[0]) ? envs[0] : envs;
  process.exit(list.some(e => e.alias === process.argv[1]) ? 0 : 1);
' "$NETWORK"; then
  sui client new-env --alias "$NETWORK" --rpc "$RPC"
fi
sui client switch --env "$NETWORK"

ACTIVE_ADDRESS="$(sui client active-address)"
echo "部署網路：$NETWORK"
echo "部署位址：$ACTIVE_ADDRESS"

# ===== 部署前測試 =====
if [[ "$SKIP_TESTS" -ne 1 ]]; then
  echo "執行單元測試……"
  sui move test
fi

# ===== 發佈套件 =====
echo "發佈套件中……"
PUBLISH_JSON="$(sui client publish --gas-budget "$GAS_BUDGET" --json)"

# ===== 解析結果並寫入部署紀錄 =====
mkdir -p deployments
NETWORK="$NETWORK" RPC="$RPC" USDC_TYPE="$USDC_TYPE" ACTIVE_ADDRESS="$ACTIVE_ADDRESS" \
node -e '
  const fs = require("fs");
  const out = JSON.parse(fs.readFileSync(0, "utf8"));
  const changes = out.objectChanges || [];

  const published = changes.find(c => c.type === "published");
  if (!published) {
    console.error("部署結果中找不到 published 紀錄");
    process.exit(1);
  }
  const find = suffix => {
    const c = changes.find(
      c => c.type === "created" && c.objectType && c.objectType.endsWith(suffix),
    );
    return c ? c.objectId : null;
  };

  const record = {
    network: process.env.NETWORK,
    rpc: process.env.RPC,
    packageId: published.packageId,
    settlementRegistryId: find("::settlement::SettlementRegistry"),
    merchantDirectoryId: find("::merchant::MerchantDirectory"),
    upgradeCapId: find("::package::UpgradeCap"),
    usdcCoinType: process.env.USDC_TYPE,
    publisher: process.env.ACTIVE_ADDRESS,
    txDigest: out.digest,
    publishedAt: new Date().toISOString(),
  };
  for (const key of ["settlementRegistryId", "merchantDirectoryId"]) {
    if (!record[key]) {
      console.error(`部署結果中找不到 ${key} 對應的 shared 物件`);
      process.exit(1);
    }
  }
  const path = `deployments/${process.env.NETWORK}.json`;
  fs.writeFileSync(path, JSON.stringify(record, null, 2) + "\n");
  console.log(`已寫入 ${path}`);
  console.log(JSON.stringify(record, null, 2));
' <<<"$PUBLISH_JSON"

echo "部署完成。"

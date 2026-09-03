# chui（Sui Move 合約）

Chui Protocol 的鏈上結算模組。一個 module、一個 entry function——刻意極簡。

## `chui::pay::settle<T>(payment: Coin<T>, merchant: address, order_digest: vector<u8>)`

- **非託管**：付款 coin 在消費者簽名的同一筆交易內直接轉給店家，合約不保管資金。
- **隱私**：鏈上只留 32 bytes salted digest（SHA-256(明細 ‖ salt)）；
  explorer 看不到品項。
- **泛型幣別**：demo 用 Sui Testnet USDC（6 位小數）。
- **事件**：`SettlementEvent { merchant, payer, amount, coin_type, order_digest }`，
  Chui Hub 據此做鏈上驗證（digest／amount／merchant 三者皆符）。

Abort codes：`1 EEmptyPayment`（金額為零）、`2 EBadDigestLength`（digest 非 32 bytes）、
`3 ESelfPayment`（收款地址等於付款人）。

## 測試

```bash
sui move test
```

## 部署（Testnet）

```bash
./deploy.sh
```

腳本會：跑測試 → `sui client publish` → 把 package ID 與事件 type 寫進
`deployments/testnet.json` → 印出要填進 chui-app `.env` 的 `CHUI_PACKAGE_ID`。

⚠️ 一律 Testnet。付 gas 的測試幣：https://faucet.sui.io；
測試 USDC：https://faucet.circle.com（選 Sui Testnet）。

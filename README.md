<p align="center">
  <img src="https://raw.githubusercontent.com/chuiprotocol/chui-app/main/branding/chui-lockup.svg" alt="Chui Protocol" width="360" />
</p>

<h1 align="center">chui-contracts</h1>
<h3 align="center">Chui Protocol（嘴付協議）智能合約</h3>

<p align="center">
  <a href="https://github.com/chuiprotocol/chui-contracts/actions"><img src="https://img.shields.io/github/actions/workflow/status/chuiprotocol/chui-contracts/ci.yml?label=CI" alt="CI" /></a>
  <img src="https://img.shields.io/badge/chain-Sui%20Testnet-4DA2FF" alt="Sui Testnet" />
  <img src="https://img.shields.io/badge/lang-Move%202024-blue" alt="Move 2024" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT" />
</p>

<p align="center">
  <a href="https://github.com/chuiprotocol/chui-app">🎙 應用層（chui-app）</a> ·
  <a href="https://chuiprotocol.com">🌐 Live Demo</a> ·
  <a href="#威脅模型誠實版">🛡 威脅模型</a>
</p>

<p align="center">
  <a href="https://youtu.be/G8o4Wx5MeNM">
    <img src="https://img.youtube.com/vi/G8o4Wx5MeNM/maxresdefault.jpg" alt="Chui Protocol 2 分鐘 Demo 影片" width="640" />
  </a>
  <br />
  <em>▶ 點擊觀看 2 分鐘 Demo</em>
</p>

---

「語音點餐、鏈上自動扣款」的信任基礎全在這三個模組——**現階段每一行自寫**，
若找到更穩定的第三方合約會適當引用：

| 模組 | 職責 | 一句話 |
|---|---|---|
| [`chui::vault`](contracts/sui/sources/vault.move) | **預授權代付**（主流程） | 錢在用戶自己的 Vault，Agent 只拿 AgentCap 權限物件；合約五關檢查全過才放行單筆結算 |
| [`chui::pay`](contracts/sui/sources/pay.move) | **一次性直付**（替代流程） | 消費者親簽、coin 直達店家、合約零託管——面額即金額，不信任呼叫端參數 |
| [`chui::log_policy`](contracts/sui/sources/log_policy.move) | **隱私授權**（Seal 取鑰） | 對話紀錄密文的解密鑰，只發給「用戶或店家」兩個地址——平台 dry-run 也過不了 |

## 核心設計

### `chui::vault`——授權金庫

```
用戶唯一一次簽名 create_and_authorize：
  USDC → 自己的 Vault（shared object） ＋ AgentCap → 頁面裡的 agent key
之後每筆訂單 agent 呼叫 agent_settle：
  ① cap 屬於這個 vault？ ② cap 未被撤銷？ ③ 金額 > 0？
  ④ digest 恰為 32 bytes？ ⑤ 金額 ≤ 單筆上限 且 ≤ 餘額？
  全過 → USDC 從 Vault 直達店家 ＋ 發 SettlementEvent（含 owner，供訂單歸戶）
```

- **一鍵撤銷**：`revoke_caps` 把 cap_version +1，所有已發出的 cap 瞬間失效。
- **一鍵離場**：`revoke_caps`＋`withdraw` 可同一筆交易執行——按下去的瞬間
  Agent 再也動不了一毛錢、餘額全回錢包。
- **加值不重建**：`deposit` 存進既有 Vault，額度累計。
- **鏈上只有 digest**：`SHA-256(canonical_json(明細) ‖ 32B CSPRNG salt)`，
  explorer 看不到你買了什麼。

### 威脅模型（誠實版）

- **agent key 被偷的最壞情況**：攻擊者可在單筆上限內分多筆轉出——
  `per_tx_limit` 限單筆、不限總額，**總損失上限＝Vault 餘額**。
  這是刻意取捨：授權金額就是你的風險上限（建議小額、隨用隨充），
  且 owner 隨時可撤銷止血。商家白名單／epoch 累計限額列於 roadmap。
- **`deposit` 不設權限**：幫別人的 Vault 加值只會增加對方可領回的錢，無害。
- **owner 專屬操作**（withdraw／revoke／reauthorize）全驗 `ctx.sender()`；
  陌生人呼叫的攻擊路徑都有對應的 `expected_failure` 測試。

## Abort Codes

| 模組 | Code | 意義 |
|---|---|---|
| vault | 1 `EWrongVault` | cap 不屬於這個 vault |
| vault | 2 `ECapRevoked` | cap 已被撤銷 |
| vault | 3 `EOverPerTx` | 超過單筆上限 |
| vault | 4 `EInsufficientFunds` | Vault 餘額不足 |
| vault | 5 `ENotOwner` | 非 owner 呼叫 owner 專屬操作 |
| vault | 6 `EEmptyAmount` | 金額／上限為零 |
| vault | 7 `EBadDigestLength` | digest 非 32 bytes |
| pay | 1–3 | 空付款／壞 digest／付給自己 |
| log_policy | 1 `ENoAccess`、2 `EBadId` | 非當事人取鑰／id 非 64 bytes |

## 測試與部署

```bash
cd contracts/sui
sui move test        # 17 個單元測試（含撤銷、限額、陌生人攻擊路徑）
./deploy.sh          # 跑測試 → publish → 印出要填進 chui-app 的 CHUI_PACKAGE_ID
```

CI 每次 push 自動跑全部 Move 測試（官方 testnet release 的 sui CLI）。

> ⚠️ **Testnet only**。應用層程式碼層封鎖 mainnet；gas 測試幣
> [faucet.sui.io](https://faucet.sui.io)、測試 USDC
> [faucet.circle.com](https://faucet.circle.com)（選 Sui Testnet）。

## License

[MIT](LICENSE)

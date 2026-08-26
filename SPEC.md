# Chui Protocol 協定規格（SPEC）

版本：1.0.0（對應 Move 套件 `chui`）

本規格的目標：精確到讓第三方不看本 repo 的程式碼，就能在其他鏈上重新實作出
行為完全相容的協定。凡是「必須（MUST）」的條目都是協定的一部分；
實作平台的物件模型細節（如 Sui 的 owned/shared 物件）另以「平台對應」註記。

## 0. 術語與通用規則

- **消費者（consumer）**：授權 agent 代為付款的終端持幣人。
- **agent**：代消費者發起結算的自動化程式；在本協定中沒有獨立身分，
  一律以消費者的簽章身分行動。
- **商家（merchant）**：收款方，以 `merchant_id` 識別。
- 所有金額 MUST 使用結算幣別的**整數最小單位**（如 USDC 的 6 位小數最小單位）。
  禁止浮點數。
- 所有時間戳 MUST 使用 **Unix epoch 毫秒（UTC）**，由鏈上可信時鐘取得。
- `merchant_id` 與 `order_digest` MUST 是 **32-byte** 值；鏈上 MUST 只存雜湊，
  不存任何品項、數量、價格或訂單明文。
- 結算幣別 MUST 是實作層的設定值／型別參數，不得寫死在協定邏輯內。

## 1. 狀態物件

### 1.1 Mandate（消費者持有）

| 欄位 | 型別 | 語意 |
|---|---|---|
| `consumer` | address | 消費者位址；所有修改與結算的授權主體 |
| `per_tx_limit` | u64 | 單筆結算金額上限（含） |
| `daily_limit` | u64 | 單一 day bucket 內累計上限（含） |
| `merchant_allowlist` | set\<bytes32\> | 允許收款的 merchant_id 集合 |
| `expires_at` | u64 | 到期時間（epoch 毫秒）；`now > expires_at` 即失效，等於仍有效 |
| `day_bucket` | u64 | 目前累計所屬日；`epoch_ms / 86_400_000`（UTC 日界） |
| `day_spent` | u64 | 目前 day_bucket 內已結算累計 |
| `revoked` | bool | 撤銷旗標；一旦為 true 即永久失效 |

不變量：
- `0 < per_tx_limit ≤ daily_limit`（建立與每次更新時 MUST 驗證）。
- `revoked` 只能由 false 轉 true，不可逆。
- 除了結算流程對 `day_bucket` / `day_spent` 的更新外，
  所有欄位修改 MUST 由 `consumer` 本人簽章。

平台對應（Sui）：`Mandate<phantom T>` 為 address-owned 物件，由消費者持有；
`T` 是結算幣別型別參數。

### 1.2 Merchant

| 欄位 | 型別 | 語意 |
|---|---|---|
| `owner` | address | 商家擁有者；唯一可修改本物件的主體 |
| `merchant_id` | bytes32 | 商家識別雜湊，全協定唯一 |
| `payout_address` | address | 收款位址 |
| `active` | bool | 停用旗標；一旦為 false 即永久停用 |

不變量：
- `merchant_id` 在整個協定內 MUST 唯一（見 1.3）。
- `active` 只能由 true 轉 false，不可逆。停用後 `merchant_id` 的唯一性登記
  MUST 保留，不得釋出給他人重新註冊（防冒名）。
- `set_payout` 與 `deactivate` MUST 由 `owner` 簽章；已停用者不得再 `set_payout`。

平台對應（Sui）：shared 物件（結算交易由消費者發起，必須能引用它），
權限由 `owner` 欄位檢查。

### 1.3 MerchantDirectory（全協定唯一）

`merchant_id → merchant 物件識別` 的映射，`register` 時 MUST 檢查並登記，
重複註冊 MUST 拒絕。

### 1.4 SettlementRegistry（全協定唯一）

`order_digest → 已結算` 的映射，提供重放保護。key 一旦寫入 MUST 永不移除。

## 2. 操作

### 2.1 Mandate 操作（授權主體：consumer）

- `create_mandate(per_tx_limit, daily_limit, allowlist, expires_at)`：
  驗證限額不變量；驗證 allowlist 每個元素為 bytes32 且無重複；
  初始 `day_bucket = 0`、`day_spent = 0`、`revoked = false`。
- `revoke()`：設 `revoked = true`；重複撤銷 MUST 失敗。
- `update_limits(per_tx_limit, daily_limit, expires_at)`：驗證限額不變量；
  不重設 `day_spent`。
- `add_merchant(merchant_id)` / `remove_merchant(merchant_id)`：
  維護白名單；加入已存在或移除不存在的 id MUST 失敗。
- 已撤銷的 Mandate 上，一切修改操作 MUST 失敗。

### 2.2 Merchant 操作（授權主體：owner）

- `register(merchant_id, payout_address)`：驗證 bytes32、唯一性；`active = true`。
- `set_payout(addr)`、`deactivate()`：見 1.2 不變量。

### 2.3 settle（授權主體：consumer）

輸入：`mandate`、`merchant`、`payment`（結算幣別的資金）、`amount`、
`order_digest`、可信時鐘。

**檢查順序是協定的一部分，MUST 依下列順序執行，每項對應獨立 abort code：**

| # | 檢查 | abort code |
|---|---|---|
| 前置 1 | 簽章者是 `mandate.consumer` | `E_NOT_CONSUMER` |
| 前置 2 | `amount > 0` | `E_ZERO_AMOUNT` |
| 前置 3 | `order_digest` 長度 = 32 | `E_BAD_DIGEST` |
| 1 | `!mandate.revoked` | `E_REVOKED` |
| 2 | `now ≤ mandate.expires_at` | `E_EXPIRED` |
| 3 | `merchant.active` | `E_MERCHANT_INACTIVE` |
| 4 | `merchant.merchant_id ∈ mandate.merchant_allowlist` | `E_NOT_ALLOWLISTED` |
| 5 | `amount ≤ per_tx_limit` | `E_OVER_PER_TX` |
| 6 | 換日處理後：`day_spent ≤ daily_limit` 且 `amount ≤ daily_limit − day_spent` | `E_OVER_DAILY` |
| 7 | `order_digest ∉ SettlementRegistry` | `E_REPLAY` |
| 執行 | `payment 面額 ≥ amount` | `E_INSUFFICIENT_PAYMENT` |

**換日處理（檢查 6 之前 MUST 執行）**：
```
current_bucket = now / 86_400_000        // now 取自鏈上可信時鐘，MUST NOT 採用呼叫方傳入的日期值
if current_bucket != mandate.day_bucket:
    mandate.day_bucket = current_bucket
    mandate.day_spent = 0
```

**成功時 MUST 依序**：
1. `mandate.day_spent += amount`
2. 在 SettlementRegistry 登記 `order_digest`
3. 轉 `amount` 至 `merchant.payout_address`；`payment` 多餘面額退回簽章者
4. 發出事件：
```
SettlementEvent {
  mandate_id,        // Mandate 物件識別
  merchant_id,       // bytes32
  order_digest,      // bytes32
  day_bucket,        // u64
  amount_bucket,     // u8，見 §3——MUST NOT 是精確金額
}
```

Sui 參考實作的 abort code 數值：`chui::settlement` 模組內
`E_NOT_CONSUMER=1, E_ZERO_AMOUNT=2, E_BAD_DIGEST=3, E_REVOKED=4, E_EXPIRED=5,
E_MERCHANT_INACTIVE=6, E_NOT_ALLOWLISTED=7, E_OVER_PER_TX=8, E_OVER_DAILY=9,
E_REPLAY=10, E_INSUFFICIENT_PAYMENT=11`。
跨鏈重實作 MUST 保留檢查順序與錯誤的可區分性；數值本身可依平台慣例。

## 3. amount_bucket（對數級距）

```
amount_bucket(amount) = k，使得 2^k ≤ amount < 2^(k+1)   （amount ≥ 1）
```

等價於 `floor(log2(amount))`，u64 值域下 k ∈ [0, 63]。
事件 MUST 只公布 bucket，MUST NOT 公布精確金額。理由見 README「隱私模型」。

## 4. order_digest（鏈下演算法）

鏈上把 `order_digest` 當不透明 32-byte 值；產生規則屬鏈下規格：

```
order_digest = SHA-256( salt || canonical_json_bytes )
```

- `salt`：32-byte 密碼學隨機值，由下單方產生，與訂單明細一同離線保存。
- `canonical_json_bytes`：訂單明細 JSON 的正規化 UTF-8 序列化（RFC 8785 子集）：
  - 物件鍵依 Unicode code point 遞增排序（遞迴套用）
  - 無任何空白
  - 數值僅允許整數（金額用整數最小單位；出現非整數 MUST 拒絕）
  - 字串採標準 JSON 跳脫
- 驗證：任何持有訂單明細與 salt 的一方，重算 digest 後查
  SettlementRegistry 即可證明「這份明細確實已結算」；不持有明細的觀察者
  因 salt 的存在無法對 digest 做字典攻擊。

參考實作：`scripts/verify.ts`（重算 + 鏈上比對）。

## 5. 重放與唯一性語意

- 一個 `order_digest` 全協定 MUST 只能結算一次，跨 Mandate、跨商家亦然。
  同一份訂單要再結算，MUST 換新的 salt 產生新 digest。
- Registry 登記 MUST 永久保留（不得因商家停用、Mandate 撤銷而清除）。

## 6. 明確的非目標

- 協定不做退款、分期、託管；退款是商家對消費者的新一筆支付。
- 協定不驗證訂單明細內容，只承諾「digest 對應的那份明細已結算過一次」。
- 協定營運方沒有任何特權角色：沒有暫停開關、沒有資金提取路徑、
  沒有名單審批。所有權限都屬於消費者（Mandate）與商家擁有者（Merchant）本人。

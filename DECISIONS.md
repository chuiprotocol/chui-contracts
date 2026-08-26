# DECISIONS — 設計決策紀錄

本文件記錄實作 Chui Protocol Move 套件過程中做的每一個決策與理由。
規格未明定之處，一律在此說明選了什麼、為什麼。

## 工具鏈與版本

1. **sui CLI `testnet-v1.78.1`、Move edition `2024`**。
   動手前實際查證：GitHub 上最新 release 為 `testnet-v1.78.1`（2026-08-25），
   `sui move new` 產生的範本使用 edition `2024`。CI 亦鎖定同一版本。
2. **不在 Move.toml 明列 Sui framework 依賴**。
   sui ≥ 1.45 起由 CLI 隱式提供 framework 依賴，官方範本即為空依賴，照辦。
3. **USDC coin type 查證**（來源：Circle 官方文件與公告，2026-08 查證）：
   - Testnet：`0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC`
   - Mainnet：`0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC`

## 核心型別設計

4. **`Mandate<phantom T>` 對幣別泛型，而不是把 USDC 型別寫進 Move 程式碼**。
   規格要求 coin type 抽成設定值。在 Move 裡最乾淨的做法是型別參數：
   幣別由呼叫端（chui-app 讀 `deployments/<network>.json` 的 `usdcCoinType`）
   在建立 Mandate 與結算時帶入，切換 Mainnet 只改設定、不改任何鏈上邏輯。
   附帶好處：限額與付款幣別由型別系統強制一致，不可能拿 A 幣的 Mandate 配 B 幣付款。
5. **Mandate 是消費者 address-owned 物件**（規格要求「消費者持有」）。
   後果：結算交易必須由消費者（或以消費者身分簽章的 zkLogin session/agent）發起，
   sponsored transaction 只代付 gas、sender 仍是消費者，與 chui-app 的 UX 設計相容。
   另外在 `settle` 內保留 `sender == consumer` 的防禦性檢查（`E_NOT_CONSUMER`），
   即使未來改變所有權模型，授權判斷依然成立。
6. **Merchant 是 shared 物件，並比規格多了 `owner: address` 欄位**。
   結算由消費者發起，交易中必須能引用 Merchant 物件；owned 物件只有擁有者
   能引用，所以 Merchant 必須 shared。「僅擁有者可修改」改由 `owner` 欄位
   把關（`E_NOT_OWNER`）。
7. **新增 `MerchantDirectory`（shared），強制 merchant_id 全協定唯一**。
   規格沒有要求，但若不加：任何人都能用同一個 merchant_id 註冊第二個
   Merchant 物件、填自己的收款位址，冒名頂替已被消費者白名單的商家，
   agent 選錯物件就會把錢打給攻擊者。這是真實漏洞，因此 `register` 多收一個
   `&mut MerchantDirectory` 參數。代價：merchant_id 先到先得，有搶註風險（見「信任假設」）。
8. **merchant_id 與 order_digest 一律固定 32 bytes，長度上鏈前驗證**。
   「鏈上只存 hash」的自然推論：長度不是 32 的值不可能是本協定認可的雜湊，
   早擋早好（`E_INVALID_MERCHANT_ID` / `E_BAD_DIGEST`）。
9. **白名單用 `VecSet<vector<u8>>` 而非 Table**。
   白名單由消費者自付 gas 維護、規模小（幾個到幾十個商家），VecSet 便宜且
   可整包讀取；Table 適合無上限的大集合（registry 就是用 Table）。

## settle 的行為細節

10. **`settle` 參數比規格多了第一個 `registry: &mut SettlementRegistry`**。
    規格的內文要求重放保護必須用 shared 的 SettlementRegistry，物件在 Sui 上
    必須顯式作為交易輸入，所以簽名裡必然要有它。
11. **檢查順序**：先做三項前置檢查（依序 `E_NOT_CONSUMER`、`E_ZERO_AMOUNT`、
    `E_BAD_DIGEST`），再嚴格依規格順序執行七項檢查
    （`E_REVOKED` → `E_EXPIRED` → `E_MERCHANT_INACTIVE` → `E_NOT_ALLOWLISTED`
    → `E_OVER_PER_TX` → `E_OVER_DAILY` → `E_REPLAY`），
    最後在實際扣款時檢查 `E_INSUFFICIENT_PAYMENT`。
    前置檢查放最前面的理由：授權與輸入格式錯誤不該消耗任何協定狀態判斷；
    規格要求的七項相對順序完全不受影響，且每項都有獨立 abort code 與測試。
12. **禁止 0 元結算（`E_ZERO_AMOUNT`）**。0 元結算無意義，卻會永久燒掉一個
    order_digest，等於免費的 DoS 面（先把別人訂單的 digest 搶登記掉）。
    註：digest 含 32-byte 隨機 salt，第三方本來就猜不到，此檢查是縱深防禦。
13. **`expires_at` 含當下（`now > expires_at` 才失效）**。
    「時間超過 expires_at」的字面語意；邊界行為有測試釘死。
14. **每日上限用減法比較**：`spent <= daily && amount <= daily - spent`，
    避免 `day_spent + amount` 在極端限額下溢位（Move 溢位會 abort，但那會
    產生錯誤的 abort code）。若消費者當日把 daily_limit 調低到低於已花費，
    當日後續結算一律回 `E_OVER_DAILY`，跨日歸零後恢復。
15. **day bucket = `clock.timestamp_ms() / 86_400_000`（UTC 日界）**。
    由鏈上 Clock 推導，呼叫方無法影響；跨 bucket 時 `day_spent` 歸零。
    選 UTC 而非消費者時區：時區是鏈下概念，鏈上必須有全網一致的確定性日界。
16. **付款 Coin 面額可大於 amount，找零自動退回呼叫者**；面額剛好時整枚轉出。
    讓 agent 不必先精確 split 硬幣，一次交易完成。
17. **amount_bucket = floor(log2(amount))**，即 `2^k ≤ amount < 2^(k+1)` 時值為 k。
    對數級距在小額密集區間粗、大額區間更粗，符合「粗略區間」要求且實作
    無分支表、可攜到任何鏈。TS 端（verify.ts）有同款實作，Move 端有黃金值測試。
18. **狀態更新在轉帳之前**（checks-effects-interactions）。Move 沒有重入問題，
    但這個順序讓不變量更容易稽核。

## 生命週期語意

19. **`revoke` 不可逆**。撤銷是消費者的緊急煞車，語意必須簡單絕對；
    要恢復就建新的 Mandate（成本極低）。撤銷後 update/add/remove 一律
    `E_ALREADY_REVOKED`。
20. **`deactivate` 不可逆，且名錄登記不釋出**。若停用後釋出 merchant_id，
    攻擊者可搶註該 id 冒名收款——消費者白名單裡的舊 id 會指向新的假商家。
21. **限額約束：`0 < per_tx_limit ≤ daily_limit`**（建立與更新時皆檢查，
    `E_BAD_LIMITS`）。per_tx > daily 的組合永遠無法用滿，視為設定錯誤直接拒絕。

## 介面形式

22. **用 `public fun` 而非規格字面的 `public entry fun`**。
    現行編譯器明確警告 `public` 上的 `entry` 無意義（WSL01011）：`public fun`
    本來就能被 PTB 直接呼叫，且可組合進其他套件。行為與規格意圖完全一致。
23. **事件最小化**：另加 `MandateCreatedEvent`、`MandateRevokedEvent`、
    `MerchantRegisteredEvent`、`MerchantDeactivatedEvent`，全部只帶物件 ID 與
    merchant_id 雜湊，不帶限額、白名單、收款位址以外的任何內容——
    agent 與索引器需要這些事件運作，且不增加隱私面積。

## 鏈下規格

24. **order_digest 演算法（鏈下）**：`SHA-256( salt(32B) || canonical_json )`，
    canonical JSON 採 RFC 8785 子集（鍵依 code point 排序、無空白、僅允許整數）。
    選 SHA-256：所有語言標準庫可得、與鏈無關（第三方在別的鏈重實作不需要
    Sui 特有的雜湊）。鏈上把 digest 當不透明 32-byte 值，演算法可在鏈下升級。
25. **verify.ts 零依賴**（Node 22 內建 fetch + crypto，
    `node --experimental-strip-types` 直跑），不引入任何 npm 套件，
    降低供應鏈面積、CI 免安裝。

## 部署與流程

26. **deploy.sh 預設 testnet；mainnet 需要 `--network mainnet` 加 `--yes-mainnet`
    雙重明確旗標**，缺一即拒絕（CI 有測試釘住這個防呆）。部署前預設會先跑
    完整單元測試。部署紀錄（package ID、兩個 shared 物件 ID、UpgradeCap、
    該網路的 USDC coin type）寫入 `deployments/<network>.json` 供 chui-app 讀取。
27. **部署用 keypair 是本次工作容器由 sui CLI 新產生的 ed25519 位址**
    （`0xb9f55e84f0f5ef4d93d9f46af6db95e5b891f6fbaa4aea0b6a0ebdc7f037cb03`），
    僅用於 Testnet、不涉及真實資金。容器是暫時性的，正式部署應改用你自己
    控制的位址（見 README「Testnet 位址」與最終回報的手動步驟）。
28. **本工作階段的網路限制**：容器的 egress 政策封鎖了
    `fullnode.testnet.sui.io` 與 `faucet.testnet.sui.io`（proxy 403），
    因此本次無法從容器內完成實際部署與鏈上驗證。所有部署自動化
    （deploy.sh 全流程、deployments 寫檔、verify.ts 鏈上查詢）都已完成並
    在可離線驗證的範圍內測試過；在網路可達的環境跑一次 `scripts/deploy.sh`
    即完成部署。
29. **CI 用 release 二進位檔 + actions/cache 安裝 sui CLI**，版本與開發環境
    釘死同一個 tag；不用 cargo install（太慢）也不用 homebrew（版本不可釘）。

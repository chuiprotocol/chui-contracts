/// Chui Protocol — Mandate（授權書）模組。
///
/// Mandate 是由消費者持有的鏈上物件，定義 agent 可以花多少錢、可以付給哪些商家，
/// 並且可以由消費者隨時撤銷。協定營運方對 Mandate 沒有任何權限，
/// 也沒有任何函式允許協定營運方單方面移動資金。
///
/// 泛型參數 T 是結算幣別（例如 Testnet USDC）。限額一律以 T 的整數最小單位計價，
/// 幣別在建立 Mandate 時由呼叫方（chui-app 的設定檔）決定，鏈上邏輯不寫死任何幣別。
module chui::mandate;

use sui::event;
use sui::vec_set::{Self, VecSet};

// ===== 錯誤碼 =====

/// 呼叫者不是這份 Mandate 的消費者本人
const E_NOT_CONSUMER: u64 = 1;
/// 限額設定不合法：per_tx_limit 必須大於 0 且不得超過 daily_limit
const E_BAD_LIMITS: u64 = 2;
/// merchant_id 長度不是 32 bytes（協定規定 merchant_id 必須是 32-byte 雜湊）
const E_INVALID_MERCHANT_ID: u64 = 3;
/// merchant_id 已經在白名單內
const E_ALREADY_ALLOWLISTED: u64 = 4;
/// merchant_id 不在白名單內
const E_NOT_IN_ALLOWLIST: u64 = 5;
/// Mandate 已被撤銷；撤銷是不可逆的終態，之後不允許任何修改
const E_ALREADY_REVOKED: u64 = 6;

/// merchant_id 規定長度：32-byte 雜湊
const MERCHANT_ID_LENGTH: u64 = 32;

// ===== 資料結構 =====

/// 消費者持有的支付授權書。
/// 這是 address-owned 物件：只有消費者（或以消費者身分簽章的 agent，
/// 例如 zkLogin session）能在交易中引用它。
public struct Mandate<phantom T> has key {
    id: UID,
    /// 消費者位址。物件本身已由消費者持有，此欄位另做防禦性檢查，
    /// 確保即使未來改變物件所有權模型，授權判斷仍然成立。
    consumer: address,
    /// 單筆交易上限（幣別 T 的整數最小單位）
    per_tx_limit: u64,
    /// 每日累計上限（幣別 T 的整數最小單位）
    daily_limit: u64,
    /// 允許收款的商家白名單，元素為 32-byte merchant_id 雜湊
    merchant_allowlist: VecSet<vector<u8>>,
    /// 到期時間（Unix epoch 毫秒）。時鐘時間「超過」此值即失效，等於此值仍有效。
    expires_at: u64,
    /// 目前每日累計所屬的 day bucket（epoch 毫秒 / 86_400_000，UTC 日界）。
    /// 一律由鏈上 Clock 推導，絕不採用呼叫方傳入的日期值。
    day_bucket: u64,
    /// 目前 day bucket 內已結算的累計金額
    day_spent: u64,
    /// 是否已撤銷。撤銷後不可復原，也不可再結算或修改。
    revoked: bool,
}

// ===== 事件 =====
// 事件只帶物件 ID，不帶限額或白名單內容，避免在事件流中留下額外可交叉比對的明文。

/// Mandate 建立事件
public struct MandateCreatedEvent has copy, drop {
    mandate_id: ID,
}

/// Mandate 撤銷事件。agent 端可據此立即停止對該 Mandate 發起結算。
public struct MandateRevokedEvent has copy, drop {
    mandate_id: ID,
}

// ===== 入口函式 =====

/// 建立一份 Mandate 並轉移給呼叫者本人（消費者）。
/// allowlist 內每個元素都必須是 32-byte merchant_id 雜湊，且不得重複。
public fun create_mandate<T>(
    per_tx_limit: u64,
    daily_limit: u64,
    allowlist: vector<vector<u8>>,
    expires_at: u64,
    ctx: &mut TxContext,
) {
    assert!(per_tx_limit > 0 && per_tx_limit <= daily_limit, E_BAD_LIMITS);

    let mut set = vec_set::empty<vector<u8>>();
    let mut i = 0;
    while (i < allowlist.length()) {
        let id = allowlist[i];
        assert!(id.length() == MERCHANT_ID_LENGTH, E_INVALID_MERCHANT_ID);
        assert!(!set.contains(&id), E_ALREADY_ALLOWLISTED);
        set.insert(id);
        i = i + 1;
    };

    let mandate = Mandate<T> {
        id: object::new(ctx),
        consumer: ctx.sender(),
        per_tx_limit,
        daily_limit,
        merchant_allowlist: set,
        expires_at,
        day_bucket: 0,
        day_spent: 0,
        revoked: false,
    };

    event::emit(MandateCreatedEvent { mandate_id: object::id(&mandate) });
    transfer::transfer(mandate, ctx.sender());
}

/// 撤銷 Mandate。僅消費者本人可呼叫，且撤銷不可逆。
public fun revoke<T>(mandate: &mut Mandate<T>, ctx: &TxContext) {
    assert_consumer(mandate, ctx);
    assert!(!mandate.revoked, E_ALREADY_REVOKED);
    mandate.revoked = true;
    event::emit(MandateRevokedEvent { mandate_id: object::id(mandate) });
}

/// 更新限額與到期時間。僅消費者本人可呼叫，已撤銷的 Mandate 不可更新。
/// 注意：若把 daily_limit 調低到低於當日已花費（day_spent），
/// 當日後續結算會以 E_OVER_DAILY 失敗，直到跨日歸零為止。
public fun update_limits<T>(
    mandate: &mut Mandate<T>,
    per_tx_limit: u64,
    daily_limit: u64,
    expires_at: u64,
    ctx: &TxContext,
) {
    assert_consumer(mandate, ctx);
    assert!(!mandate.revoked, E_ALREADY_REVOKED);
    assert!(per_tx_limit > 0 && per_tx_limit <= daily_limit, E_BAD_LIMITS);
    mandate.per_tx_limit = per_tx_limit;
    mandate.daily_limit = daily_limit;
    mandate.expires_at = expires_at;
}

/// 把一個 merchant_id 加入白名單。僅消費者本人可呼叫。
public fun add_merchant<T>(
    mandate: &mut Mandate<T>,
    merchant_id: vector<u8>,
    ctx: &TxContext,
) {
    assert_consumer(mandate, ctx);
    assert!(!mandate.revoked, E_ALREADY_REVOKED);
    assert!(merchant_id.length() == MERCHANT_ID_LENGTH, E_INVALID_MERCHANT_ID);
    assert!(!mandate.merchant_allowlist.contains(&merchant_id), E_ALREADY_ALLOWLISTED);
    mandate.merchant_allowlist.insert(merchant_id);
}

/// 把一個 merchant_id 從白名單移除。僅消費者本人可呼叫。
public fun remove_merchant<T>(
    mandate: &mut Mandate<T>,
    merchant_id: vector<u8>,
    ctx: &TxContext,
) {
    assert_consumer(mandate, ctx);
    assert!(!mandate.revoked, E_ALREADY_REVOKED);
    assert!(mandate.merchant_allowlist.contains(&merchant_id), E_NOT_IN_ALLOWLIST);
    mandate.merchant_allowlist.remove(&merchant_id);
}

// ===== 唯讀存取（供 settlement 模組與外部查詢使用）=====

public fun consumer<T>(mandate: &Mandate<T>): address { mandate.consumer }
public fun per_tx_limit<T>(mandate: &Mandate<T>): u64 { mandate.per_tx_limit }
public fun daily_limit<T>(mandate: &Mandate<T>): u64 { mandate.daily_limit }
public fun expires_at<T>(mandate: &Mandate<T>): u64 { mandate.expires_at }
public fun day_bucket<T>(mandate: &Mandate<T>): u64 { mandate.day_bucket }
public fun day_spent<T>(mandate: &Mandate<T>): u64 { mandate.day_spent }
public fun is_revoked<T>(mandate: &Mandate<T>): bool { mandate.revoked }

public fun is_allowlisted<T>(mandate: &Mandate<T>, merchant_id: &vector<u8>): bool {
    mandate.merchant_allowlist.contains(merchant_id)
}

// ===== 套件內部修改（僅限本套件的 settlement 模組呼叫）=====

/// 若鏈上時鐘推導出的 day bucket 與目前紀錄不同，切換到新 bucket 並把當日累計歸零。
public(package) fun roll_day_if_needed<T>(mandate: &mut Mandate<T>, current_bucket: u64) {
    if (mandate.day_bucket != current_bucket) {
        mandate.day_bucket = current_bucket;
        mandate.day_spent = 0;
    }
}

/// 累加當日已花費。呼叫端（settlement）必須先完成所有限額檢查。
public(package) fun add_spent<T>(mandate: &mut Mandate<T>, amount: u64) {
    mandate.day_spent = mandate.day_spent + amount;
}

// ===== 內部輔助 =====

/// 防禦性檢查：呼叫者必須是消費者本人
fun assert_consumer<T>(mandate: &Mandate<T>, ctx: &TxContext) {
    assert!(ctx.sender() == mandate.consumer, E_NOT_CONSUMER);
}

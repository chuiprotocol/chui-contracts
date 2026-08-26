/// Chui Protocol — Settlement（結算）模組。
///
/// settle 是協定唯一會移動資金的入口：由消費者（或以消費者身分簽章的 agent）
/// 發起，依序通過 Mandate 與 Merchant 的所有檢查後，把款項轉給商家的收款位址。
/// 協定營運方在這條路徑上沒有任何角色，也拿不到任何資金控制權。
///
/// 隱私設計：鏈上與事件中只出現 order_digest（訂單明細的雜湊）與對數級距的
/// amount_bucket，絕不出現品項、數量、價格等明文，也不出現精確金額。
module chui::settlement;

use sui::clock::Clock;
use sui::coin::Coin;
use sui::event;
use sui::table::{Self, Table};
use chui::mandate::Mandate;
use chui::merchant::Merchant;

// ===== 錯誤碼 =====
// E_REVOKED ~ E_REPLAY 的檢查順序是協定規格的一部分，順序不可變動。
// 在其之前另有三項輸入／授權前置檢查（E_NOT_CONSUMER、E_ZERO_AMOUNT、E_BAD_DIGEST），
// E_INSUFFICIENT_PAYMENT 則發生在全部檢查通過後、實際扣款時。

/// 呼叫者不是 Mandate 的消費者本人（前置授權檢查）
const E_NOT_CONSUMER: u64 = 1;
/// 金額為 0（前置輸入檢查；0 元結算沒有意義，且會白白燒掉一個 digest）
const E_ZERO_AMOUNT: u64 = 2;
/// order_digest 長度不是 32 bytes（前置輸入檢查）
const E_BAD_DIGEST: u64 = 3;
/// Mandate 已撤銷
const E_REVOKED: u64 = 4;
/// 時鐘時間超過 expires_at
const E_EXPIRED: u64 = 5;
/// merchant.active 為 false
const E_MERCHANT_INACTIVE: u64 = 6;
/// merchant_id 不在 Mandate 的白名單內
const E_NOT_ALLOWLISTED: u64 = 7;
/// 金額超過單筆上限 per_tx_limit
const E_OVER_PER_TX: u64 = 8;
/// day_spent + amount 超過每日上限 daily_limit
const E_OVER_DAILY: u64 = 9;
/// 這個 order_digest 已經結算過（重放保護）
const E_REPLAY: u64 = 10;
/// 付款 Coin 面額不足 amount
const E_INSUFFICIENT_PAYMENT: u64 = 11;

/// 一天的毫秒數；day bucket = epoch 毫秒 / MS_PER_DAY（UTC 日界）
const MS_PER_DAY: u64 = 86_400_000;
/// order_digest 規定長度：32-byte 雜湊
const DIGEST_LENGTH: u64 = 32;

// ===== 資料結構 =====

/// 全協定唯一的結算名錄（shared），以 order_digest 為 key 提供重放保護。
public struct SettlementRegistry has key {
    id: UID,
    /// 已結算過的 order_digest。value 恆為 true，只用 key 的存在性判斷。
    settled: Table<vector<u8>, bool>,
}

// ===== 事件 =====

/// 結算成功事件。
/// 注意 amount_bucket 是對數級距（2^k ≤ amount < 2^(k+1) 時值為 k），
/// 刻意不是精確金額——詳見 README 的隱私模型。
public struct SettlementEvent has copy, drop {
    mandate_id: ID,
    merchant_id: vector<u8>,
    order_digest: vector<u8>,
    day_bucket: u64,
    amount_bucket: u8,
}

// ===== 初始化 =====

/// 套件發佈時建立唯一的 SettlementRegistry 並設為 shared。
fun init(ctx: &mut TxContext) {
    transfer::share_object(SettlementRegistry {
        id: object::new(ctx),
        settled: table::new(ctx),
    });
}

// ===== 入口函式 =====

/// 結算一筆訂單：檢查全部通過後，從 payment 中撥出 amount 給商家收款位址，
/// 找零（若有）退回呼叫者，最後發出 SettlementEvent。
///
/// 檢查順序（規格）：E_REVOKED → E_EXPIRED → E_MERCHANT_INACTIVE →
/// E_NOT_ALLOWLISTED → E_OVER_PER_TX → E_OVER_DAILY → E_REPLAY。
/// 每日累計的 day bucket 一律由鏈上 Clock 推導，絕不採用呼叫方傳入的日期值。
#[allow(lint(self_transfer))] // 找零退回呼叫者是本函式的預期行為
public fun settle<T>(
    registry: &mut SettlementRegistry,
    mandate: &mut Mandate<T>,
    merchant: &Merchant,
    payment: Coin<T>,
    amount: u64,
    order_digest: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // ── 前置授權與輸入檢查 ──
    let sender = ctx.sender();
    assert!(sender == mandate.consumer(), E_NOT_CONSUMER);
    assert!(amount > 0, E_ZERO_AMOUNT);
    assert!(order_digest.length() == DIGEST_LENGTH, E_BAD_DIGEST);

    // ── 規格檢查順序 ──
    // 1. Mandate 未撤銷
    assert!(!mandate.is_revoked(), E_REVOKED);

    // 2. 未過期（等於 expires_at 的當下仍有效）
    let now = clock.timestamp_ms();
    assert!(now <= mandate.expires_at(), E_EXPIRED);

    // 3. 商家仍在營運
    assert!(merchant.is_active(), E_MERCHANT_INACTIVE);

    // 4. 商家在白名單內
    let merchant_id = merchant.merchant_id();
    assert!(mandate.is_allowlisted(&merchant_id), E_NOT_ALLOWLISTED);

    // 5. 單筆上限
    assert!(amount <= mandate.per_tx_limit(), E_OVER_PER_TX);

    // 6. 每日上限：先由 Clock 推導 day bucket，跨日時歸零，再檢查累計。
    //    用減法而非加法比較，避免 day_spent + amount 溢位；
    //    若 daily_limit 曾在當日被調低到低於 day_spent，一律視為超限。
    let current_bucket = now / MS_PER_DAY;
    mandate.roll_day_if_needed(current_bucket);
    let spent = mandate.day_spent();
    let daily = mandate.daily_limit();
    assert!(spent <= daily && amount <= daily - spent, E_OVER_DAILY);

    // 7. 重放保護：order_digest 只能結算一次
    assert!(!registry.settled.contains(order_digest), E_REPLAY);

    // ── 執行 ──
    assert!(payment.value() >= amount, E_INSUFFICIENT_PAYMENT);

    // 先更新狀態再轉帳（checks-effects-interactions 習慣；
    // Move 沒有重入問題，但維持此順序讓不變量更易於稽核）。
    mandate.add_spent(amount);
    registry.settled.add(order_digest, true);

    // 撥款：面額剛好就整枚轉出，否則拆出 amount、找零退回呼叫者。
    let mut payment = payment;
    if (payment.value() == amount) {
        transfer::public_transfer(payment, merchant.payout_address());
    } else {
        let paid = payment.split(amount, ctx);
        transfer::public_transfer(paid, merchant.payout_address());
        transfer::public_transfer(payment, sender);
    };

    event::emit(SettlementEvent {
        mandate_id: object::id(mandate),
        merchant_id,
        order_digest,
        day_bucket: current_bucket,
        amount_bucket: amount_bucket(amount),
    });
}

// ===== 純函式 =====

/// 對數級距：回傳 k 使得 2^k ≤ amount < 2^(k+1)。
/// 呼叫端保證 amount ≥ 1，因此 k 落在 0..=63。
public fun amount_bucket(amount: u64): u8 {
    let mut k: u8 = 0;
    let mut v = amount;
    while (v > 1) {
        v = v >> 1;
        k = k + 1;
    };
    k
}

/// 查詢某個 order_digest 是否已結算過（供鏈下驗證與其他套件查詢）。
public fun is_settled(registry: &SettlementRegistry, order_digest: &vector<u8>): bool {
    registry.settled.contains(*order_digest)
}

// ===== 測試專用 =====

#[test_only]
/// 單元測試無法觸發套件發佈的 init，提供測試專用入口。
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

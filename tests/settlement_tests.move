/// chui::settlement 單元測試：涵蓋規格要求的每一個 abort code、
/// day bucket 換日歸零、重放保護，以及邊界條件（等於上限、等於到期時間）。
#[test_only]
module chui::settlement_tests;

use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as ts};
use chui::mandate::{Self, Mandate};
use chui::merchant::{Self, Merchant};
use chui::settlement::{Self, SettlementRegistry};
use chui::test_helpers::{
    Self as h,
    TEST_USDC,
    consumer,
    merchant_owner,
    payout,
    other,
    per_tx,
    daily,
    expires,
    now,
    ms_per_day,
    mid_1,
    bytes32,
};

// ===== 正常路徑 =====

#[test]
fun settle_exact_payment_pays_merchant_and_records_state() {
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(100));

    // 商家收款位址收到整筆金額
    s.next_tx(payout());
    let received = s.take_from_sender<Coin<TEST_USDC>>();
    assert!(received.value() == per_tx());
    coin::burn_for_testing(received);

    // Mandate 記錄了當日累計與 day bucket，digest 已登記
    s.next_tx(consumer());
    let m = s.take_from_sender<Mandate<TEST_USDC>>();
    assert!(m.day_spent() == per_tx());
    assert!(m.day_bucket() == now() / ms_per_day());
    s.return_to_sender(m);

    let registry = s.take_shared<SettlementRegistry>();
    assert!(settlement::is_settled(&registry, &bytes32(100)));
    assert!(!settlement::is_settled(&registry, &bytes32(101)));
    ts::return_shared(registry);
    s.end();
}

#[test]
fun settle_with_change_returns_remainder_to_sender() {
    let mut s = h::setup();
    let amount = 60_000_000;
    let payment = 90_000_000;
    h::do_settle(&mut s, consumer(), now(), payment, amount, bytes32(100));

    // 商家收到 amount
    s.next_tx(payout());
    let received = s.take_from_sender<Coin<TEST_USDC>>();
    assert!(received.value() == amount);
    coin::burn_for_testing(received);

    // 消費者收到找零
    s.next_tx(consumer());
    let change = s.take_from_sender<Coin<TEST_USDC>>();
    assert!(change.value() == payment - amount);
    coin::burn_for_testing(change);
    s.end();
}

#[test]
fun settle_at_exact_expiry_succeeds() {
    // 邊界：clock 時間「等於」expires_at 時仍有效
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), expires(), 1, 1, bytes32(100));
    s.end();
}

#[test]
fun settle_at_exact_per_tx_limit_succeeds() {
    // 邊界：金額「等於」per_tx_limit 時通過
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(100));
    s.end();
}

#[test]
fun settle_up_to_exact_daily_limit_succeeds() {
    // 邊界：當日累計「等於」daily_limit（300 = 100 × 3）時仍全部通過
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(1));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(2));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(3));

    s.next_tx(consumer());
    let m = s.take_from_sender<Mandate<TEST_USDC>>();
    assert!(m.day_spent() == daily());
    s.return_to_sender(m);
    s.end();
}

#[test]
fun day_rollover_resets_day_spent() {
    // 第一天花滿 daily_limit，跨日後必須歸零重新累計
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(1));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(2));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(3));

    // 換到下一個 day bucket 的整點
    let bucket_1 = now() / ms_per_day();
    let next_day_ms = (bucket_1 + 1) * ms_per_day();
    h::do_settle(&mut s, consumer(), next_day_ms, per_tx(), per_tx(), bytes32(4));

    s.next_tx(consumer());
    let m = s.take_from_sender<Mandate<TEST_USDC>>();
    assert!(m.day_bucket() == bucket_1 + 1);
    assert!(m.day_spent() == per_tx()); // 只剩新的一筆，前一日的累計已歸零
    s.return_to_sender(m);
    s.end();
}

#[test]
fun amount_bucket_is_logarithmic() {
    assert!(settlement::amount_bucket(1) == 0);
    assert!(settlement::amount_bucket(2) == 1);
    assert!(settlement::amount_bucket(3) == 1);
    assert!(settlement::amount_bucket(4) == 2);
    assert!(settlement::amount_bucket(1023) == 9);
    assert!(settlement::amount_bucket(1024) == 10);
    assert!(settlement::amount_bucket(18_446_744_073_709_551_615) == 63);
}

// ===== abort：前置授權與輸入檢查 =====

#[test, expected_failure(abort_code = chui::settlement::E_NOT_CONSUMER)]
fun settle_by_other_aborts() {
    let mut s = h::setup();
    h::do_settle(&mut s, other(), now(), per_tx(), per_tx(), bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_ZERO_AMOUNT)]
fun settle_zero_amount_aborts() {
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), 0, bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_BAD_DIGEST)]
fun settle_bad_digest_length_aborts() {
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), 1, b"not-32-bytes");
    abort 0
}

// ===== abort：規格檢查順序（E_REVOKED → … → E_REPLAY）=====

#[test, expected_failure(abort_code = chui::settlement::E_REVOKED)]
fun settle_revoked_mandate_aborts() {
    let mut s = h::setup();

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::revoke(&mut m, s.ctx());
    s.return_to_sender(m);

    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_EXPIRED)]
fun settle_after_expiry_aborts() {
    // 邊界：expires_at + 1 毫秒即失效
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), expires() + 1, per_tx(), per_tx(), bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_MERCHANT_INACTIVE)]
fun settle_inactive_merchant_aborts() {
    let mut s = h::setup();

    s.next_tx(merchant_owner());
    let mut merch = s.take_shared<Merchant>();
    merchant::deactivate(&mut merch, s.ctx());
    ts::return_shared(merch);

    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_NOT_ALLOWLISTED)]
fun settle_not_allowlisted_aborts() {
    let mut s = h::setup();

    // 消費者把商家從白名單移除後再結算
    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::remove_merchant(&mut m, mid_1(), s.ctx());
    s.return_to_sender(m);

    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_OVER_PER_TX)]
fun settle_over_per_tx_aborts() {
    // 邊界：per_tx_limit + 1 即超限
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), daily(), per_tx() + 1, bytes32(100));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_OVER_DAILY)]
fun settle_over_daily_aborts() {
    // daily = 3 × per_tx：第四筆必然超過每日上限
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(1));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(2));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(3));
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(4));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_OVER_DAILY)]
fun settle_after_daily_limit_lowered_below_spent_aborts() {
    // 當日已花 100，之後把 daily_limit 調低到 50 → 後續結算必須失敗
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx(), per_tx(), bytes32(1));

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::update_limits(&mut m, 50, 50, expires(), s.ctx());
    s.return_to_sender(m);

    h::do_settle(&mut s, consumer(), now(), 50, 50, bytes32(2));
    abort 0
}

#[test, expected_failure(abort_code = chui::settlement::E_REPLAY)]
fun settle_same_digest_twice_aborts() {
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), 1, 1, bytes32(100));
    h::do_settle(&mut s, consumer(), now(), 1, 1, bytes32(100));
    abort 0
}

// ===== abort：付款面額不足 =====

#[test, expected_failure(abort_code = chui::settlement::E_INSUFFICIENT_PAYMENT)]
fun settle_insufficient_payment_aborts() {
    let mut s = h::setup();
    h::do_settle(&mut s, consumer(), now(), per_tx() - 1, per_tx(), bytes32(100));
    abort 0
}

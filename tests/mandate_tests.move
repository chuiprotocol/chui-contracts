/// chui::mandate 單元測試：涵蓋每個 abort code 與所有正常路徑。
#[test_only]
module chui::mandate_tests;

use sui::test_scenario::{Self as ts};
use chui::mandate::{Self, Mandate};
use chui::test_helpers::{
    Self as h,
    TEST_USDC,
    consumer,
    other,
    per_tx,
    daily,
    expires,
    mid_1,
};

// ===== 正常路徑 =====

#[test]
fun create_sets_all_fields() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[mid_1()], expires(), s.ctx());

    s.next_tx(consumer());
    let m = s.take_from_sender<Mandate<TEST_USDC>>();
    assert!(m.consumer() == consumer());
    assert!(m.per_tx_limit() == per_tx());
    assert!(m.daily_limit() == daily());
    assert!(m.expires_at() == expires());
    assert!(m.day_bucket() == 0);
    assert!(m.day_spent() == 0);
    assert!(!m.is_revoked());
    assert!(m.is_allowlisted(&mid_1()));
    assert!(!m.is_allowlisted(&h::bytes32(9)));
    s.return_to_sender(m);
    s.end();
}

#[test]
fun revoke_marks_revoked() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::revoke(&mut m, s.ctx());
    assert!(m.is_revoked());
    s.return_to_sender(m);
    s.end();
}

#[test]
fun update_limits_updates_fields() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::update_limits(&mut m, 7, 9, expires() + 1, s.ctx());
    assert!(m.per_tx_limit() == 7);
    assert!(m.daily_limit() == 9);
    assert!(m.expires_at() == expires() + 1);
    s.return_to_sender(m);
    s.end();
}

#[test]
fun add_then_remove_merchant() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::add_merchant(&mut m, mid_1(), s.ctx());
    assert!(m.is_allowlisted(&mid_1()));
    mandate::remove_merchant(&mut m, mid_1(), s.ctx());
    assert!(!m.is_allowlisted(&mid_1()));
    s.return_to_sender(m);
    s.end();
}

// ===== abort：建立時的限額與白名單驗證 =====

#[test, expected_failure(abort_code = chui::mandate::E_BAD_LIMITS)]
fun create_zero_per_tx_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(0, daily(), vector[], expires(), s.ctx());
    s.end();
}

#[test, expected_failure(abort_code = chui::mandate::E_BAD_LIMITS)]
fun create_per_tx_above_daily_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(daily() + 1, daily(), vector[], expires(), s.ctx());
    s.end();
}

#[test, expected_failure(abort_code = chui::mandate::E_INVALID_MERCHANT_ID)]
fun create_short_merchant_id_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[b"short"], expires(), s.ctx());
    s.end();
}

#[test, expected_failure(abort_code = chui::mandate::E_ALREADY_ALLOWLISTED)]
fun create_duplicate_allowlist_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(
        per_tx(),
        daily(),
        vector[mid_1(), mid_1()],
        expires(),
        s.ctx(),
    );
    s.end();
}

// ===== abort：僅消費者本人 =====

#[test, expected_failure(abort_code = chui::mandate::E_NOT_CONSUMER)]
fun revoke_by_other_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(other());
    let mut m = s.take_from_address<Mandate<TEST_USDC>>(consumer());
    mandate::revoke(&mut m, s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_NOT_CONSUMER)]
fun update_limits_by_other_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(other());
    let mut m = s.take_from_address<Mandate<TEST_USDC>>(consumer());
    mandate::update_limits(&mut m, 1, 1, expires(), s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_NOT_CONSUMER)]
fun add_merchant_by_other_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(other());
    let mut m = s.take_from_address<Mandate<TEST_USDC>>(consumer());
    mandate::add_merchant(&mut m, mid_1(), s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_NOT_CONSUMER)]
fun remove_merchant_by_other_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[mid_1()], expires(), s.ctx());

    s.next_tx(other());
    let mut m = s.take_from_address<Mandate<TEST_USDC>>(consumer());
    mandate::remove_merchant(&mut m, mid_1(), s.ctx());
    abort 0
}

// ===== abort：撤銷後不可再操作 =====

#[test, expected_failure(abort_code = chui::mandate::E_ALREADY_REVOKED)]
fun revoke_twice_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::revoke(&mut m, s.ctx());
    mandate::revoke(&mut m, s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_ALREADY_REVOKED)]
fun update_limits_after_revoke_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::revoke(&mut m, s.ctx());
    mandate::update_limits(&mut m, 1, 1, expires(), s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_ALREADY_REVOKED)]
fun add_merchant_after_revoke_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::revoke(&mut m, s.ctx());
    mandate::add_merchant(&mut m, mid_1(), s.ctx());
    abort 0
}

// ===== abort：白名單操作驗證 =====

#[test, expected_failure(abort_code = chui::mandate::E_INVALID_MERCHANT_ID)]
fun add_merchant_bad_length_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::add_merchant(&mut m, b"not-32-bytes", s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_ALREADY_ALLOWLISTED)]
fun add_merchant_duplicate_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[mid_1()], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::add_merchant(&mut m, mid_1(), s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::mandate::E_NOT_IN_ALLOWLIST)]
fun remove_merchant_missing_aborts() {
    let mut s = ts::begin(consumer());
    mandate::create_mandate<TEST_USDC>(per_tx(), daily(), vector[], expires(), s.ctx());

    s.next_tx(consumer());
    let mut m = s.take_from_sender<Mandate<TEST_USDC>>();
    mandate::remove_merchant(&mut m, mid_1(), s.ctx());
    abort 0
}

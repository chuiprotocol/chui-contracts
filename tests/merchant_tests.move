/// chui::merchant 單元測試：涵蓋每個 abort code 與所有正常路徑。
#[test_only]
module chui::merchant_tests;

use sui::test_scenario::{Self as ts};
use chui::merchant::{Self, Merchant, MerchantDirectory};
use chui::test_helpers::{Self as h, merchant_owner, payout, other, mid_1};

/// 建立 directory 並以 merchant_owner 註冊 mid_1
fun setup(): ts::Scenario {
    let mut s = ts::begin(merchant_owner());
    merchant::init_for_testing(s.ctx());

    s.next_tx(merchant_owner());
    let mut dir = s.take_shared<MerchantDirectory>();
    merchant::register(&mut dir, mid_1(), payout(), s.ctx());
    ts::return_shared(dir);
    s
}

// ===== 正常路徑 =====

#[test]
fun register_sets_all_fields() {
    let mut s = setup();

    s.next_tx(merchant_owner());
    let m = s.take_shared<Merchant>();
    assert!(m.owner() == merchant_owner());
    assert!(m.merchant_id() == mid_1());
    assert!(m.payout_address() == payout());
    assert!(m.is_active());
    ts::return_shared(m);
    s.end();
}

#[test]
fun set_payout_updates_address() {
    let mut s = setup();

    s.next_tx(merchant_owner());
    let mut m = s.take_shared<Merchant>();
    merchant::set_payout(&mut m, other(), s.ctx());
    assert!(m.payout_address() == other());
    ts::return_shared(m);
    s.end();
}

#[test]
fun deactivate_marks_inactive() {
    let mut s = setup();

    s.next_tx(merchant_owner());
    let mut m = s.take_shared<Merchant>();
    merchant::deactivate(&mut m, s.ctx());
    assert!(!m.is_active());
    ts::return_shared(m);
    s.end();
}

// ===== abort：註冊驗證 =====

#[test, expected_failure(abort_code = chui::merchant::E_INVALID_MERCHANT_ID)]
fun register_bad_length_aborts() {
    let mut s = ts::begin(merchant_owner());
    merchant::init_for_testing(s.ctx());

    s.next_tx(merchant_owner());
    let mut dir = s.take_shared<MerchantDirectory>();
    merchant::register(&mut dir, b"not-32-bytes", payout(), s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::merchant::E_MERCHANT_ID_TAKEN)]
fun register_duplicate_id_aborts() {
    let mut s = setup();

    // 換另一個人也用同一個 merchant_id 註冊 → 必須被擋下（冒名頂替防護）
    s.next_tx(other());
    let mut dir = s.take_shared<MerchantDirectory>();
    merchant::register(&mut dir, mid_1(), other(), s.ctx());
    abort 0
}

// ===== abort：僅擁有者 =====

#[test, expected_failure(abort_code = chui::merchant::E_NOT_OWNER)]
fun set_payout_by_other_aborts() {
    let mut s = setup();

    s.next_tx(other());
    let mut m = s.take_shared<Merchant>();
    merchant::set_payout(&mut m, other(), s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::merchant::E_NOT_OWNER)]
fun deactivate_by_other_aborts() {
    let mut s = setup();

    s.next_tx(other());
    let mut m = s.take_shared<Merchant>();
    merchant::deactivate(&mut m, s.ctx());
    abort 0
}

// ===== abort：停用是終態 =====

#[test, expected_failure(abort_code = chui::merchant::E_ALREADY_DEACTIVATED)]
fun deactivate_twice_aborts() {
    let mut s = setup();

    s.next_tx(merchant_owner());
    let mut m = s.take_shared<Merchant>();
    merchant::deactivate(&mut m, s.ctx());
    merchant::deactivate(&mut m, s.ctx());
    abort 0
}

#[test, expected_failure(abort_code = chui::merchant::E_ALREADY_DEACTIVATED)]
fun set_payout_after_deactivate_aborts() {
    let mut s = setup();

    s.next_tx(merchant_owner());
    let mut m = s.take_shared<Merchant>();
    merchant::deactivate(&mut m, s.ctx());
    merchant::set_payout(&mut m, other(), s.ctx());
    abort 0
}

// 讓 helper 的匯入不因只用部分符號而報 unused 警告
#[test]
fun helper_bytes32_shape() {
    assert!(h::bytes32(7).length() == 32);
}

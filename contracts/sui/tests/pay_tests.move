/// chui::pay 單元測試。
/// 執行：cd contracts/sui && sui move test
#[test_only]
module chui::pay_tests;

use sui::coin;
use sui::sui::SUI;
use sui::test_scenario;
use chui::pay;

const CONSUMER: address = @0xA11CE;
const MERCHANT: address = @0xB0B;

/// 32 bytes 的測試 digest
fun test_digest(): vector<u8> {
    let mut digest = vector[];
    let mut i: u8 = 0;
    while (i < 32) {
        digest.push_back(i);
        i = i + 1;
    };
    digest
}

#[test]
fun settle_transfers_coin_to_merchant() {
    let mut scenario = test_scenario::begin(CONSUMER);
    {
        let payment = coin::mint_for_testing<SUI>(2_080_000, scenario.ctx());
        pay::settle(payment, MERCHANT, test_digest(), scenario.ctx());
    };
    // 下一個 tx 以店家身分檢查：coin 已到店家名下且面額正確
    scenario.next_tx(MERCHANT);
    {
        let received = scenario.take_from_sender<coin::Coin<SUI>>();
        assert!(received.value() == 2_080_000, 0);
        scenario.return_to_sender(received);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = pay::EEmptyPayment)]
fun settle_rejects_zero_payment() {
    let mut scenario = test_scenario::begin(CONSUMER);
    {
        let payment = coin::mint_for_testing<SUI>(0, scenario.ctx());
        pay::settle(payment, MERCHANT, test_digest(), scenario.ctx());
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = pay::EBadDigestLength)]
fun settle_rejects_short_digest() {
    let mut scenario = test_scenario::begin(CONSUMER);
    {
        let payment = coin::mint_for_testing<SUI>(100, scenario.ctx());
        pay::settle(payment, MERCHANT, vector[1, 2, 3], scenario.ctx());
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = pay::ESelfPayment)]
fun settle_rejects_paying_self() {
    let mut scenario = test_scenario::begin(CONSUMER);
    {
        let payment = coin::mint_for_testing<SUI>(100, scenario.ctx());
        pay::settle(payment, CONSUMER, test_digest(), scenario.ctx());
    };
    scenario.end();
}

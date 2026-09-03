/// chui::vault 單元測試。執行：cd contracts/sui && sui move test
#[test_only]
module chui::vault_tests;

use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario};
use chui::vault::{Self, Vault, AgentCap};

const OWNER: address = @0xA11CE;
const AGENT: address = @0xA9E27;
const MERCHANT: address = @0xB0B;
const STRANGER: address = @0xBAD;

const THREE_USDC: u64 = 3_000_000;
const ORDER_AMOUNT: u64 = 2_080_000;

fun test_digest(): vector<u8> {
    let mut digest = vector::empty<u8>();
    let mut i = 0;
    while (i < 32) {
        digest.push_back((i as u8));
        i = i + 1;
    };
    digest
}

/// 建 vault（3 USDC、單筆上限 3 USDC）並把 cap 交給 AGENT
fun setup(scenario: &mut Scenario) {
    let deposit = coin::mint_for_testing<SUI>(THREE_USDC, scenario.ctx());
    vault::create_and_authorize(deposit, THREE_USDC, AGENT, scenario.ctx());
}

#[test]
fun agent_settle_pays_merchant_and_tracks_spent() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);

    // agent 用 cap 結算：錢從 vault 直接到商家
    scenario.next_tx(AGENT);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        let cap = scenario.take_from_sender<AgentCap>();
        vault::agent_settle(&mut v, &cap, ORDER_AMOUNT, MERCHANT, test_digest(), scenario.ctx());
        assert!(vault::remaining(&v) == THREE_USDC - ORDER_AMOUNT, 0);
        assert!(vault::spent(&v) == ORDER_AMOUNT, 1);
        scenario.return_to_sender(cap);
        test_scenario::return_shared(v);
    };
    // 商家收到正確金額
    scenario.next_tx(MERCHANT);
    {
        let received = scenario.take_from_sender<Coin<SUI>>();
        assert!(received.value() == ORDER_AMOUNT, 2);
        scenario.return_to_sender(received);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EOverPerTx)]
fun settle_rejects_over_per_tx_limit() {
    let mut scenario = test_scenario::begin(OWNER);
    {
        let deposit = coin::mint_for_testing<SUI>(THREE_USDC, scenario.ctx());
        // 單筆上限 1 USDC，卻要扣 2.08 USDC → 必須 abort
        vault::create_and_authorize(deposit, 1_000_000, AGENT, scenario.ctx());
    };
    scenario.next_tx(AGENT);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        let cap = scenario.take_from_sender<AgentCap>();
        vault::agent_settle(&mut v, &cap, ORDER_AMOUNT, MERCHANT, test_digest(), scenario.ctx());
        scenario.return_to_sender(cap);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EInsufficientFunds)]
fun settle_rejects_when_funds_exhausted() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    scenario.next_tx(AGENT);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        let cap = scenario.take_from_sender<AgentCap>();
        // 第一筆花掉 2.08，剩 0.92；第二筆 2.08 必須 abort
        vault::agent_settle(&mut v, &cap, ORDER_AMOUNT, MERCHANT, test_digest(), scenario.ctx());
        vault::agent_settle(&mut v, &cap, ORDER_AMOUNT, MERCHANT, test_digest(), scenario.ctx());
        scenario.return_to_sender(cap);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::ECapRevoked)]
fun revoke_kills_cap_immediately() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    // owner 撤銷
    scenario.next_tx(OWNER);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        vault::revoke_caps(&mut v, scenario.ctx());
        test_scenario::return_shared(v);
    };
    // agent 再結算 → 必須 abort
    scenario.next_tx(AGENT);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        let cap = scenario.take_from_sender<AgentCap>();
        vault::agent_settle(&mut v, &cap, 1_000, MERCHANT, test_digest(), scenario.ctx());
        scenario.return_to_sender(cap);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::ENotOwner)]
fun stranger_cannot_revoke() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    scenario.next_tx(STRANGER);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        vault::revoke_caps(&mut v, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::ENotOwner)]
fun stranger_cannot_withdraw() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    scenario.next_tx(STRANGER);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        vault::withdraw(&mut v, scenario.ctx());
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun owner_withdraws_remaining() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    scenario.next_tx(OWNER);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        vault::withdraw(&mut v, scenario.ctx());
        assert!(vault::remaining(&v) == 0, 0);
        test_scenario::return_shared(v);
    };
    scenario.next_tx(OWNER);
    {
        let refund = scenario.take_from_sender<Coin<SUI>>();
        assert!(refund.value() == THREE_USDC, 1);
        scenario.return_to_sender(refund);
    };
    scenario.end();
}

#[test]
#[expected_failure(abort_code = vault::EBadDigestLength)]
fun settle_rejects_short_digest() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    scenario.next_tx(AGENT);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        let cap = scenario.take_from_sender<AgentCap>();
        vault::agent_settle(&mut v, &cap, 1_000, MERCHANT, vector[1, 2, 3], scenario.ctx());
        scenario.return_to_sender(cap);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

#[test]
fun reauthorize_after_revoke_works() {
    let mut scenario = test_scenario::begin(OWNER);
    setup(&mut scenario);
    // 撤銷 → 重新授權新 cap
    scenario.next_tx(OWNER);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        vault::revoke_caps(&mut v, scenario.ctx());
        vault::reauthorize(&v, AGENT, scenario.ctx());
        test_scenario::return_shared(v);
    };
    // 新 cap 可用（舊 cap 已死，這裡拿到的是最新那顆——先把兩顆都取出挑對的）
    scenario.next_tx(AGENT);
    {
        let mut v = scenario.take_shared<Vault<SUI>>();
        let cap_a = scenario.take_from_sender<AgentCap>();
        let cap_b = scenario.take_from_sender<AgentCap>();
        let (fresh, stale) = if (vault::cap_is_current(&v, &cap_a)) (cap_a, cap_b) else (cap_b, cap_a);
        vault::agent_settle(&mut v, &fresh, 1_000, MERCHANT, test_digest(), scenario.ctx());
        assert!(vault::spent(&v) == 1_000, 0);
        scenario.return_to_sender(fresh);
        scenario.return_to_sender(stale);
        test_scenario::return_shared(v);
    };
    scenario.end();
}

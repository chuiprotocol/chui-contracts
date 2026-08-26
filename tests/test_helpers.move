/// 測試共用工具：測試幣別、常用位址、標準測試環境與 settle 快捷函式。
#[test_only]
module chui::test_helpers;

use sui::clock::{Self, Clock};
use sui::coin;
use sui::test_scenario::{Self as ts, Scenario};
use chui::mandate::{Self, Mandate};
use chui::merchant::{Self, Merchant, MerchantDirectory};
use chui::settlement::{Self, SettlementRegistry};

/// 測試用幣別。實際部署時由 chui-app 設定檔決定（Testnet 為 Circle 測試用 USDC），
/// 鏈上邏輯對幣別完全泛型，這裡用任意型別即可完整覆蓋邏輯。
public struct TEST_USDC has drop {}

// ===== 常用位址 =====

public fun consumer(): address { @0xA11CE }
public fun merchant_owner(): address { @0xB0B }
public fun payout(): address { @0xFACE }
public fun other(): address { @0xDEAD }

// ===== 常用參數（金額以 6 位小數的最小單位計）=====

/// 單筆上限：100 USDC
public fun per_tx(): u64 { 100_000_000 }
/// 每日上限：300 USDC
public fun daily(): u64 { 300_000_000 }
/// 到期時間（epoch 毫秒，遠在測試時間之後）
public fun expires(): u64 { 1_900_000_000_000 }
/// 測試的「現在」（epoch 毫秒，早於 expires）
public fun now(): u64 { 1_800_000_000_000 }
/// 一天的毫秒數
public fun ms_per_day(): u64 { 86_400_000 }

/// 產生一個以 n 結尾的 32-byte merchant_id / digest
public fun bytes32(n: u8): vector<u8> {
    let mut v = vector[];
    let mut i = 0u8;
    while (i < 31) {
        v.push_back(0);
        i = i + 1;
    };
    v.push_back(n);
    v
}

/// 預設商家 id
public fun mid_1(): vector<u8> { bytes32(1) }

// ===== 環境建置 =====

/// 標準測試環境：registry 與 directory 已建立、商家 mid_1 已註冊（收款位址 payout()）、
/// 消費者已建立一份白名單含 mid_1 的 Mandate。
public fun setup(): Scenario {
    let mut s = ts::begin(merchant_owner());
    merchant::init_for_testing(s.ctx());
    settlement::init_for_testing(s.ctx());

    s.next_tx(merchant_owner());
    {
        let mut dir = s.take_shared<MerchantDirectory>();
        merchant::register(&mut dir, mid_1(), payout(), s.ctx());
        ts::return_shared(dir);
    };

    s.next_tx(consumer());
    mandate::create_mandate<TEST_USDC>(
        per_tx(),
        daily(),
        vector[mid_1()],
        expires(),
        s.ctx(),
    );
    s
}

/// 建立設定好時間的測試時鐘
public fun make_clock(now_ms: u64, s: &mut Scenario): Clock {
    let mut clk = clock::create_for_testing(s.ctx());
    clk.set_for_testing(now_ms);
    clk
}

/// 以 sender 身分、指定鏈上時間，鑄造 payment_value 的測試幣並結算 amount。
public fun do_settle(
    s: &mut Scenario,
    sender: address,
    now_ms: u64,
    payment_value: u64,
    amount: u64,
    digest: vector<u8>,
) {
    s.next_tx(sender);
    let mut registry = s.take_shared<SettlementRegistry>();
    let mut m = s.take_from_address<Mandate<TEST_USDC>>(consumer());
    let merch = s.take_shared<Merchant>();
    let clk = make_clock(now_ms, s);
    let pay = coin::mint_for_testing<TEST_USDC>(payment_value, s.ctx());

    settlement::settle(&mut registry, &mut m, &merch, pay, amount, digest, &clk, s.ctx());

    clk.destroy_for_testing();
    ts::return_shared(registry);
    ts::return_shared(merch);
    ts::return_to_address(consumer(), m);
}

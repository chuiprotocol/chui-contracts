/// Chui Protocol（嘴付協議）結算模組。
///
/// 設計原則：
/// 1. 非託管：付款 coin 由消費者在錢包（Slush）簽名的同一筆交易內
///    直接轉給店家地址，合約不保管任何資金。
/// 2. 隱私：鏈上只留 32 bytes 的 salted digest（SHA-256(明細 ‖ salt)），
///    explorer 看不到品項與菜單價格明細；金額是幣別最小單位（USDC 6 位）。
/// 3. 泛型幣別：settle<T> 對任何 Coin<T> 都成立，demo 用 Sui Testnet USDC。
///
/// 應用層（Chui Hub）以 SettlementEvent 做鏈上驗證：
/// 比對 order_digest、amount、merchant 三者皆符才視為結算完成。
module chui::pay;

use sui::coin::Coin;
use sui::event;
use std::type_name;

/// 付款金額為零：拒絕空結算
const EEmptyPayment: u64 = 1;
/// digest 長度不是 32 bytes：不是合法的 SHA-256 輸出
const EBadDigestLength: u64 = 2;
/// 不可把錢付給自己（防呆：店家地址填錯成自己）
const ESelfPayment: u64 = 3;

/// 結算事件：Hub 與任何第三方都能據此獨立驗證一筆訂單已付款。
public struct SettlementEvent has copy, drop {
    /// 收款店家地址
    merchant: address,
    /// 付款人（消費者錢包）地址
    payer: address,
    /// 金額（該幣別最小單位，USDC 為 6 位小數）
    amount: u64,
    /// 幣別（如 ...::usdc::USDC），供索引器過濾
    coin_type: std::ascii::String,
    /// SHA-256(canonical_json(訂單明細) ‖ 32B salt)；鏈上唯一的訂單資訊
    order_digest: vector<u8>,
}

/// 結算：把整顆 payment coin 轉給店家並發出結算事件。
///
/// 呼叫端（錢包側）用 coinWithBalance 先切出「剛好等於訂單金額」的 coin，
/// 因此 coin 面額即結算金額，合約不需再信任呼叫端另傳的金額參數。
public entry fun settle<T>(
    payment: Coin<T>,
    merchant: address,
    order_digest: vector<u8>,
    ctx: &TxContext,
) {
    let amount = payment.value();
    assert!(amount > 0, EEmptyPayment);
    assert!(order_digest.length() == 32, EBadDigestLength);
    assert!(ctx.sender() != merchant, ESelfPayment);

    event::emit(SettlementEvent {
        merchant,
        payer: ctx.sender(),
        amount,
        coin_type: type_name::get<T>().into_string(),
        order_digest,
    });
    transfer::public_transfer(payment, merchant);
}

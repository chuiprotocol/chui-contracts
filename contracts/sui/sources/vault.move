/// Chui Protocol 授權金庫（vault）模組——零按鍵自動結帳的鏈上守門人。
///
/// 設計（全部自寫，不依賴任何第三方合約）：
/// 1. 資金不離開用戶：USDC 存在用戶自己的 Vault（shared object，owner 欄位
///    控制 withdraw／revoke），Chui Agent 拿到的只是 AgentCap「權限物件」。
/// 2. 合約強制限額：agent_settle 檢查 cap 未撤銷 ∧ 金額 ≤ 單筆上限 ∧
///    Vault 餘額足夠，全過才把 USDC 直接轉給商家——agent 永遠拿不到本金。
/// 3. 一鍵撤銷：owner 把 cap_version +1，所有已發出的 cap 立即全部失效。
/// 4. 隱私：鏈上只留 32 bytes salted digest。
///
/// 威脅模型（誠實版）：
/// - agent key 被偷的最壞情況：攻擊者可在單筆上限內「分多筆」把餘額
///   轉往任意地址——per_tx_limit 限制的是單筆、不是總額，**總損失上限
///   ＝Vault 餘額本身**。這是刻意的設計取捨：授權金額就是你願意承擔的
///   風險上限（demo 建議小額），而 owner 隨時可 revoke_caps 止血、
///   withdraw 領回。要更強的防護（商家白名單、epoch 累計限額）列於
///   roadmap，屬功能擴充而非漏洞修補。
/// - deposit 刻意不設權限：任何人「幫別人的 Vault 加值」只會增加該
///   owner 可領回的餘額，無利可圖、無害。
/// - owner 專屬操作（withdraw／revoke／reauthorize）全部驗 ctx.sender()；
///   agent_settle 驗 cap 綁定＋版本＋單筆上限＋餘額＋digest 長度，
///   五關全過才放行，缺一即 abort。
module chui::vault;

use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::event;
use std::type_name;

/// cap 不屬於這個 vault
const EWrongVault: u64 = 1;
/// cap 已被撤銷（版本過期）
const ECapRevoked: u64 = 2;
/// 超過單筆上限
const EOverPerTx: u64 = 3;
/// Vault 餘額不足
const EInsufficientFunds: u64 = 4;
/// 只有 Vault 擁有者能做這件事
const ENotOwner: u64 = 5;
/// 金額為零
const EEmptyAmount: u64 = 6;
/// digest 長度不是 32 bytes
const EBadDigestLength: u64 = 7;

/// 用戶的授權金庫。shared object；資金與規則都在這裡。
public struct Vault<phantom T> has key {
    id: UID,
    /// 只有 owner 能 withdraw / revoke / 調整上限
    owner: address,
    /// 用戶存入的資金（總額上限＝餘額本身）
    funds: Balance<T>,
    /// 單筆上限（幣別最小單位）
    per_tx_limit: u64,
    /// 撤銷版本：+1 即讓所有已發出的 cap 失效
    cap_version: u64,
    /// 累計已結算金額（供查帳）
    spent: u64,
}

/// Agent 的權限物件：只證明「可在規則內觸發結算」，本身不含任何資金。
public struct AgentCap has key, store {
    id: UID,
    vault_id: ID,
    version: u64,
}

/// 建立事件：前端據此取得 vault_id 與 cap_id
public struct VaultCreated has copy, drop {
    vault_id: ID,
    cap_id: ID,
    owner: address,
    agent: address,
    amount: u64,
    per_tx_limit: u64,
}

/// 結算事件：Hub 據此驗證（digest／amount／merchant 三符）
public struct SettlementEvent has copy, drop {
    vault_id: ID,
    merchant: address,
    owner: address,
    amount: u64,
    coin_type: std::ascii::String,
    order_digest: vector<u8>,
}

public struct CapsRevoked has copy, drop { vault_id: ID, new_version: u64 }
public struct Withdrawn has copy, drop { vault_id: ID, amount: u64 }

/// 用戶唯一一次動手：存入資金、設單筆上限、把 AgentCap 交給 agent。
public fun create_and_authorize<T>(
    deposit: Coin<T>,
    per_tx_limit: u64,
    agent: address,
    ctx: &mut TxContext,
) {
    let amount = deposit.value();
    assert!(amount > 0, EEmptyAmount);
    assert!(per_tx_limit > 0, EEmptyAmount);
    let vault = Vault<T> {
        id: object::new(ctx),
        owner: ctx.sender(),
        funds: deposit.into_balance(),
        per_tx_limit,
        cap_version: 1,
        spent: 0,
    };
    let cap = AgentCap {
        id: object::new(ctx),
        vault_id: object::id(&vault),
        version: 1,
    };
    event::emit(VaultCreated {
        vault_id: object::id(&vault),
        cap_id: object::id(&cap),
        owner: ctx.sender(),
        agent,
        amount,
        per_tx_limit,
    });
    transfer::public_transfer(cap, agent);
    transfer::share_object(vault);
}

/// Agent 自動結算：規則全過才從 Vault 把錢直接轉給商家。
public fun agent_settle<T>(
    vault: &mut Vault<T>,
    cap: &AgentCap,
    amount: u64,
    merchant: address,
    order_digest: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(cap.vault_id == object::id(vault), EWrongVault);
    assert!(cap.version == vault.cap_version, ECapRevoked);
    assert!(amount > 0, EEmptyAmount);
    assert!(order_digest.length() == 32, EBadDigestLength);
    assert!(amount <= vault.per_tx_limit, EOverPerTx);
    assert!(vault.funds.value() >= amount, EInsufficientFunds);

    vault.spent = vault.spent + amount;
    let payment = coin::from_balance(vault.funds.split(amount), ctx);
    event::emit(SettlementEvent {
        vault_id: object::id(vault),
        merchant,
        owner: vault.owner,
        amount,
        coin_type: type_name::with_defining_ids<T>().into_string(),
        order_digest,
    });
    transfer::public_transfer(payment, merchant);
}

/// 用戶加值（不需要重新授權，額度＝餘額）。
public fun deposit<T>(vault: &mut Vault<T>, more: Coin<T>) {
    vault.funds.join(more.into_balance());
}

/// 一鍵撤銷：所有已發出的 AgentCap 立即失效。只有 owner 能呼叫。
public fun revoke_caps<T>(vault: &mut Vault<T>, ctx: &TxContext) {
    assert!(ctx.sender() == vault.owner, ENotOwner);
    vault.cap_version = vault.cap_version + 1;
    event::emit(CapsRevoked { vault_id: object::id(vault), new_version: vault.cap_version });
}

/// 撤銷後重新授權：發新的 cap 給（新的）agent。只有 owner 能呼叫。
public fun reauthorize<T>(vault: &Vault<T>, agent: address, ctx: &mut TxContext) {
    assert!(ctx.sender() == vault.owner, ENotOwner);
    let cap = AgentCap { id: object::new(ctx), vault_id: object::id(vault), version: vault.cap_version };
    transfer::public_transfer(cap, agent);
}

/// 領回全部剩餘資金。只有 owner 能呼叫。
public fun withdraw<T>(vault: &mut Vault<T>, ctx: &mut TxContext) {
    assert!(ctx.sender() == vault.owner, ENotOwner);
    let amount = vault.funds.value();
    event::emit(Withdrawn { vault_id: object::id(vault), amount });
    transfer::public_transfer(coin::from_balance(vault.funds.withdraw_all(), ctx), vault.owner);
}

// ---- 唯讀查詢（前端顯示額度用）----

public fun remaining<T>(vault: &Vault<T>): u64 { vault.funds.value() }
public fun per_tx_limit<T>(vault: &Vault<T>): u64 { vault.per_tx_limit }
public fun spent<T>(vault: &Vault<T>): u64 { vault.spent }
public fun cap_version<T>(vault: &Vault<T>): u64 { vault.cap_version }
public fun cap_is_current<T>(vault: &Vault<T>, cap: &AgentCap): bool {
    cap.vault_id == object::id(vault) && cap.version == vault.cap_version
}

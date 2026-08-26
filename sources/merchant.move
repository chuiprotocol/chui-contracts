/// Chui Protocol — Merchant（商家）模組。
///
/// Merchant 是 shared 物件：結算交易由消費者（或其 agent）發起，
/// 必須能在交易中引用商家物件，因此不能做成商家持有的 owned 物件。
/// 修改權限改由物件內的 owner 欄位把關，僅商家擁有者本人可以修改。
///
/// merchant_id 是 32-byte 雜湊（例如商家法律實體識別資料的雜湊），
/// 鏈上不存商家名稱等任何明文。
module chui::merchant;

use sui::event;
use sui::table::{Self, Table};

// ===== 錯誤碼 =====

/// 呼叫者不是這個 Merchant 物件的擁有者
const E_NOT_OWNER: u64 = 1;
/// merchant_id 長度不是 32 bytes
const E_INVALID_MERCHANT_ID: u64 = 2;
/// 這個 merchant_id 已經被註冊過（協定內 merchant_id 必須唯一，防止冒名頂替）
const E_MERCHANT_ID_TAKEN: u64 = 3;
/// Merchant 已經停用；停用是不可逆的終態
const E_ALREADY_DEACTIVATED: u64 = 4;

/// merchant_id 規定長度：32-byte 雜湊
const MERCHANT_ID_LENGTH: u64 = 32;

// ===== 資料結構 =====

/// 商家登錄物件（shared）。
public struct Merchant has key {
    id: UID,
    /// 商家擁有者位址。因為物件是 shared，修改權限由此欄位把關。
    owner: address,
    /// 32-byte merchant_id 雜湊，在整個協定內唯一
    merchant_id: vector<u8>,
    /// 收款位址
    payout_address: address,
    /// 是否仍可收款。停用後不可復原。
    active: bool,
}

/// 全協定唯一的商家名錄（shared），確保 merchant_id 不會被重複註冊。
/// 若沒有這層唯一性保證，攻擊者可以用相同 merchant_id 註冊第二個 Merchant
/// 物件並填入自己的收款位址，冒名頂替已被消費者列入白名單的商家。
public struct MerchantDirectory has key {
    id: UID,
    /// merchant_id 雜湊 → Merchant 物件 ID
    taken: Table<vector<u8>, ID>,
}

// ===== 事件 =====

/// 商家註冊事件
public struct MerchantRegisteredEvent has copy, drop {
    merchant_object_id: ID,
    merchant_id: vector<u8>,
}

/// 商家停用事件
public struct MerchantDeactivatedEvent has copy, drop {
    merchant_object_id: ID,
    merchant_id: vector<u8>,
}

// ===== 初始化 =====

/// 套件發佈時建立唯一的 MerchantDirectory 並設為 shared。
fun init(ctx: &mut TxContext) {
    transfer::share_object(MerchantDirectory {
        id: object::new(ctx),
        taken: table::new(ctx),
    });
}

// ===== 入口函式 =====

/// 註冊一個商家。merchant_id 必須是 32-byte 雜湊且尚未被任何人註冊。
/// 建立出來的 Merchant 物件是 shared，擁有者為呼叫者本人。
public fun register(
    directory: &mut MerchantDirectory,
    merchant_id: vector<u8>,
    payout_address: address,
    ctx: &mut TxContext,
) {
    assert!(merchant_id.length() == MERCHANT_ID_LENGTH, E_INVALID_MERCHANT_ID);
    assert!(!directory.taken.contains(merchant_id), E_MERCHANT_ID_TAKEN);

    let merchant = Merchant {
        id: object::new(ctx),
        owner: ctx.sender(),
        merchant_id,
        payout_address,
        active: true,
    };

    directory.taken.add(merchant_id, object::id(&merchant));
    event::emit(MerchantRegisteredEvent {
        merchant_object_id: object::id(&merchant),
        merchant_id,
    });
    transfer::share_object(merchant);
}

/// 變更收款位址。僅商家擁有者本人可呼叫。
public fun set_payout(merchant: &mut Merchant, addr: address, ctx: &TxContext) {
    assert_owner(merchant, ctx);
    assert!(merchant.active, E_ALREADY_DEACTIVATED);
    merchant.payout_address = addr;
}

/// 停用商家。僅商家擁有者本人可呼叫，且停用不可逆。
/// 名錄中的 merchant_id 登記保留不釋出，避免停用後被他人搶註冒名。
public fun deactivate(merchant: &mut Merchant, ctx: &TxContext) {
    assert_owner(merchant, ctx);
    assert!(merchant.active, E_ALREADY_DEACTIVATED);
    merchant.active = false;
    event::emit(MerchantDeactivatedEvent {
        merchant_object_id: object::id(merchant),
        merchant_id: merchant.merchant_id,
    });
}

// ===== 唯讀存取 =====

public fun owner(merchant: &Merchant): address { merchant.owner }
public fun merchant_id(merchant: &Merchant): vector<u8> { merchant.merchant_id }
public fun payout_address(merchant: &Merchant): address { merchant.payout_address }
public fun is_active(merchant: &Merchant): bool { merchant.active }

// ===== 內部輔助 =====

/// 防禦性檢查：呼叫者必須是商家擁有者本人
fun assert_owner(merchant: &Merchant, ctx: &TxContext) {
    assert!(ctx.sender() == merchant.owner, E_NOT_OWNER);
}

// ===== 測試專用 =====

#[test_only]
/// 單元測試無法觸發套件發佈的 init，提供測試專用入口。
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

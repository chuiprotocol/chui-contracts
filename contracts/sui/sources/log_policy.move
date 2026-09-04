/// Seal 存取政策：點餐對話 log 的解密權限。
///
/// 對話 log 在用戶瀏覽器內以 Seal（門檻式 IBE）加密後上傳 Walrus，
/// 身分 id ＝ 用戶地址(32B) ‖ 店家地址(32B)。Seal key server 發金鑰前
/// 會以「請求者」為 sender dry-run 本函式——只有 id 裡的兩方能通過，
/// 嘴付平台（Hub）與任何第三方都拿不到鑰匙。
module chui::log_policy;

use sui::address;

/// 請求者不是這份 log 的當事人（既非用戶也非店家）
const ENoAccess: u64 = 1;
/// id 長度不對（必須是 64 bytes：兩個地址）
const EBadId: u64 = 2;

/// Seal 標準進入點：核可才返回，否則 abort（key server 便拒發金鑰）。
entry fun seal_approve(id: vector<u8>, ctx: &TxContext) {
    assert!(id.length() == 64, EBadId);
    let mut owner_bytes = vector[];
    let mut merchant_bytes = vector[];
    let mut i = 0;
    while (i < 32) {
        owner_bytes.push_back(id[i]);
        i = i + 1;
    };
    while (i < 64) {
        merchant_bytes.push_back(id[i]);
        i = i + 1;
    };
    let owner = address::from_bytes(owner_bytes);
    let merchant = address::from_bytes(merchant_bytes);
    let sender = ctx.sender();
    assert!(sender == owner || sender == merchant, ENoAccess);
}

#[test_only]
/// 測試用：讓單元測試能直接呼叫（entry 函式測試中也可呼叫，此別名保留語意清晰）
public fun approve_for_testing(id: vector<u8>, ctx: &TxContext) {
    seal_approve(id, ctx)
}

/// chui::log_policy 單元測試。執行：cd contracts/sui && sui move test
#[test_only]
module chui::log_policy_tests;

use sui::test_scenario;
use chui::log_policy;

const OWNER: address = @0xA11CE;
const MERCHANT: address = @0xB0B;
const STRANGER: address = @0xBAD;

fun id_for(owner: address, merchant: address): vector<u8> {
    let mut id = sui::address::to_bytes(owner);
    id.append(sui::address::to_bytes(merchant));
    id
}

#[test]
fun owner_can_decrypt() {
    let mut scenario = test_scenario::begin(OWNER);
    log_policy::approve_for_testing(id_for(OWNER, MERCHANT), scenario.ctx());
    scenario.end();
}

#[test]
fun merchant_can_decrypt() {
    let mut scenario = test_scenario::begin(MERCHANT);
    log_policy::approve_for_testing(id_for(OWNER, MERCHANT), scenario.ctx());
    scenario.end();
}

#[test]
#[expected_failure(abort_code = log_policy::ENoAccess)]
fun stranger_cannot_decrypt() {
    let mut scenario = test_scenario::begin(STRANGER);
    log_policy::approve_for_testing(id_for(OWNER, MERCHANT), scenario.ctx());
    scenario.end();
}

#[test]
#[expected_failure(abort_code = log_policy::EBadId)]
fun short_id_rejected() {
    let mut scenario = test_scenario::begin(OWNER);
    log_policy::approve_for_testing(vector[1, 2, 3], scenario.ctx());
    scenario.end();
}

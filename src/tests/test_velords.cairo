use openzeppelin::access::ownable::interface::{IOwnableDispatcher, IOwnableDispatcherTrait};
use lordship::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use lordship::interfaces::IVE::{IVEDispatcher, IVEDispatcherTrait};
use lordship::tests::common;
use lordship::velords::Lock;
use snforge_std::{load, start_prank, start_warp, stop_prank, CheatTarget};
use starknet::{ContractAddress, Store, get_block_timestamp};

#[test]
fn test_velords_setup() {
    let velords = IERC20Dispatcher { contract_address: common::deploy_velords() };
    assert_eq!(velords.name(), "Voting LORDS", "name mismatch");
    assert_eq!(velords.symbol(), "veLORDS", "symbol mismatch");
    assert_eq!(velords.decimals(), 18, "decimals mismatch");
    assert_eq!(velords.total_supply(), 0, "total supply mismatch");

    let owner = common::velords_owner();
    assert_eq!(IOwnableDispatcher { contract_address: velords.contract_address }.owner(), owner, "owner mismatch");
}

#[test]
#[should_panic(expected: "veLORDS are not transferable")]
fn test_velords_non_transferable() {
    let velords = IERC20Dispatcher { contract_address: common::deploy_velords() };
    let owner: ContractAddress = common::velords_owner();
    let spender: ContractAddress = 'king'.try_into().unwrap();

    start_prank(CheatTarget::One(velords.contract_address), owner);
    // testing approve() returns false in here too
    assert_eq!(velords.approve(spender, 100), false, "approve should not be available");

    velords.transfer(spender, 1); // should panic
}

// TODO:
// test create new lock pass
// fail creating for others
// fail creating when amount == 0
// fail creating when unlock time is 0
// more...

#[test]
fn test_create_new_lock_pass() {
    let (velords, lords) = common::velords_setup();
    let velords_token = IERC20Dispatcher { contract_address: velords.contract_address };

    let blobert: ContractAddress = common::blobert();
    let balance: u256 = 10_000_000 * common::ONE;

    common::fund_lords(blobert, Option::Some(balance));

    let lock_amount: u256 = 2_000_000 * common::ONE;
    let now = get_block_timestamp();
    let unlock_time: u64 = now + common::YEAR;

    // blobert allows veLords contract to transfer its LORDS
    start_prank(CheatTarget::One(lords.contract_address), blobert);
    lords.approve(velords.contract_address, lock_amount);
    stop_prank(CheatTarget::One(lords.contract_address));

    // sanity checks
    assert_eq!(lords.balance_of(blobert), balance, "balance mismatch");
    assert_eq!(lords.allowance(blobert, velords.contract_address), lock_amount, "allowance mismatch");
    assert_eq!(velords_token.total_supply(), 0, "total supply mismatch");

    // blobert locks 2M LORDS for 1 year
    start_prank(CheatTarget::One(velords.contract_address), blobert);
    velords.manage_lock(lock_amount, unlock_time, blobert);

    assert_eq!(lords.balance_of(blobert), balance - lock_amount, "LORDS balance mismatch after locking");
    assert_eq!(velords_token.total_supply(), lock_amount, "total supply mismatch after locking");
    // TODO
    // assert_eq!(velords_token.balance_of(blobert), lock_amount, "veLORDS balance mismatch after locking");

    let lock: Lock = velords.get_lock_for(blobert);
    assert_eq!(lock.amount, lock_amount.try_into().unwrap(), "lock amount mismatch");
    assert_eq!(lock.end_time, common::floor_to_week(unlock_time), "unlock time mismatch");

    // TODO: test events
}

#[test]
fn test_create_new_lock_capped_4y_pass() {
    let (velords, lords) = common::velords_setup();
    let velords_token = IERC20Dispatcher { contract_address: velords.contract_address };

    let blobert: ContractAddress = common::blobert();
    let balance: u256 = 10_000_000 * common::ONE;

    common::fund_lords(blobert, Option::Some(balance));

    let lock_amount: u256 = 2_000_000 * common::ONE;
    let now = get_block_timestamp();
    let unlock_time: u64 = now + 20 * common::YEAR;
    let capped_unlock_time: u64 = now + 4 * common::YEAR;

    // blobert allows veLords contract to transfer its LORDS
    start_prank(CheatTarget::One(lords.contract_address), blobert);
    lords.approve(velords.contract_address, lock_amount);
    stop_prank(CheatTarget::One(lords.contract_address));

    // blobert locks 2M LORDS for 20 years, will be capped to 4
    start_prank(CheatTarget::One(velords.contract_address), blobert);
    velords.manage_lock(lock_amount, unlock_time, blobert);

    assert_eq!(lords.balance_of(blobert), balance - lock_amount, "LORDS balance mismatch after locking");
    assert_eq!(velords_token.total_supply(), lock_amount, "total supply mismatch after locking");
    // TODO
    // assert_eq!(velords_token.balance_of(blobert), lock_amount, "veLORDS balance mismatch after locking");

    let lock: Lock = velords.get_lock_for(blobert);
    assert_eq!(lock.amount, lock_amount.try_into().unwrap(), "lock amount mismatch");
    assert_eq!(lock.end_time, common::floor_to_week(capped_unlock_time), "unlock time mismatch");
}

#[test]
#[should_panic(expected: "must lock amount greater than zero")]
fn test_create_new_lock_zero_amount_fail() {
    let velords = IVEDispatcher { contract_address: common::deploy_velords() };
    let blobert: ContractAddress = common::blobert();

    start_warp(CheatTarget::All, common::TS);
    start_prank(CheatTarget::One(velords.contract_address), blobert);

    let now = get_block_timestamp();
    let unlock_time: u64 = now + common::YEAR;

    velords.manage_lock(0, unlock_time, blobert);
}

#[test]
#[should_panic(expected: "must set unlock time")]
fn test_create_new_lock_unlock_time_zero_fail() {
    let velords = IVEDispatcher { contract_address: common::deploy_velords() };
    let blobert: ContractAddress = common::blobert();

    start_warp(CheatTarget::All, common::TS);
    start_prank(CheatTarget::One(velords.contract_address), blobert);

    let lock_amount: u256 = 100_000 * common::ONE;

    velords.manage_lock(lock_amount, 0, blobert);
}

#[test]
#[should_panic(expected: "unlock time must be in the future")]
fn test_create_new_lock_in_past_fail() {
    let velords = IVEDispatcher { contract_address: common::deploy_velords() };
    let blobert: ContractAddress = common::blobert();

    start_warp(CheatTarget::All, common::TS);
    start_prank(CheatTarget::One(velords.contract_address), blobert);

    let now = get_block_timestamp();
    let unlock_time: u64 = now - common::YEAR;

    velords.manage_lock(0, unlock_time, blobert);
}

#[test]
#[should_panic(expected: "can create a lock only for oneself")]
fn test_create_new_lock_for_others_fail() {
    let velords = IVEDispatcher { contract_address: common::deploy_velords() };
    let blobert: ContractAddress = common::blobert();
    let badguy: ContractAddress = common::badguy();

    start_warp(CheatTarget::All, common::TS);
    start_prank(CheatTarget::One(velords.contract_address), badguy);

    let lock_amount: u256 = 100_000 * common::ONE;
    let now = get_block_timestamp();
    let unlock_time: u64 = now + common::YEAR;

    velords.manage_lock(lock_amount, unlock_time, blobert);
}

    // test modifying lock
    //   pass w/ new amount and new time
    //   fail when shortening lock time
    //   fail modifying expired
    //   pass when modifying amount for someone else
    //   fail when modifying time for someone else
    //   fail on expired

use lordship::velords::{Lock, Point};
use starknet::ContractAddress;

#[starknet::interface]
pub trait IVE<TContractState> {
    // TODO: getters
    // TODO: docs

    //
    // getters
    //

    fn get_lock_for(self: @TContractState, owner: ContractAddress) -> Lock;
    fn get_last_point(self: @TContractState, owner: ContractAddress) -> Point;
    fn find_epoch_by_timestamp(self: @TContractState, owner: ContractAddress, ts: u64) -> u64;
    fn balance_of_at(self: @TContractState, owner: ContractAddress, ts: u64) -> u256;


    //
    // modifiers
    //

    fn manage_lock(ref self: TContractState, amount: u256, unlock_time: u64, owner: ContractAddress);
    fn checkpoint(ref self: TContractState);
    fn withdraw(ref self: TContractState) -> (u128, u128);

    //
    // votingYFI

    // TODO: these:
    // getPriorVotes(address, uint256) -> uint256
    // totalSupply
    // totalSupplyAt
    // token -> ERC20
    // public variables getters
}

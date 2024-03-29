// TODO: SRC5
//       getters for storage vars
//       compare VotingYFI with veANGLE.vy & crv VotingEscrow.vy
//       test suite

// TODO: in VotingYFI/veANGLE it's LockedBalance.amount is int128, why? why not uint128?
//       we're using uint128, can the locked balance be negative?

// TODO: doc comments everywhere

// TODO: packing
#[derive(Copy, Default, Drop, Serde, starknet::Store)]
pub struct Lock {
    pub amount: u128,
    pub end_time: u64,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
pub struct Point {
    pub bias: i128,
    pub slope: i128, // dweight / dt
    pub ts: u64,
    pub block: u64
}

// TODO: rm once signed integers defaults are in Cairo
impl PointDefault of Default<Point> {
    fn default() -> Point {
        Point { bias: 0, slope: 0, ts: 0, block: 0 }
    }
}


#[starknet::contract]
mod velords {
    use core::cmp::{min, max};
    use core::num::traits::Zero;
    use lordship::interfaces::IERC20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use lordship::interfaces::IVE::IVE;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use starknet::{ClassHash, ContractAddress, contract_address_const, get_caller_address, get_block_number, get_block_timestamp, get_contract_address};
    use super::{Lock, Point};

    const LORDS_TOKEN: felt252 = 0x124aeb495b947201f5fac96fd1138e326ad86195b98df6dec9009158a533b49;
    const SCALE: u64 = 1000000000000000000; // 10 ** 18
    const WEEK: u64 = 3600 * 24 * 7;
    const MAX_LOCK_DURATION: u64 = 4 * 365 * 86400; // 4 years
    const MAX_N_WEEKS: u64 = 210;
    const MAX_PENALTY_RATIO: u128 = 750000000000000000; // 75% of SCALE

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    #[abi(embed_v0)]
    impl OwnableTwoStepImpl = OwnableComponent::OwnableTwoStepImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,

        // TODO: better docstrings

        balances: LegacyMap<ContractAddress, u256>,
        supply: u128,

        // owner -> lock details
        locked: LegacyMap<ContractAddress, Lock>,
        // 0,1,2...
        epoch: LegacyMap<ContractAddress, u64>,
        // (address, epoch) -> Point
        point_history: LegacyMap<(ContractAddress, u64), Point>,
        // (address, epoch) -> signed slope change
        slope_changes: LegacyMap<(ContractAddress, u64), i128>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event
    }

    // TODO: events

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        self.ownable.initializer(owner);
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.ownable.assert_only_owner();
            self.upgradeable._upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl IERC20Impl of IERC20<ContractState> {
        fn name(self: @ContractState) -> ByteArray {
            "Voting LORDS"
        }

        fn symbol(self: @ContractState) -> ByteArray {
            "veLORDS"
        }

        fn decimals(self: @ContractState) -> u8 {
            18
        }

        fn total_supply(self: @ContractState) -> u256 {
            //self.supply.read().into()
            self.balance_of_at(get_contract_address(), get_block_timestamp()) // TODO: verify, is this correct?
        }

        fn totalSupply(self: @ContractState) -> u256 {
            self.total_supply()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balance_of_at(account, get_block_timestamp())
        }

        fn balanceOf(self: @ContractState, account: ContractAddress) -> u256 {
            self.balance_of(account)
        }

        //
        // ve tokens are not transferable
        //
        fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
            0
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            false
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            panic!("veLORDS are not transferable")
        }

        fn transfer_from(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
            panic!("veLORDS are not transferable")
        }

        fn transferFrom(ref self: ContractState, sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
            panic!("veLORDS are not transferable")
        }
    }

    #[abi(embed_v0)]
    impl IVEImpl of IVE<ContractState> {
        fn get_lock_for(self: @ContractState, owner: ContractAddress) -> Lock {
            self.locked.read(owner)
        }

        // get the most recently recorded point for an owner
        fn get_last_point(self: @ContractState, owner: ContractAddress) -> Point {
            let epoch: u64 = self.epoch.read(owner);
            self.point_history.read((owner, epoch))
        }

        fn find_epoch_by_timestamp(self: @ContractState, owner: ContractAddress, ts: u64) -> u64 {
            self.find_epoch_by_timestamp_internal(owner, ts, self.epoch.read(owner))
        }

        fn balance_of_at(self: @ContractState, owner: ContractAddress, ts: u64) -> u256 {
            let mut epoch: u64 = self.epoch.read(owner);
            if epoch.is_zero() {
                return 0;
            }
            if ts != get_block_timestamp() {
                epoch = self.find_epoch_by_timestamp_internal(owner, ts, epoch);
            }

            let upoint: Point = self.point_history.read((owner, epoch));
            let upoint: Point = self.replay_slope_changes(owner, @upoint, ts);
            let balance: u128 = upoint.bias.try_into().expect('point bias negative');
            balance.into()
        }

        // create or modify a lock for a user
        // supports deposits on behalf of a user
        fn manage_lock(ref self: ContractState, amount: u256, unlock_time: u64, owner: ContractAddress) {
            let amount: u128 = amount.try_into().expect('amount overflow');
            let old_lock: Lock = self.locked.read(owner);
            let mut new_lock: Lock = old_lock;
            new_lock.amount += amount;

            let caller: ContractAddress = get_caller_address();
            let now: u64 = get_block_timestamp();

            let mut unlock_week: u64 = 0;

            // only the owner can modify their own unlock time
            if caller == owner && unlock_time.is_non_zero() {
                // cap lock time to 4 years
                let unlock_time: u64 = min(now + MAX_LOCK_DURATION, unlock_time);
                unlock_week = floor_to_week(unlock_time);
                assert!(unlock_week > now, "unlock time must be in the future");
                assert!(unlock_week > old_lock.end_time, "new unlock time must be greater than current unlock time");
                new_lock.end_time = unlock_week;
            }

            // create a new lock
            if old_lock.amount.is_zero() && old_lock.end_time.is_zero() {
                assert!(caller == owner, "can create a lock only for oneself");
                assert!(amount.is_non_zero(), "must lock amount greater than zero");
                assert!(unlock_week.is_non_zero(), "must set unlock time");
            } else { // modify an existing lock
                assert!(old_lock.end_time > now, "cannot modify an expired lock");
            }

            self.supply.write(self.supply.read() + amount);
            self.locked.write(owner, new_lock);

            self.checkpoint_internal(owner, @old_lock, @new_lock);

            if amount.is_non_zero() {
                LORDS().transfer_from(caller, get_contract_address(), amount.into());
            }

            // TODO: emit events
        }

        fn checkpoint(ref self: ContractState) {
            self.checkpoint_internal(Zero::zero(), @Default::default(), @Default::default());
        }

        fn withdraw(ref self: ContractState) -> (u128, u128) {
            let caller: ContractAddress = get_caller_address();
            let locked: Lock = self.locked.read(caller);
            assert!(locked.amount.is_non_zero(), "lock not created");

            let now: u64 = get_block_timestamp();
            let penalty: u128 = if locked.end_time > now {
                let time_left: u64 = locked.end_time - now;
                let penalty_ratio: u128 = min((time_left * SCALE).into(), MAX_PENALTY_RATIO);
                locked.amount * penalty_ratio / SCALE.into()
            } else {
                0
            };

            let supply = self.supply.read();
            self.supply.write(supply - locked.amount);
            self.locked.write(caller, Default::default());

            self.checkpoint_internal(caller, @locked, @Default::default());

            // transfer
            LORDS().transfer(caller, (locked.amount - penalty).into());
            // if penalty.is_non_zero() {
                // VotingYFI burns penalty here, figure out
                // if we want to do the same - what's REWARD_POOL for?
            // }

            // TODO: emit

            (locked.amount - penalty, penalty)
        }
    }

    #[generate_trait]
    impl InternalHelpers of InternalHelpersTrait {
        fn find_epoch_by_timestamp_internal(self: @ContractState, owner: ContractAddress, ts: u64, max_epoch: u64) -> u64 {
            let mut min: u64 = 0;
            let mut max: u64 = max_epoch;
            loop { // TODO: is this loop guaranteed to terminate? the VotingYFI does 128 iterations
                if min >= max {
                    break min;
                }

                let mid: u64 = (min + max + 1) / 2;
                if self.point_history.read((owner, mid)).ts <= ts {
                    min = mid;
                } else {
                    max = mid - 1;
                }
            }
        }

        // record global and per user data to checkpoint
        fn checkpoint_internal(ref self: ContractState, owner: ContractAddress, old_lock: @Lock, new_lock: @Lock) {
            let (user_point_0, user_point_1): (Point, Point) = if owner.is_non_zero() {
                self.checkpoint_owner(owner, old_lock, new_lock)
            } else {
                (Default::default(), Default::default())
            };

            // fill point_history until t=now
            let mut last_point: Point = self.checkpoint_global();

            if owner.is_non_zero() {
                // If last point was in this block, the slope change has been applied already
                // but in such case we have 0 slope(s)
                last_point.slope += (user_point_1.slope - user_point_0.slope);
                last_point.bias += (user_point_1.bias - user_point_0.bias);
                last_point.slope = max(0, last_point.slope);
                last_point.bias = max(0, last_point.bias);
            }

            let this: ContractAddress = get_contract_address();
            let epoch: u64 = self.epoch.read(this);
            self.point_history.write((this, epoch), last_point);
        }

        fn checkpoint_owner(ref self: ContractState, owner: ContractAddress, old_lock: @Lock, new_lock: @Lock) -> (Point, Point) {
            // we don't use kinks like in VotingYFI, because the lock period is capped at 4 years

            let mut old_point: Point = self.lock_to_point(old_lock);
            let mut new_point: Point = self.lock_to_point(new_lock);

            let now: u64 = get_block_timestamp();
            let this: ContractAddress = get_contract_address();

            // schedule slope changes for the lock end
            if old_point.slope.is_non_zero() && *old_lock.end_time > now {
                let this_slope = self.slope_changes.read((this, *old_lock.end_time));
                self.slope_changes.write((this, *old_lock.end_time), this_slope + old_point.slope);
                let owner_slope = self.slope_changes.read((owner, *old_lock.end_time));
                self.slope_changes.write((owner, *old_lock.end_time), owner_slope + old_point.slope);
            }
            if new_point.slope.is_non_zero() && *new_lock.end_time > now {
                let this_slope = self.slope_changes.read((this, *new_lock.end_time));
                self.slope_changes.write((this, *new_lock.end_time), this_slope - new_point.slope);
                let owner_slope = self.slope_changes.read((owner, *new_lock.end_time));
                self.slope_changes.write((owner, *new_lock.end_time), owner_slope - new_point.slope);
            }

            let new_owner_epoch: u64 = self.epoch.read(owner) + 1;
            self.epoch.write(owner, new_owner_epoch);
            self.point_history.write((owner, new_owner_epoch), new_point);

            (old_point, new_point)
        }

        fn checkpoint_global(ref self: ContractState) -> Point {
            let now: u64 = get_block_timestamp();
            let block: u64 = get_block_number();
            let this: ContractAddress = get_contract_address();

            let mut last_point = Point { bias: 0, slope: 0, ts: now, block };
            let mut epoch: u64 = self.epoch.read(this);
            if epoch.is_non_zero() {
                last_point = self.point_history.read((this, epoch));
            }
            let mut last_checkpoint: u64 = last_point.ts;
            let initial_last_point: Point = last_point;
            let mut block_slope: u64 = 0; // dblock/dt
            if now > last_checkpoint {
                block_slope = SCALE * (block - last_point.block) / (now - last_checkpoint);
            }

            // apply weekly slope changes and record weekly global snapshots
            let mut t_i: u64 = floor_to_week(last_checkpoint);
            loop {
                t_i = min(t_i + WEEK, now);
                last_point.bias -= last_point.slope * (t_i - last_checkpoint).into();
                last_point.slope += self.slope_changes.read((this, t_i));
                last_point.bias = max(0, last_point.bias); // this can happen
                last_point.slope = max(0, last_point.slope); // this shouldn't happen
                last_checkpoint = t_i;
                last_point.ts = t_i;
                last_point.block = initial_last_point.block + block_slope * (t_i - initial_last_point.ts) / SCALE;
                epoch += 1;

                if t_i < now {
                    self.point_history.write((this, epoch), last_point);
                } else {
                    // skip last week
                    last_point.block = block;
                    break;
                }
            };

            self.epoch.write(this, epoch);
            last_point
        }

        fn lock_to_point(self: @ContractState, lock: @Lock) -> Point {
            let now: u64 = get_block_timestamp();
            let block: u64 = get_block_number();

            let mut point = Point { bias: 0, slope: 0, ts: now, block };
            if lock.amount.is_non_zero() && *lock.end_time > now {
                let slope = *lock.amount / MAX_LOCK_DURATION.into();
                point.slope = slope.try_into().expect('slope overflow');
                point.bias = (slope * (*lock.end_time - now).into()).try_into().expect('bias overflow');
            }

            point
        }

        fn replay_slope_changes(self: @ContractState, owner: ContractAddress, point: @Point, ts: u64) -> Point {
            let mut upoint: Point = *point;
            let mut t_i: u64 = floor_to_week(upoint.ts);

            let mut i = 0;
            while i < MAX_N_WEEKS {
                t_i += WEEK;
                let mut d_slope: i128 = 0;
                if t_i > ts {
                    t_i = ts;
                } else {
                    d_slope = self.slope_changes.read((owner, t_i));
                }
                upoint.bias == upoint.slope * (t_i - upoint.ts).into();
                if t_i == ts {
                    break;
                }
                upoint.slope += d_slope;
                upoint.ts = t_i;
            };

            upoint.bias = max(0, upoint.bias);
            upoint
        }
    }

    //
    // Helper utility functions
    //

    fn floor_to_week(ts: u64) -> u64 {
        (ts / WEEK) * WEEK
    }

    fn LORDS() -> IERC20Dispatcher {
        IERC20Dispatcher {
            contract_address:
                contract_address_const::<LORDS_TOKEN>()
        }
    }
}

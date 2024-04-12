// TODO: can the while loops go longer than 40 or 50?

// TODO: docs, functions and storage vars

// TODO: events

// TODO: ownable, upgradable?

#[starknet::contract]
mod dlords_reward_pool {
    use core::cmp::max;
    use core::integer::BoundedInt;
    use core::num::traits::Zero;
    use lordship::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use lordship::interfaces::IVE::{IVEDispatcher, IVEDispatcherTrait};
    use lordship::interfaces::IDLordsRewardPool::IDLordsRewardPool;
    use lordship::velords::Point; // TODO: move to a shared types file?
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    const DAY: u64 = 3600 * 24;
    const WEEK: u64 = DAY * 7;
    const TOKEN_CHECKPOINT_DEADLINE: u64 = DAY;

    #[storage]
    struct Storage {
        // TODO: docs
        dlords: IERC20Dispatcher,
        velords: IVEDispatcher,

        start_time: u64,
        time_cursor: u64,
        time_cursor_of: LegacyMap<ContractAddress, u64>,

        last_token_time: u64,
        tokens_per_week: LegacyMap<u64, u256>,

        token_last_balance: u256,
        // ve_supply key is a timestamp (week cursor)
        ve_supply: LegacyMap<u64, u256>
    }

    #[constructor]
    fn constructor(ref self: ContractState, velords: ContractAddress, dlords: ContractAddress, start_time: u64) {
        self.velords.write(IVEDispatcher { contract_address: velords });
        self.dlords.write(IERC20Dispatcher { contract_address: dlords });

        let t: u64 = floor_to_week(start_time);
        self.start_time.write(t);
        self.last_token_time.write(t);
        self.time_cursor.write(t);

        // TODO: log init event? do we want it?
    }

    #[abi(embed_v0)]
    impl IDLordsRewardPoolImpl of IDLordsRewardPool<ContractState> {
        fn get_start_time(self: @ContractState) -> u64 {
            self.start_time.read()
        }

        fn get_time_cursor(self: @ContractState) -> u64 {
            self.time_cursor.read()
        }

        fn get_time_cursor_of(self: @ContractState, account: ContractAddress) -> u64 {
            self.time_cursor_of.read(account)
        }

        fn get_last_token_time(self: @ContractState) -> u64 {
            self.last_token_time.read()
        }

        fn get_tokens_per_week(self: @ContractState, week: u64) -> u256 {
            self.tokens_per_week.read(week)
        }

        fn get_token_last_balance(self: @ContractState) -> u256 {
            self.token_last_balance.read()
        }

        fn get_ve_supply(self: @ContractState, week: u64) -> u256 {
            self.ve_supply.read(week)
        }

        fn burn(ref self: ContractState, amount: u256) {
            let caller: ContractAddress = get_caller_address();
            let this: ContractAddress = get_contract_address();
            let dlords = self.dlords.read();

            let amount: u256 = if amount == BoundedInt::max() {
                dlords.allowance(caller, this)
            } else {
                amount
            };

            if amount.is_non_zero() {
                dlords.transfer_from(caller, this, amount);
                // TODO: emit RewardReceived
                if get_block_timestamp() > self.last_token_time.read() + TOKEN_CHECKPOINT_DEADLINE {
                    self.checkpoint_token_internal();
                }
            }
        }

        fn checkpoint_token(ref self: ContractState) {
            assert!(get_block_timestamp() > self.last_token_time.read() + TOKEN_CHECKPOINT_DEADLINE, "Token checkpoint deadline not yet reached");
            self.checkpoint_token_internal();
        }

        fn checkpoint_total_supply(ref self: ContractState) {
            self.checkpoint_total_supply_internal();
        }

        fn claim(ref self: ContractState, recipient: ContractAddress) -> u256 {
            let now: u64 = get_block_timestamp();

            if now >= self.time_cursor.read() {
                self.checkpoint_total_supply_internal();
            }

            let mut last_token_time: u64 = self.last_token_time.read();
            if now > last_token_time + TOKEN_CHECKPOINT_DEADLINE {
                self.checkpoint_token_internal();
                last_token_time = now;
            }

            let amount: u256 = self.claim_internal(recipient, floor_to_week(last_token_time));
            if amount.is_non_zero() {
                self.dlords.read().transfer(recipient, amount);
                self.token_last_balance.write(self.token_last_balance.read() - amount);
            }

            amount
        }
    }

    #[generate_trait]
    impl InternalHelpers of InternalHelpersTrait {
        fn checkpoint_token_internal(ref self: ContractState) {
            let dlords_balance: u256 = self.dlords.read().balance_of(get_contract_address());
            let to_distribute: u256 = dlords_balance - self.token_last_balance.read();
            let now: u64 = get_block_timestamp();

            if to_distribute.is_zero() {
                self.last_token_time.write(now);
                // TODO: emit CheckpointToken
                return;
            }

            self.token_last_balance.write(dlords_balance);
            let mut t: u64 = self.last_token_time.read();
            let since_last: u64 = now - t;
            self.last_token_time.write(now);
            let mut this_week: u64 = floor_to_week(now);
            let mut next_week: u64 = 0;
            let mut i: u32 = 0;

            while i < 40 {
                next_week = this_week + WEEK;
                let tpw = self.tokens_per_week.read(this_week);

                if now < next_week {
                    if (since_last.is_zero() && now == t) {
                        self.tokens_per_week.write(this_week, tpw + to_distribute);
                    } else {
                        self.tokens_per_week.write(this_week, tpw + to_distribute * (now - t).into() / since_last.into());
                    }
                    break;
                } else {
                    if (since_last.is_zero() && next_week == t) {
                        self.tokens_per_week.write(this_week, tpw + to_distribute);
                    } else {
                        self.tokens_per_week.write(this_week, tpw + to_distribute * (next_week - t).into() / since_last.into());
                    }
                }

                t = next_week;
                this_week = next_week;
            }
            // TODO: log CheckpointToken
        }

        fn checkpoint_total_supply_internal(ref self: ContractState) {
            let mut t: u64 = self.time_cursor.read();
            let rounded_ts: u64 = floor_to_week(get_block_timestamp());
            let velords = self.velords.read();
            velords.checkpoint();

            let mut i: u32 = 0;
            while i < 40 {
                if t > rounded_ts {
                    break;
                }

                let epoch: u64 = velords.find_epoch_by_timestamp(velords.contract_address, t);
                let point: Point = velords.get_point_for_at(velords.contract_address, epoch);
                let mut dt: i128 = 0;
                if t > point.ts {
                    // If the point is at 0 epoch, it can actually be earlier than the first deposit
                    // then make dt 0
                    dt = t.into() - point.ts.into();
                }
                let ve_supply: u128 = (point.bias - point.slope * dt).try_into().unwrap_or(0); // unwrap_or(0) is essentially a max(value, 0)
                self.ve_supply.write(t, ve_supply.into());

                t += WEEK;
            };

            self.time_cursor.write(t);
        }

        fn claim_internal(ref self: ContractState, recipient: ContractAddress, last_token_time: u64) -> u256 {
            let mut to_distribute: u256 = 0;
            let max_user_epoch: u64 = self.velords.read().get_epoch_for(recipient);
            let start_time: u64 = self.start_time.read();

            if max_user_epoch.is_zero() {
                // no lock -> no fees
                return 0;
            }

            let mut week_cursor: u64 = self.time_cursor_of.read(recipient);
            if week_cursor.is_zero() {
                let user_point: Point = self.velords.read().get_point_for_at(recipient, 1);
                week_cursor = floor_to_week(user_point.ts + WEEK - 1);
            }

            if week_cursor >= last_token_time {
                return 0;
            }

            if week_cursor < start_time {
                week_cursor = start_time;
            }

            let mut i: u32 = 0;
            while i < 50 {
                if week_cursor >= last_token_time {
                    break;
                }
                let balance_of: u256 = self.velords.read().balance_of_at(recipient, week_cursor);
                if balance_of.is_zero() {
                    break;
                }
                to_distribute += balance_of * self.tokens_per_week.read(week_cursor) / self.ve_supply.read(week_cursor);
                week_cursor += WEEK;
            };

            self.time_cursor_of.write(recipient, week_cursor);
            // TODO: log Claimed

            to_distribute
        }
    }

    //
    // Helper utility functions
    //

    fn floor_to_week(ts: u64) -> u64 {
        (ts / WEEK) * WEEK
    }
}

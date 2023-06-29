use core::result::ResultTrait;
use starknet::{ContractAddress};

#[derive(Drop, Serde)]
struct Call {
    address: ContractAddress,
    entry_point_selector: felt252,
    calldata: Array<felt252>,
}

#[starknet::interface]
trait ITimelock<TStorage> {
    fn queue(ref self: TStorage, calls: Array<Call>) -> felt252;
    fn execute(ref self: TStorage, calls: Array<Call>);

    // Return the execution window, i.e. the start and end timestamp in which the call can be executed
    fn get_execution_window(self: @TStorage, id: felt252) -> (u64, u64);
    // Get the current owner
    fn get_owner(self: @TStorage) -> ContractAddress;

    // Returns the delay and the window for call execution
    fn get_configuration(self: @TStorage) -> (u64, u64);

    // Transfer ownership, i.e. the address that can queue and cancel calls
    fn transfer(ref self: TStorage, to: ContractAddress);
    // Configure the delay and the window for call execution
    fn configure(ref self: TStorage, delay: u64, window: u64);
}

#[starknet::contract]
mod Timelock {
    use super::{ITimelock, ContractAddress, Call};
    use hash::LegacyHash;
    use array::{ArrayTrait, SpanTrait};
    use starknet::{
        get_caller_address, get_contract_address, SyscallResult, syscalls::call_contract_syscall,
        ContractAddressIntoFelt252, get_block_timestamp
    };
    use result::{ResultTrait};
    use traits::{Into};
    use zeroable::{Zeroable};

    #[storage]
    struct Storage {
        owner: ContractAddress,
        delay: u64,
        window: u64,
        execution_started: LegacyMap<felt252, u64>,
        executed: LegacyMap<felt252, u64>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, delay: u64, window: u64) {
        self.owner.write(owner);
        self.delay.write(delay);
        self.window.write(window);
    }

    // Take a list of calls and convert it to a unique identifier for the execution
    // Two lists of calls will always have the same ID if they are equivalent
    // A list of calls can only be queued and executed once. To make 2 different calls, add an empty call.
    fn to_id(calls: @Array<Call>) -> felt252 {
        let mut state = 0;
        let mut span = calls.span();
        loop {
            match span.pop_front() {
                Option::Some(call) => {
                    let mut data_hash = 0;

                    let mut data_span = call.calldata.span();
                    loop {
                        match data_span.pop_front() {
                            Option::Some(word) => {
                                data_hash = pedersen(state, *word);
                            },
                            Option::None(_) => {
                                break;
                            }
                        };
                    };

                    state =
                        pedersen(
                            state,
                            pedersen(
                                pedersen((*call.address).into(), *call.entry_point_selector),
                                data_hash
                            )
                        );
                },
                Option::None(_) => {
                    break state;
                }
            };
        }
    }

    #[generate_trait]
    impl TimelockInternal of TimelockInternalTrait {
        fn check_self_call(self: @ContractState) {
            assert(get_caller_address() == get_contract_address(), 'SELF_CALL_ONLY');
        }
    }

    #[external(v0)]
    impl TimelockImpl of ITimelock<ContractState> {
        fn queue(ref self: ContractState, calls: Array<Call>) -> felt252 {
            assert(get_caller_address() == self.owner.read(), 'OWNER_ONLY');
            let id = to_id(@calls);
            self.execution_started.write(to_id(@calls), get_block_timestamp());
            id
        }

        fn execute(ref self: ContractState, calls: Array<Call>) {
            let id = to_id(@calls);

            assert(self.executed.read(id).is_zero(), 'ALREADY_EXECUTED');

            let (earliest, latest) = self.get_execution_window(id);
            let time_current = get_block_timestamp();

            assert(time_current >= earliest, 'TOO_EARLY');
            assert(time_current < latest, 'TOO_LATE');

            self.executed.write(id, time_current);

            // now do the execution

            let mut call_span = calls.span();
            let mut results: Array<Array<felt252>> = ArrayTrait::new();
            loop {
                match call_span.pop_front() {
                    Option::Some(call) => {
                        let result = call_contract_syscall(
                            *call.address, *call.entry_point_selector, call.calldata.span()
                        );

                        assert(result.is_ok(), 'ERROR_IN_CALL');
                    },
                    Option::None(_) => {
                        break;
                    }
                };
            };
        }

        fn get_execution_window(self: @ContractState, id: felt252) -> (u64, u64) {
            let start_time = self.execution_started.read(id);

            assert(start_time != 0, 'INVALID_ID');

            let (window, delay) = (self.get_configuration());

            let earliest = start_time + delay;
            let latest = earliest + window;

            (earliest, latest)
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn get_configuration(self: @ContractState) -> (u64, u64) {
            (self.delay.read(), self.window.read())
        }

        fn transfer(ref self: ContractState, to: ContractAddress) {
            self.check_self_call();

            self.owner.write(to);
        }

        fn configure(ref self: ContractState, delay: u64, window: u64) {
            self.check_self_call();

            self.delay.write(delay);
            self.window.write(window);
        }
    }
}

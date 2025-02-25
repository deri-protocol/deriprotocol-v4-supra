/// RewardStore module for managing B0 token rewards.
/// This module allows executors and finishers to deposit and claim rewards.
/// A user must sign a message to prove ownership of the reward before claiming.
/// The reward is stored in a `SmartTable` and can only be transferred to the recipient
/// upon verification of ownership.
module deri::reward_store {
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use supra_framework::object::{Self, ExtendRef, Object};
    use supra_framework::primary_fungible_store;
    use aptos_std::smart_table::{Self, SmartTable};

    friend deri::gateway;

    const REWARD_STORE_NAME: vector<u8> = b"deri::reward_store";

    /// zero reward balance
    const EREWARD_ZERO: u64 = 0;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct RewardStore has key {
        store: Object<FungibleStore>,
        extend_ref: ExtendRef,
        reward: SmartTable<vector<u8>, u64>
    }

    #[event]
    struct ClaimReward has drop, store {
        user_address: vector<u8>,
        recipient: address,
        reward_amount: u64
    }

    #[event]
    struct DepositReward has drop, store {
        user_address: vector<u8>,
        total_reward_amount: u64
    }

    fun init_module(deployer: &signer) {
        let constructor_ref = &object::create_named_object(deployer, REWARD_STORE_NAME);
        let token_b0 = object::address_to_object<Metadata>(@b0_token);
        let store = fungible_asset::create_store(constructor_ref, token_b0);

        move_to(
            deployer,
            RewardStore {
                store,
                extend_ref: object::generate_extend_ref(constructor_ref),
                reward: smart_table::new()
            }
        );
    }

    /// Allows a user to claim their reward.
    friend fun claim_reward(user_address: vector<u8>, recipient: address) acquires RewardStore {
        let reward_store = &mut RewardStore[@deri];
        let reward = *smart_table::borrow(&reward_store.reward, user_address);
        assert!(reward > 0, EREWARD_ZERO);

        smart_table::remove(&mut reward_store.reward, user_address);

        let store_signer = &object::generate_signer_for_extending(&reward_store.extend_ref);
        fungible_asset::transfer(
            store_signer,
            reward_store.store,
            primary_fungible_store::ensure_primary_store_exists(recipient, object::address_to_object<Metadata>(@b0_token)),
            reward
        );

        event::emit(ClaimReward {
            user_address,
            recipient,
            reward_amount: reward
        });
    }

    /// Deposits a reward into the user's balance.
    friend fun deposit_reward(user_address: vector<u8>, reward_amount: u64) acquires RewardStore {
        let reward_store = &mut RewardStore[@deri];
        let current_reward_amount = *smart_table::borrow(&reward_store.reward, user_address);

        smart_table::upsert(&mut reward_store.reward, user_address, current_reward_amount + reward_amount);

        event::emit(DepositReward {
            user_address,
            total_reward_amount: current_reward_amount + reward_amount
        });
    }
}

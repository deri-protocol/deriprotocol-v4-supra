/// RewardStore module for managing B0 token rewards.
/// This module allows executors and finishers to deposit and claim rewards.
/// A user must sign a message to prove ownership of the reward before claiming.
/// The reward is stored in a `SmartTable` and can only be transferred to the recipient
/// upon verification of ownership.
module deri::reward_store {
    use aptos_std::smart_table::{Self, SmartTable};
    use deri::global_state;
    use std::bcs;
    use std::vector;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, FungibleStore, Metadata, FungibleAsset};
    use supra_framework::object::{Self, ExtendRef, Object};

    friend deri::gateway;

    const REWARD_STORE_NAME: vector<u8> = b"deri::reward_store";

    /// zero reward balance
    const EREWARD_ZERO: u64 = 0;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct RewardStores has key {
        stores: SmartTable<Object<Metadata>, RewardStore>,
    }

    struct RewardStore has store {
        store: Object<FungibleStore>,
        extend_ref: ExtendRef,
        reward: SmartTable<vector<u8>, u64>
    }

    #[event]
    struct ClaimReward has drop, store {
        user_address: vector<u8>,
        reward_amount: u64
    }

    #[event]
    struct DepositReward has drop, store {
        user_address: vector<u8>,
        total_reward_amount: u64
    }

    fun init_module(deri_signer: &signer) {
        move_to(
            deri_signer,
            RewardStores {
                stores: smart_table::new()
            }
        );
    }

    public(friend) fun create_reward_store(token: Object<Metadata>) acquires RewardStores {
        let reward_stores = borrow_global_mut<RewardStores>(@deri);

        let seed = REWARD_STORE_NAME;
        vector::append(&mut seed, bcs::to_bytes(&token));
        let constructor_ref = &object::create_named_object(&global_state::config_signer(), seed);
        let store = fungible_asset::create_store(constructor_ref, token);

        smart_table::add(&mut reward_stores.stores, token, RewardStore {
            store,
            extend_ref: object::generate_extend_ref(constructor_ref),
            reward: smart_table::new()
        });
    }

    /// Allows a user to claim their reward.
    public(friend) fun claim_reward(user_address: vector<u8>, token: Object<Metadata>): FungibleAsset acquires RewardStores {
        let reward_stores = borrow_global_mut<RewardStores>(@deri);
        let reward_store = smart_table::borrow_mut(&mut reward_stores.stores, token);
        let reward_amount = *smart_table::borrow(&reward_store.reward, user_address);
        assert!(reward_amount > 0, EREWARD_ZERO);

        smart_table::remove(&mut reward_store.reward, user_address);

        let store_signer = &object::generate_signer_for_extending(&reward_store.extend_ref);
        let reward_asset = fungible_asset::withdraw(
            store_signer,
            reward_store.store,
            reward_amount
        );

        event::emit(ClaimReward { user_address, reward_amount });

        reward_asset
    }

    /// Deposits a reward into the user's balance.
    public(friend) fun deposit_reward(user_address: vector<u8>, reward: FungibleAsset) acquires RewardStores {
        let reward_stores = borrow_global_mut<RewardStores>(@deri);
        let reward_asset_metadata = fungible_asset::metadata_from_asset(&reward);
        let reward_store = smart_table::borrow_mut(&mut reward_stores.stores, reward_asset_metadata);
        let reward_amount = fungible_asset::amount(&reward);
        fungible_asset::deposit(reward_store.store, reward);

        let current_reward_amount =
            if (!smart_table::contains(&reward_store.reward, user_address)) {
                smart_table::add(&mut reward_store.reward, user_address, 0);
                0
            } else {
                *smart_table::borrow(&reward_store.reward, user_address)
            };

        smart_table::upsert(&mut reward_store.reward, user_address, current_reward_amount + reward_amount);

        event::emit(
            DepositReward { user_address, total_reward_amount: current_reward_amount + reward_amount }
        );
    }

    public(friend) fun fix_liquidation_reward_error_20250425(
        token: Object<Metadata>,
        user_address: vector<u8>,
        reward_amount: u64
    ): FungibleAsset acquires RewardStores {
        let reward_stores = borrow_global_mut<RewardStores>(@deri);
        let reward_store = smart_table::borrow_mut(&mut reward_stores.stores, token);

        smart_table::remove(&mut reward_store.reward, user_address);
        let store_signer = &object::generate_signer_for_extending(&reward_store.extend_ref);
        let reward_asset = fungible_asset::withdraw(
            store_signer,
            reward_store.store,
            reward_amount
        );

        reward_asset
    }
}

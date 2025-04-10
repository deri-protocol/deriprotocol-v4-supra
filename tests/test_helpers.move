#[test_only]
module deri::test_helpers {
    use supra_framework::account;
    use supra_framework::supra_coin::{Self, SupraCoin};
    use supra_framework::coin::{Self, Coin, MintCapability};
    use supra_framework::fungible_asset::{Self, FungibleAsset, MintRef, Metadata};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::debug;
    use aptos_std::smart_table::{Self, SmartTable};
    use deri::coin_wrapper;
    use deri::gateway;
    use deri::global_state;
    use deri::iou;
    use deri::ltoken;
    use deri::ptoken;
    use std::option;
    use std::signer;
    use std::string;
    use deri::vault;
    use supra_framework::chain_id;

    struct TestCoin<phantom R> has key {
        mint_cap: MintCapability<R>
    }

    struct FungibleCap has key {
        mint_cap: SmartTable<Object<Metadata>, MintRef>
    }

    public fun setup() acquires FungibleCap {
        let deployer = deri();
        let admin = admin();

        chain_id::initialize_for_test(aptos_fx(), 10);
        let (burn_cap, mint_cap) = supra_coin::initialize_for_test(aptos_fx());

        move_to(deployer, TestCoin<SupraCoin> { mint_cap });

        // Set up b0 token
        let b0_metadata = create_fungible_asset(b"USDC", 6);

        global_state::init_for_test(deployer);
        coin_wrapper::init_for_test(deployer);
        iou::init_for_test(deployer);
        ltoken::init_for_test(deployer);
        ptoken::init_for_test(deployer);
        gateway::init_for_test(deployer, b0_metadata);
        gateway::initialize_with_fa(admin, b0_metadata);

        timestamp::set_time_has_started_for_testing(&account::create_signer_for_test(@0x1));
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);

        // add _token is b0
        let vault_b0 = vault::create_vault_for_test(b0_metadata);
        let vault_b0_addr = object::object_address(&vault_b0);
        gateway::add_b_token(
            admin,
            b0_metadata,
            vault_b0_addr,
            string::utf8(b"1"),
            1_000_000_000_000_000_000
        );
    }

    /// Prints a string on its own line.
    public fun println(str: vector<u8>) {
        debug::print(&string::utf8(str));
    }

    public inline fun deri(): &signer {
        &account::create_signer_for_test(@deri)
    }

    public inline fun admin(): &signer {
        &account::create_signer_for_test(@admin)
    }

    public inline fun get_signer(signer_address: address): &signer {
        &account::create_account_for_test(signer_address)
    }

    public inline fun aptos_fx(): &signer {
        &account::create_signer_for_test(@0x1)
    }

    public fun create_coin<CoinType>() {
        let (burn_cap, freeze_cap, mint_cap) =
            coin::initialize<CoinType>(deri(), string::utf8(b"Test"), string::utf8(b"Test"), 8, true);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
        move_to(deri(), TestCoin<CoinType> { mint_cap });
    }

    public fun mint_coin<CoinType>(amount: u64): Coin<CoinType> acquires TestCoin {
        coin::mint<CoinType>(amount, &borrow_global<TestCoin<CoinType>>(@deri).mint_cap)
    }

    public fun create_fungible_asset(name: vector<u8>, decimals: u8): Object<Metadata> acquires FungibleCap {
        if (!exists<FungibleCap>(signer::address_of(deri()))) {
            move_to(deri(), FungibleCap { mint_cap: smart_table::new() });
        };
        let token_metadata = &object::create_named_object(deri(), name);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            token_metadata,
            option::none(),
            string::utf8(name),
            string::utf8(name),
            decimals,
            string::utf8(b""),
            string::utf8(b"")
        );
        let fungible_cap = borrow_global_mut<FungibleCap>(@deri);
        let metadata = object::object_from_constructor_ref(token_metadata);
        smart_table::add(&mut fungible_cap.mint_cap, metadata, fungible_asset::generate_mint_ref(token_metadata));

        metadata
    }

    public fun mint_fungible_asset(asset: Object<Metadata>, amount: u64): FungibleAsset acquires FungibleCap {
        let fungible_cap = borrow_global<FungibleCap>(@deri);

        fungible_asset::mint(smart_table::borrow(&fungible_cap.mint_cap, asset), amount)
    }

    public fun get_b0_metadata(): Object<Metadata> {
        let (_, b0_metadata_addr, _, _, _, _, _, _, _) = gateway::get_gateway_param();
        b0_metadata_addr
    }
}

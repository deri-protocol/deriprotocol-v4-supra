/**
* @title IOU Token Contract
* @dev A Fungible asset (ERC20) token used to represent IOUs issued to traders when B0 is insufficient on a specific i-chain.
*      Traders can later redeem these IOU tokens for B0 after a rebalance operation.
*/
module deri::iou {
    use supra_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use std::option;
    use std::string::utf8;

    friend deri::gateway;

    const ASSET_NAME: vector<u8> = b"IOU Coin";
    const ASSET_SYMBOL: vector<u8> = b"IOU";

    /// TODO: update later
    const ICON_URL: vector<u8> = b"";
    const PROJECT_URL: vector<u8> = b"";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ManagedFungibleAsset has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef
    }

    fun init_module(deri_signer: &signer) {
        let constructor_ref = &object::create_named_object(deri_signer, ASSET_SYMBOL);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            utf8(ASSET_NAME),
            utf8(ASSET_SYMBOL),
            8,
            utf8(ICON_URL),
            utf8(PROJECT_URL)
        );

        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(constructor_ref);
        move_to(
            deri_signer,
            ManagedFungibleAsset { mint_ref, transfer_ref, burn_ref }
        );
    }

    #[view]
    public fun get_metadata(): Object<Metadata> {
        let asset_address = object::create_object_address(&@deri, ASSET_SYMBOL);
        object::address_to_object<Metadata>(asset_address)
    }

    public(friend) fun mint(to: address, amount: u64) acquires ManagedFungibleAsset {
        let asset = get_metadata();
        let managed_fungible_asset = borrow_global<ManagedFungibleAsset>(@deri);
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&managed_fungible_asset.mint_ref, amount);
        fungible_asset::deposit_with_ref(&managed_fungible_asset.transfer_ref, to_wallet, fa);
    }

    public(friend) fun burn(from: address, amount: u64) acquires ManagedFungibleAsset {
        let asset = get_metadata();
        let burn_ref = &borrow_global<ManagedFungibleAsset>(@deri).burn_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        fungible_asset::burn_from(burn_ref, from_wallet, amount);
    }

    #[test_only]
    public fun init_for_test(deployer: &signer) {
        init_module(deployer);
    }

    #[test_only]
    public fun mint_for_test(to: address, amount: u64) acquires ManagedFungibleAsset {
        mint(to, amount);
    }

    #[test_only]
    public fun burn_for_test(from: address, amount: u64) acquires ManagedFungibleAsset {
        burn(from, amount);
    }
}

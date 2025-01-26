/**
* @title IOU Token Contract
* @dev A Fungible asset (ERC20) token used to represent IOUs issued to traders when B0 is insufficient on a specific i-chain.
*      Traders can later redeem these IOU tokens for B0 after a rebalance operation.
*/
module deri::iou {
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, Metadata};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use std::option;
    use std::string::utf8;
    use deri::global_state;

    friend deri::gateway;

    const ASSET_NAME: vector<u8> = b"IOU Coin";
    const ASSET_SYMBOL: vector<u8> = b"IOU";

    /// TODO: update later
    const ICON_URL: vector<u8> = b"";
    const PROJECT_URL: vector<u8> = b"";

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct ManagedFungibleAsset has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef
    }

    fun init_module(_deployer: &signer) {
        let constructor_ref =
            &object::create_named_object(&global_state::config_signer(), ASSET_SYMBOL);
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
        let metadata_object_signer = object::generate_signer(constructor_ref);
        move_to(
            &metadata_object_signer,
            ManagedFungibleAsset { mint_ref, transfer_ref, burn_ref }
        );
    }

    #[view]
    public fun get_metadata(): Object<Metadata> {
        let asset_address = object::create_object_address(&@deri, ASSET_SYMBOL);
        object::address_to_object<Metadata>(asset_address)
    }

    friend fun mint(to: address, amount: u64) acquires ManagedFungibleAsset {
        let asset = get_metadata();
        let managed_fungible_asset = &ManagedFungibleAsset[object::object_address(&asset)];
        let to_wallet = primary_fungible_store::ensure_primary_store_exists(to, asset);
        let fa = fungible_asset::mint(&managed_fungible_asset.mint_ref, amount);
        fungible_asset::deposit_with_ref(&managed_fungible_asset.transfer_ref, to_wallet, fa);
    }

    friend fun burn(from: address, amount: u64) acquires ManagedFungibleAsset {
        let asset = get_metadata();
        let burn_ref = &ManagedFungibleAsset[object::object_address(&asset)].burn_ref;
        let from_wallet = primary_fungible_store::primary_store(from, asset);
        fungible_asset::burn_from(burn_ref, from_wallet, amount);
    }
}

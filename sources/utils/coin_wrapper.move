module deri::coin_wrapper {
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::supra_account;
    use supra_framework::coin::{Self, Coin};
    use supra_framework::fungible_asset::{Self, BurnRef, FungibleAsset, Metadata, MintRef, TransferRef};
    use supra_framework::object::{Self, Object};
    use supra_framework::primary_fungible_store;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::string_utils;
    use aptos_std::type_info;
    use deri::global_state;
    use std::option;
    use std::string::{Self, String};

    friend deri::gateway;

    const COIN_WRAPPER_NAME: vector<u8> = b"deri::COIN_WRAPPER";

    struct FungibleAssetData has store {
        metadata: Object<Metadata>,
        burn_ref: BurnRef,
        mint_ref: MintRef,
        transfer_ref: TransferRef
    }

    struct WrapperAccount has key {
        signer_cap: SignerCapability,
        coin_to_fungible_asset: SmartTable<String, FungibleAssetData>,
        fungible_asset_to_coin: SmartTable<Object<Metadata>, String>
    }

    /// Create the coin wrapper account to host all the deposited coins.
    fun init_module(_account: &signer) {
        let (coin_wrapper_signer, signer_cap) =
            account::create_resource_account(&global_state::config_signer(), COIN_WRAPPER_NAME);

        move_to(
            &coin_wrapper_signer,
            WrapperAccount {
                signer_cap,
                coin_to_fungible_asset: smart_table::new(),
                fungible_asset_to_coin: smart_table::new()
            }
        );
    }

    #[view]
    public fun wrapper_address(): address {
        account::create_resource_address(&global_state::config_address(), COIN_WRAPPER_NAME)
    }

    #[view]
    public fun is_supported<CoinType>(): bool acquires WrapperAccount {
        let coin_type = type_info::type_name<CoinType>();
        smart_table::contains(&wrapper_account().coin_to_fungible_asset, coin_type)
    }

    #[view]
    public fun is_wrapper(metadata: Object<Metadata>): bool acquires WrapperAccount {
        smart_table::contains(&wrapper_account().fungible_asset_to_coin, metadata)
    }

    #[view]
    public fun get_coin_type(metadata: Object<Metadata>): String acquires WrapperAccount {
        *smart_table::borrow(&wrapper_account().fungible_asset_to_coin, metadata)
    }

    #[view]
    public fun get_wrapper<CoinType>(): Object<Metadata> acquires WrapperAccount {
        fungible_asset_data<CoinType>().metadata
    }

    #[view]
    public fun get_original(fungible_asset: Object<Metadata>): String acquires WrapperAccount {
        if (is_wrapper(fungible_asset)) {
            get_coin_type(fungible_asset)
        } else {
            format_fungible_asset(fungible_asset)
        }
    }

    public fun format_coin<CoinType>(): String {
        type_info::type_name<CoinType>()
    }

    public fun format_fungible_asset(fungible_asset: Object<Metadata>): String {
        let fa_address = object::object_address(&fungible_asset);
        // This will create "@0x123"
        let fa_address_str = string_utils::to_string(&fa_address);
        // We want to strip the prefix "@"
        string::sub_string(&fa_address_str, 1, string::length(&fa_address_str))
    }

    public(friend) fun wrap<CoinType>(coins: Coin<CoinType>): FungibleAsset acquires WrapperAccount {
        // Ensure the corresponding fungible asset has already been created.
        create_fungible_asset<CoinType>();

        let amount = coin::value(&coins);
        supra_account::deposit_coins(wrapper_address(), coins);
        let mint_ref = &fungible_asset_data<CoinType>().mint_ref;
        fungible_asset::mint(mint_ref, amount)
    }

    public(friend) fun unwrap<CoinType>(fa: FungibleAsset): Coin<CoinType> acquires WrapperAccount {
        let amount = fungible_asset::amount(&fa);
        let burn_ref = &fungible_asset_data<CoinType>().burn_ref;
        fungible_asset::burn(burn_ref, fa);
        coin::withdraw(coin_wrapper_signer(), amount)
    }

    public(friend) fun create_fungible_asset<CoinType>(): Object<Metadata> acquires WrapperAccount {
        let wrapper_signer = coin_wrapper_signer();
        let coin_type = format_coin<CoinType>();
        let wrapper_account = mut_wrapper_account();
        let coin_to_fungible_asset = &mut wrapper_account.coin_to_fungible_asset;
        if (!smart_table::contains(coin_to_fungible_asset, coin_type)) {
            let metadata_constructor_ref = &object::create_named_object(wrapper_signer, *string::bytes(&coin_type));
            primary_fungible_store::create_primary_store_enabled_fungible_asset(
                metadata_constructor_ref,
                // Coin doesn't have maximum supply.
                option::none(),
                // Name, symbol, and decimals come from the coin.
                coin::name<CoinType>(),
                coin::symbol<CoinType>(),
                coin::decimals<CoinType>(),
                // Coin doesn't have these fields so we'll leave them empty in the wrapper asset.
                string::utf8(b""),
                string::utf8(b"")
            );

            let mint_ref = fungible_asset::generate_mint_ref(metadata_constructor_ref);
            let burn_ref = fungible_asset::generate_burn_ref(metadata_constructor_ref);
            let transfer_ref = fungible_asset::generate_transfer_ref(metadata_constructor_ref);
            let metadata = object::object_from_constructor_ref<Metadata>(metadata_constructor_ref);

            smart_table::add(
                coin_to_fungible_asset,
                coin_type,
                FungibleAssetData { metadata, mint_ref, transfer_ref, burn_ref }
            );
            smart_table::add(&mut wrapper_account.fungible_asset_to_coin, metadata, coin_type);
        };
        smart_table::borrow(coin_to_fungible_asset, coin_type).metadata
    }

    inline fun coin_wrapper_signer(): &signer acquires WrapperAccount {
        &account::create_signer_with_capability(&wrapper_account().signer_cap)
    }

    inline fun fungible_asset_data<CoinType>(): &FungibleAssetData acquires WrapperAccount {
        let coin_type = type_info::type_name<CoinType>();
        smart_table::borrow(&wrapper_account().coin_to_fungible_asset, coin_type)
    }

    inline fun wrapper_account(): &WrapperAccount acquires WrapperAccount {
        borrow_global<WrapperAccount>(wrapper_address())
    }

    inline fun mut_wrapper_account(): &mut WrapperAccount acquires WrapperAccount {
        borrow_global_mut<WrapperAccount>(wrapper_address())
    }

    #[test_only]
    public fun init_for_test(deployer: &signer) {
        init_module(deployer);
    }
}

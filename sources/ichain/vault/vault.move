module deri::vault {
    use std::bcs;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_std::smart_table::{Self, SmartTable};
    use deri::global_state;
    use deri::coin_wrapper;
    use deri::safe_math256;

    friend deri::gateway;

    const BILLION: u256 = 1_000_000_000;
    const SCALE_DECIMALS: u8 = 18;

    /// Tiny share of init deposit
    const ETINY_SHARE_OF_INIT_DEPOSIT: u64 = 1;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Vault has key {
        // dtoken_id => st_amount
        // The 'st_amounts' represents the stake or equity held by a 'dtoken_id' within a vault
        // The portion 'st_amount/ st_total_amount' denotes the share of equity that a specific 'dtoken_id' has within this vault
        st_amounts: SmartTable<address, u256>,
        st_total_amount: u256,
        transfer_total_asset_amount: u256,
        // Asset token, e.g. DERI
        asset: Object<Metadata>,
        extend_ref: ExtendRef
    }

    #[event]
    struct VaultCreated has drop, store {
        vault: Object<Vault>,
        asset: Object<Metadata>
    }

    #[view]
    public fun get_balance<T: key>(vault: Object<Vault>, dtoken: Object<T>): u256 acquires Vault {
        let vault_address = vault_address(&vault);
        let vault = vault_data(vault);
        let st_amount = *vault.st_amounts.borrow(object::object_address(&dtoken));

        if (st_amount != 0 && vault.st_total_amount != 0) {
            (primary_fungible_store::balance(vault_address, vault.asset) as u256) * st_amount / vault.st_total_amount
        } else { 0 }
    }

    #[view]
    public fun st_amounts<T: key>(vault: Object<Vault>, dtoken: Object<T>): u256 acquires Vault {
        let vault = vault_data(vault);
        *vault.st_amounts.borrow(object::object_address(&dtoken))
    }

    #[view]
    public fun st_total_amount(vault: Object<Vault>): u256 acquires Vault {
        let vault = vault_data(vault);
        vault.st_total_amount
    }

    #[view]
    public fun asset(vault: Object<Vault>): Object<Metadata> acquires Vault {
        let vault = vault_data(vault);
        vault.asset
    }

    #[view]
    public fun transfer_total_asset_amount(vault: Object<Vault>): u256 acquires Vault {
        let vault = vault_data(vault);
        vault.transfer_total_asset_amount
    }

    /// Create a new vault with the given asset.
    /// Only gateway module can call friend function.
    friend fun create_vault(asset: Object<Metadata>): Object<Vault> {
        let asset_name = coin_wrapper::get_coin_type(asset);
        let vault = &object::create_named_object(&global_state::config_signer(), bcs::to_bytes(&asset_name));
        let vault_signer = object::generate_signer(vault);
        let vault_object = object::object_from_constructor_ref(vault);
        move_to(
            &vault_signer,
            Vault {
                st_amounts: smart_table::new(),
                st_total_amount: 0,
                transfer_total_asset_amount: 0,
                asset,
                extend_ref: object::generate_extend_ref(vault)
            }
        );

        event::emit(
            VaultCreated { vault: vault_object, asset }
        );

        vault_object
    }

    /// Deposit assets into the vault associated with a specific 'dtoken'.
    /// Only gateway module can call friend function.
    friend fun deposit<T: key>(
        vault: Object<Vault>, dtoken: Object<T>, asset: FungibleAsset
    ): u256 acquires Vault {
        let dtoken_address = object::object_address(&dtoken);
        let minted_ts = 0;
        let asset_decimals = fungible_asset::decimals(fungible_asset::metadata_from_asset(&asset));
        let amount = (fungible_asset::amount(&asset) as u256);
        let vault_address = vault_address(&vault);
        primary_fungible_store::deposit(vault_address, asset);

        let vault = &mut Vault[object::object_address(&vault)];
        if (vault.st_total_amount == 0) {
            minted_ts = safe_math256::rescale(amount, asset_decimals, SCALE_DECIMALS);
            assert!(minted_ts > BILLION, ETINY_SHARE_OF_INIT_DEPOSIT);
        } else {
            let amount_total = (primary_fungible_store::balance(vault_address, vault.asset) as u256);
            minted_ts = vault.st_total_amount * amount / (amount_total - amount)
        };

        // Update the staked amount for 'dTokenId' and the total staked amount
        let st_amounts = &mut vault.st_amounts;
        let st_amount = *st_amounts.borrow(dtoken_address);
        st_amount += minted_ts;
        st_amounts.upsert(dtoken_address, st_amount);
        vault.st_total_amount += minted_ts;

        minted_ts
    }

    /// Redeem staked tokens and receive assets from the vault associated with a specific 'dToken'
    /// Only gateway module can call friend function.
    friend fun redeem<T: key>(
        vault: Object<Vault>, dtoken: Object<T>, amount: u256
    ): FungibleAsset acquires Vault {
        let dtoken_address = object::object_address(&dtoken);
        let redeemed_amount = 0;
        let vault_address = vault_address(&vault);
        let vault = &mut Vault[object::object_address(&vault)];
        let st_amount = *vault.st_amounts.borrow(dtoken_address);

        if (st_amount == 0) {
            return fungible_asset::zero(vault.asset)
        };

        let amount_total = (primary_fungible_store::balance(vault_address, vault.asset) as u256);
        let available_amount = amount_total * st_amount / vault.st_total_amount;
        redeemed_amount = if (amount < available_amount) amount else available_amount;

        if (redeemed_amount < available_amount
            && redeemed_amount * 10000 >= available_amount * 9999) {
            // prevent tiny share left over
            redeemed_amount = available_amount
        };

        // Calculate the staked tokens burned ('burnedSt') based on changes in the total asset balance
        let burned_st = if (redeemed_amount == available_amount) {
            st_amount
        } else {
            safe_math256::div_rounding_up(
                vault.st_total_amount * redeemed_amount, amount_total
            )
        };

        // Update the staked amount for 'dTokenId' and the total staked amount
        let st_amount = *vault.st_amounts.borrow_mut(dtoken_address);
        st_amount -= burned_st;

        primary_fungible_store::withdraw(
            &object::generate_signer_for_extending(&vault.extend_ref),
            vault.asset,
            (redeemed_amount as u64)
        )
    }

    inline fun vault_data<T: key>(vault: Object<T>): &Vault {
        &Vault[object::object_address(&vault)]
    }

    inline fun vault_address<T: key>(vault: &Object<T>): address {
        object::object_address(vault)
    }
}

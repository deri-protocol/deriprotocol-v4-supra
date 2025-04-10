module deri::vault {
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata, FungibleAsset};
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use aptos_std::smart_table::{Self, SmartTable};
    use deri::global_state;
    use deri::safe_math256;

    friend deri::gateway;

    const BILLION: u256 = 1_000_000_000;
    const SCALE_DECIMALS: u8 = 18;

    /// Tiny share of init deposit
    const ETINY_SHARE_OF_INIT_DEPOSIT: u64 = 1;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct Vault has key {
        // dtoken_id => st_amount
        // The 'st_amounts' represents the stake or equity held by a 'dtoken_id' within a vault
        // The portion 'st_amount/ st_total_amount' denotes the share of equity that a specific 'dtoken_id' has within this vault
        st_amounts: SmartTable<u256, u256>,
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
    public fun get_balance(vault: Object<Vault>, d_token_id: u256): u256 acquires Vault {
        let vault_address = object::object_address(&vault);
        let vault = vault_data(vault);
        let st_amount = *smart_table::borrow(&vault.st_amounts, d_token_id);

        if (st_amount != 0 && vault.st_total_amount != 0) {
            (primary_fungible_store::balance(vault_address, vault.asset) as u256) * st_amount / vault.st_total_amount
        } else { 0 }
    }

    #[view]
    public fun st_amounts(vault: Object<Vault>, d_token_id: u256): u256 acquires Vault {
        let vault = vault_data(vault);
        *smart_table::borrow(&vault.st_amounts, d_token_id)
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
    public(friend) fun create_vault(asset: Object<Metadata>): Object<Vault> {
        let vault = &object::create_object(global_state::config_address());
        let vault_signer = object::generate_signer(vault);
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
        let vault_object = object::object_from_constructor_ref(vault);

        event::emit(VaultCreated { vault: vault_object, asset });

        vault_object
    }

    /// Deposit assets into the vault associated with a specific 'dtoken'.
    /// Only gateway module can call friend function.
    public(friend) fun deposit(vault: Object<Vault>, d_token_id: u256, asset: FungibleAsset): u256 acquires Vault {
        let minted_ts;
        let asset_decimals = fungible_asset::decimals(fungible_asset::metadata_from_asset(&asset));
        let amount = (fungible_asset::amount(&asset) as u256);
        let vault_address = object::object_address(&vault);
        primary_fungible_store::deposit(vault_address, asset);

        let vault = borrow_global_mut<Vault>(object::object_address(&vault));

        if (vault.st_total_amount == 0) {
            minted_ts = safe_math256::rescale(amount, asset_decimals, SCALE_DECIMALS);
            assert!(minted_ts > BILLION, ETINY_SHARE_OF_INIT_DEPOSIT);
        } else {
            let amount_total = (primary_fungible_store::balance(vault_address, vault.asset) as u256);
            minted_ts = vault.st_total_amount * amount / (amount_total - amount)
        };

        // Update the staked amount for 'dTokenId' and the total staked amount
        let st_amounts = &mut vault.st_amounts;
        let st_amount = *smart_table::borrow_with_default(st_amounts, d_token_id, &0);
        st_amount = st_amount + minted_ts;
        smart_table::upsert(st_amounts, d_token_id, st_amount);
        vault.st_total_amount = vault.st_total_amount + minted_ts;

        minted_ts
    }

    /// Redeem staked tokens and receive assets from the vault associated with a specific 'dToken'
    /// Only gateway module can call friend function.
    public(friend) fun redeem(vault: Object<Vault>, d_token_id: u256, amount: u256): FungibleAsset acquires Vault {
        let redeemed_amount;
        let vault_address = object::object_address(&vault);
        let vault = borrow_global_mut<Vault>(object::object_address(&vault));
        let st_amount = *smart_table::borrow(&vault.st_amounts, d_token_id);

        if (st_amount == 0) {
            return fungible_asset::zero(vault.asset)
        };

        let amount_total = (primary_fungible_store::balance(vault_address, vault.asset) as u256);
        let available_amount = amount_total * st_amount / vault.st_total_amount;
        redeemed_amount = if (amount < available_amount) amount else available_amount;

        if (redeemed_amount < available_amount && redeemed_amount * 10000 >= available_amount * 9999) {
            // prevent tiny share left over
            redeemed_amount = available_amount
        };

        // Calculate the staked tokens burned ('burnedSt') based on changes in the total asset balance
        let burned_st =
            if (redeemed_amount == available_amount) {
                st_amount
            } else {
                safe_math256::div_rounding_up(vault.st_total_amount * redeemed_amount, amount_total)
            };

        // Update the staked amount for 'dTokenId' and the total staked amount
        let st_amount = *smart_table::borrow_mut(&mut vault.st_amounts, d_token_id);
        st_amount = st_amount - burned_st;
        smart_table::upsert(&mut vault.st_amounts, d_token_id, st_amount);
        vault.st_total_amount = vault.st_total_amount - burned_st;

        primary_fungible_store::withdraw(
            &object::generate_signer_for_extending(&vault.extend_ref),
            vault.asset,
            (redeemed_amount as u64)
        )
    }

    inline fun vault_data<T: key>(vault: Object<T>): &Vault {
        borrow_global<Vault>(object::object_address(&vault))
    }

    #[test_only]
    public fun create_vault_for_test(asset: Object<Metadata>): Object<Vault> {
        create_vault(asset)
    }

    #[test_only]
    public fun deposit_for_test(vault: Object<Vault>, d_token_id: u256, asset: FungibleAsset): u256 acquires Vault {
        deposit(vault, d_token_id, asset)
    }

    #[test_only]
    public fun redeem_for_test(vault: Object<Vault>, d_token_id: u256, amount: u256): FungibleAsset acquires Vault {
        redeem(vault, d_token_id, amount)
    }
}

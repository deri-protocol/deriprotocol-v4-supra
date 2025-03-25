#[test_only]
module deri::vault_tests {
    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;
    use deri::vault::Vault;
    use deri::gateway::get_vault_b0_address;
    use deri::test_helpers;
    use deri::vault;
    use deri::test_helpers::setup;

    #[test]
    fun test_deposit_vault_should_work() {
        setup();

        let b0_metadata = test_helpers::get_b0_metadata();
        let vault_addr = get_vault_b0_address();
        let vault_object = object::address_to_object<Vault>(vault_addr);

        let deposit_amount = 100;
        let b0_deposit_asset = test_helpers::mint_fungible_asset(b0_metadata, deposit_amount);

        vault::deposit_for_test(vault_object, 0, b0_deposit_asset);
        assert!(vault::get_balance(vault_object, 0) == (deposit_amount as u256));
        assert!(primary_fungible_store::balance(vault_addr, b0_metadata) == deposit_amount);

        let b0_deposit_asset2 = test_helpers::mint_fungible_asset(b0_metadata, deposit_amount);
        vault::deposit_for_test(vault_object, 0, b0_deposit_asset2);
        assert!(
            vault::get_balance(vault_object, 0) == (deposit_amount * 2 as u256)
        );
    }

    #[test]
    fun test_redeem_vault_should_work() {
        setup();

        let b0_metadata = test_helpers::get_b0_metadata();
        let vault_addr = get_vault_b0_address();
        let vault_object = object::address_to_object<Vault>(vault_addr);

        let deposit_amount = 100;
        let b0_deposit_asset = test_helpers::mint_fungible_asset(b0_metadata, deposit_amount);

        vault::deposit_for_test(vault_object, 0, b0_deposit_asset);

        let redeem_amount = 50;
        let redeem_asset = vault::redeem_for_test(vault_object, 0, redeem_amount as u256);

        assert!(fungible_asset::amount(&redeem_asset) == redeem_amount);
        assert!(
            vault::get_balance(vault_object, 0) == ((deposit_amount - redeem_amount) as u256)
        );
        assert!(
            primary_fungible_store::balance(vault_addr, b0_metadata) == (deposit_amount - redeem_amount)
        );

        primary_fungible_store::deposit(@0xaa, redeem_asset);
        assert!(primary_fungible_store::balance(@0xaa, b0_metadata) == redeem_amount);
    }
}

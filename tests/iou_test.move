#[test_only]
module deri::iou_test {
    use supra_framework::primary_fungible_store;
    use deri::iou;
    use deri::test_helpers::setup;

    #[test]
    fun test_iou_should_work() {
        setup();

        let owner_addr = @0xaa;
        let mint_amount = 100;
        let iou_metadata = iou::get_metadata();

        assert!(primary_fungible_store::balance(owner_addr, iou_metadata) == 0);
        iou::mint_for_test(owner_addr, mint_amount);
        assert!(primary_fungible_store::balance(owner_addr, iou_metadata) == mint_amount);

        let burn_amount = 50;
        iou::burn_for_test(owner_addr, burn_amount);

        assert!(
            primary_fungible_store::balance(owner_addr, iou_metadata) == (mint_amount - burn_amount)
        );
    }
}

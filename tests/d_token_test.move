#[test_only]
module deri::d_token_test {
    use supra_framework::event;
    use supra_framework::object;
    use deri::ptoken::{Self, PTokenMinted};
    use deri::test_helpers::setup;

    #[test]
    fun test_mint_token_id_should_work() {
        setup();

        assert!(ptoken::total_minted() == 0);
        let owner_addr = @0xaa;
        let token_id = ptoken::test_mint(owner_addr);
        let ptoken = ptoken::extract_ptoken_minted_event(&event::emitted_events<PTokenMinted>()[0]);
        assert!(object::owns(ptoken, owner_addr));
        assert!(ptoken::total_minted() == 1);

        let token_address = ptoken::get_token_address(token_id);
        assert!(object::address_to_object<ptoken::PToken>(token_address) == ptoken);
    }

    #[test]
    fun test_burn_token_id_should_work() {
        setup();

        assert!(ptoken::total_minted() == 0);
        let owner_addr = @0xaa;
        let token_id = ptoken::test_mint(owner_addr);
        assert!(ptoken::total_minted() == 1);

        ptoken::test_burn(token_id);
    }
}

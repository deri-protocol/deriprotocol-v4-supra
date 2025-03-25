#[test_only]
module deri::verify_signature_tests {
    use std::vector;
    use aptos_std::debug::print;
    use deri::i256;
    use deri::gateway;
    use deri::test_helpers::setup;

    #[test]
    fun verify_valid_signature() {
        setup();

        let (_, _, d_chain_event_signer, _, _, _, _, _, _) = gateway::get_gateway_param();
        let event_data =
            x"0000000000000000000000000000950f0000000000000000000000000000066202000000000000000000a4b100000000000000000000000000000000000003090000000000000000000000000000000000000000000000218258d0997982c162ffffffffffffffffffffffffffffffffffffffffffffffb2ac634b9bfa8900660000000000000000000000000000000000000000000000000000000001312d00";
        let signature =
            x"6ebefcc0c86173408d9aee02287cc15fa0ec91a85f8886c2b3f9af8aa079d75333b156e05dd942a54f1ab1d6283e1fb544026e9e67e98210575669288d8ec6011c";
        print(&gateway::get_event_signer_address(signature, event_data));
        assert!(gateway::get_event_signer_address(signature, event_data) == d_chain_event_signer);
    }

    #[test]
    fun extract_event_data() {
        let event_data =
            x"000000000000000000000000000094cd0000000000000000000000000000002401000000000000000000a4b1000000000000000000000000000000000000004f00000000000000000000000000000000000000000000001db2b0dac23c55a000000000000000000000000000000000000000000000000005f35aecc230d87bf60000000000000000000000000000000000000000000003ea9e7896541279c0000000000000000000000000000000000000000000000000000000000000000000";

        let request_id = 12962376203119308888710328920898346478993444;
        let l_token_id = 452312848583266388373385778560718648249770263156390604487522901302855073871;
        let liquidity = 547831610000000000000;
        let last_cumulative_pnl_on_engine = 109769308786455510006;
        let cumulative_pnl_on_gateway = 18495056604000000000000;
        let remove_b_amount = 0;

        assert!(gateway::vector_to_u256(gateway::extract_event_data(event_data, 0)) == request_id);
        assert!(gateway::vector_to_u256(gateway::extract_event_data(event_data, 1)) == l_token_id);
        assert!(gateway::vector_to_u256(gateway::extract_event_data(event_data, 2)) == liquidity);
        assert!(gateway::vector_to_u256(gateway::extract_event_data(event_data, 3)) == last_cumulative_pnl_on_engine);
        assert!(gateway::vector_to_u256(gateway::extract_event_data(event_data, 4)) == cumulative_pnl_on_gateway);
        assert!(gateway::vector_to_u256(gateway::extract_event_data(event_data, 5)) == remove_b_amount);
    }

    #[test]
    fun print_extract_event_data() {
        let event_data =
            x"000000000000000000000000000097b20000000000000000000000000000001d02000000000000000000a4b100000000000000000000000000000000000004140000000000000000000000000000000000000000000000000000000000000000fffffffffffffffffffffffffffffffffffffffffffffffffcdd71868997d6250000000000000012725dd1d243aba0e75fe645cc4873f9e65afe688c928e1f21";

        for (i in 0..(vector::length(&event_data) / 32)) {
            print(
                &i256::from_uncheck(gateway::vector_to_u256(gateway::extract_event_data(event_data, i))).to_string()
            );
        };
    }
}

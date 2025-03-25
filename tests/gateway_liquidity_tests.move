#[test_only]
module deri::gateway_liquidity_tests {
    use supra_framework::event;
    use supra_framework::primary_fungible_store;
    use deri::gateway;
    use deri::test_helpers::{Self, get_b0_metadata, setup};
    use std::signer;
    use aptos_std::debug::print;
    use aptos_std::math64;
    use deri::gateway::RequestUpdateLiquidity;
    use deri::i256;

    #[test(user = @0xbabe1, user2 = @0xbabe2)]
    fun test_add_liquidity_b0_should_work(user: &signer, user2: &signer) {
        setup();

        let user_addr = signer::address_of(user);
        let b0_metadata = get_b0_metadata();
        let user_b0_total_amount = 100 * math64::pow(10, 6);
        let b0_asset = test_helpers::mint_fungible_asset(b0_metadata, user_b0_total_amount);
        primary_fungible_store::deposit(user_addr, b0_asset);

        let b0_asset = test_helpers::mint_fungible_asset(b0_metadata, user_b0_total_amount);
        primary_fungible_store::deposit(signer::address_of(user2), b0_asset);

        // request add liquidity
        let add_liquidity_amount = 50 * math64::pow(10, 6);
        gateway::request_add_liquidity(user, 0, b0_metadata, (add_liquidity_amount as u256));
        gateway::request_add_liquidity(user2, 0, b0_metadata, (add_liquidity_amount as u256));

        let events = event::emitted_events<RequestUpdateLiquidity>();
        print(&events);
        let (
            request_id, l_token_id, liquidity, last_cumulative_pnl_on_engine, cumulative_pnl_on_gateway, remove_b_amount
        ) = gateway::deserialize_request_update_liquidity_event(&events[0]);

        gateway::print_d_token_state(l_token_id);

        // finish update liquidity
        gateway::test_finish_update_liquidity(
            user,
            request_id,
            l_token_id,
            liquidity,
            i256::string_to_u256(last_cumulative_pnl_on_engine),
            i256::from_uncheck(i256::string_to_u256(cumulative_pnl_on_gateway)),
            remove_b_amount
        );
        gateway::print_d_token_state(l_token_id);

        // remove all liquidity
        gateway::request_remove_liquidity(user, l_token_id, b0_metadata, (add_liquidity_amount as u256));
        gateway::print_d_token_state(l_token_id);

        let events = event::emitted_events<RequestUpdateLiquidity>();
        print(&events);
        let (
            request_id, l_token_id, liquidity, last_cumulative_pnl_on_engine, cumulative_pnl_on_gateway, remove_b_amount
        ) = gateway::deserialize_request_update_liquidity_event(&events[2]);

        gateway::test_finish_update_liquidity(
            user,
            request_id,
            l_token_id,
            liquidity,
            i256::string_to_u256(last_cumulative_pnl_on_engine),
            i256::from_uncheck(i256::string_to_u256(cumulative_pnl_on_gateway)),
            remove_b_amount
        );
        print(&primary_fungible_store::balance(user_addr, b0_metadata));
        assert!(primary_fungible_store::balance(user_addr, b0_metadata) == user_b0_total_amount);

    }
}

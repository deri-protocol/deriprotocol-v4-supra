#[test_only]
module deri::gateway_margin_and_trade_tests {
    use supra_framework::event;
    use supra_framework::primary_fungible_store;
    use deri::gateway::{FinishAddMargin, RequestRemoveMargin, RequestTrade};
    use deri::gateway;
    use deri::test_helpers::{Self, get_b0_metadata, setup};
    use std::signer;
    use aptos_std::debug::print;
    use aptos_std::math64;
    use deri::ptoken::PTokenMinted;
    use deri::i256;

    #[test(user = @0xbabe1)]
    fun test_e2e_margin_should_work(user: &signer) {
        setup();

        let user_addr = signer::address_of(user);
        let b0_metadata = get_b0_metadata();
        let user_b0_total_amount = 100 * math64::pow(10, 6);
        let b0_asset = test_helpers::mint_fungible_asset(b0_metadata, user_b0_total_amount);
        primary_fungible_store::deposit(user_addr, b0_asset);

        let add_margin_amount = 50 * math64::pow(10, 6);

        // request add margin 50 b0
        gateway::request_add_margin(user, 0, b0_metadata, (add_margin_amount as u256), true);

        let finish_add_margin_events = event::emitted_events<FinishAddMargin>();
        print(&finish_add_margin_events);
        print(&event::emitted_events<PTokenMinted>());
        let (request_id, p_token_id, b_token, b_amount) =
            gateway::deserialize_finish_add_margin_event(&finish_add_margin_events[0]);
        gateway::print_d_token_state(p_token_id);

        // remove margin
        let remove_margin_amount = 10 * math64::pow(10, 6);

        gateway::request_remove_margin(user, p_token_id, b0_metadata, remove_margin_amount as u256);
        let finish_remove_margin_events = event::emitted_events<RequestRemoveMargin>();
        print(&finish_remove_margin_events);

        let (
            request_id,
            p_token_id,
            real_money_margin,
            last_cumulative_pnl_on_engine,
            cumulative_pnl_on_gateway,
            b_amount_to_remove
        ) = gateway::deserialize_request_remove_margin_event(&finish_remove_margin_events[0]);

        gateway::test_finish_remove_margin(
            user,
            request_id,
            p_token_id,
            0,
            i256::from_uncheck(i256::string_to_u256(last_cumulative_pnl_on_engine)),
            b_amount_to_remove
        );

        gateway::print_d_token_state(p_token_id);
    }

    #[test(user = @0xbabe1)]
    fun test_trade(user: &signer) {
        setup();

        let user_addr = signer::address_of(user);
        let b0_metadata = get_b0_metadata();
        let user_b0_total_amount = 100 * math64::pow(10, 6);
        let b0_asset = test_helpers::mint_fungible_asset(b0_metadata, user_b0_total_amount);
        primary_fungible_store::deposit(user_addr, b0_asset);

        let add_margin_amount = 50 * math64::pow(10, 6);
        gateway::request_add_margin(user, 0, b0_metadata, (add_margin_amount as u256), true);

        let finish_add_margin_events = event::emitted_events<FinishAddMargin>();
        print(&finish_add_margin_events);
        let (request_id, p_token_id, b_token, b_amount) =
            gateway::deserialize_finish_add_margin_event(&finish_add_margin_events[0]);
        gateway::print_d_token_state(p_token_id);

        gateway::request_trade(user, p_token_id, b"ETH", vector[1, 2]);
        print(&event::emitted_events<RequestTrade>());
        gateway::print_d_token_state(p_token_id);

        gateway::request_trade(user, p_token_id, b"BTC", vector[1, 2]);
    }
}

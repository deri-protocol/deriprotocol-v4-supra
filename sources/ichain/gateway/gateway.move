module deri::gateway {
    use aptos_framework::aptos_account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, FungibleAsset, FungibleStore};
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use aptos_std::math64;
    use aptos_std::smart_table::{Self, SmartTable};
    use deri::coin_wrapper;
    use deri::global_state;
    use deri::i256::{Self, I256};
    use deri::iou;
    use deri::ltoken::{Self, LToken};
    use deri::ptoken::PToken;
    use deri::ptoken;
    use deri::safe_math256;
    use deri::vault::{Self, Vault};
    use std::error;
    use std::signer;
    use std::string::String;

    const DERI_GATEWAY_PARAM_NAME: vector<u8> = b"deri::gateway_param";
    const MAX_AS_U256: u256 = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    const SCALE_DECIMALS: u8 = 18;
    /// 1 UONE = 1e18
    const UONE: u256 = 1_000_000_000_000_000_000;
    const ZERO_ADDRESS: address = @0x0;

    // Errors

    /// The LToken ID is invalid
    const EINVALID_LTOKEN_ID: u64 = 1;
    /// The PToken ID is invalid
    const EINVALID_PTOKEN_ID: u64 = 2;
    /// Invalid BToken
    const EINVALID_BTOKEN: u64 = 3;
    /// Invalid BToken amount
    const EINVALID_BTOKEN_AMOUNT: u64 = 4;
    /// Invalid request id
    const EINVALD_REQUEST_ID: u64 = 5;
    /// Vault not found
    const ENOT_FOUND_VAULT: u64 = 6;
    /// Insufficient B0Token balance
    const EINSUFFICIENT_B0_BALANCE: u64 = 7;
    /// Insufficient execution fee
    const EINSUFFICIENT_EXECUTION_FEE: u64 = 8;
    /// Insufficient margin
    const EINSUFFICIENT_MARGIN: u64 = 9;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct GatewayStorage has key {
        gateway_state: GatewayState,
        // b_token address => state
        b_token_states: SmartTable<address, BTokenState>,
        // d_token address => state
        d_token_states: SmartTable<u256, DTokenState>,
        // actionId => executionFee
        execution_fees: ExecutionFee
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct GatewayParam has key {
        // Vault for holding reserved B0, used for payments on regular bases
        vault0: address,
        // B0, settlement base token, e.g. USDC native
        token_b0: Object<Metadata>,
        d_chain_event_signer: address,
        b0_reserve_ratio: u256,
        liquidation_reward_cut_ratio: I256,
        min_liquidation_reward: I256,
        max_liquidation_reward: I256,
        protocol_fee_manager: address,
        liq_claim: address,
        gateway_stores: SmartTable<Object<Metadata>, GatewayStore>,
    }

    /// Data regarding the store object for a specific fungible asset.
    struct GatewayStore has store {
        store: Object<FungibleStore>,
        store_extend_ref: ExtendRef,
    }

    struct GatewayState has store, drop, copy {
        vaults: vector<address>,
        // Cumulative pnl on Gateway
        cumulative_pnl_on_gateway: I256,
        // Last timestamp when liquidity updated
        liquidity_time: u256,
        // Total liquidity on d chain
        total_liquidity: u256,
        // Cumulavie time per liquidity
        cumulative_time_per_liquidity: I256,
        // Gateway request id
        gateway_request_id: u256,
        // dChain execution fee for executing request on dChain
        d_chain_execution_fee_per_request: u256,
        // Total iChain execution fee paid by all requests
        total_i_chain_execution_fee: u256,
        // Cumulative collected protocol fee on Gateway
        cumulative_collected_protocol_fee: u256
    }

    struct BTokenState has store, drop, copy {
        // BToken vault address
        vault: address,
        // BToken oracle id
        oracle_id: String,
        // BToken collateral factor
        collateral_factor: u256
    }

    struct DTokenState has store, drop, copy {
        // Lp/Trader request id
        request_id: u256,
        // Lp/Trader bToken
        b_token: Object<Metadata>,
        // Lp/Trader b0Amount
        b0_amount: I256,
        // Lp/Trader last cumulative pnl on engine
        last_cumulative_pnl_on_engine: I256,
        // Lp liquidity
        liquidity: u256,
        // Lp cumulative time
        cumulative_time: u256,
        // Lp last cumulative time per liquidity
        last_cumulative_time_per_liquidity: u256,
        // Td single position flag
        single_position: bool,
        // User last request's iChain execution fee
        last_request_i_chain_execution_fee: u256,
        // User cumulaitve iChain execution fee for requests cannot be finished, users can claim back
        cumulative_unused_i_chain_execution_fee: u256,
        current_operate_token: address
    }

    struct ExecutionFee has store, drop, copy {
        request_add_liquidity: u256,
        request_remove_liquidity: u256,
        request_remove_margin: u256,
        request_trade: u256,
        request_trade_and_remove_margin: u256
    }

    // struct holding intermediate values passed around functions
    struct Data has store, drop, copy {
        // Lp/Trader account address
        account: address,
        // Lp/Trader dTokenId
        d_token_id: u256,
        // Lp/Trader bToken address
        b_token: Object<Metadata>,
        // cumulative pnl on Gateway
        cumulative_pnl_on_gateway: I256,
        // Lp/Trader bToken's vault address
        vault: address,
        // Lp/Trader b0Amount
        b0_amount: I256,
        // Lp/Trader last cumulative pnl on engine
        last_cumulative_pnl_on_engine: I256,
        // bToken collateral factor
        collateral_factor: u256,
        // bToken price
        b_price: u256
    }

    #[event]
    struct AddBToken has drop, store {
        b_token: address,
        vault: address,
        oracle_id: String,
        collateral_factor: u256
    }

    #[event]
    struct SetExecutionFee has drop, store {
        request_add_liquidity: u256,
        request_remove_liquidity: u256,
        request_remove_margin: u256,
        request_trade: u256,
        request_trade_and_remove_margin: u256
    }

    #[event]
    struct RequestUpdateLiquidty has drop, store {
        request_id: u256,
        l_token_id: u256,
        liquidity: u256,
        last_cumulative_pnl_on_engine: String,
        cumulative_pnl_on_gateway: String,
        remove_b_amount: u256
    }

    #[event]
    struct FinishAddLiquidity has drop, store {
        request_id: u256,
        l_token_id: u256,
        liquidity: u256,
        total_liquidity: u256
    }

    #[event]
    struct FinishRemoveLiquidity has drop, store {
        request_id: u256,
        l_token_id: u256,
        liquidity: u256,
        total_liquidity: u256,
        b_token: address,
        b_amount: u256
    }

    #[event]
    struct FinishAddMargin has drop, store {
        request_id: u256,
        p_token_id: u256,
        b_token: address,
        b_amount: u256
    }

    #[event]
    struct RequestREmoveMargin has drop, store {
        request_id: u256,
        p_token_id: u256,
        real_money_margin: u256,
        last_cumulative_pnl_on_engine: String,
        cumulative_pnl_on_gateway: String,
        b_amount: u256
    }

    #[event]
    struct FinishRemoveMargin has drop, store {
        request_id: u256,
        p_token_id: u256,
        b_token: address,
        b_amount: u256
    }

    #[event]
    struct RequestTrade has drop, store {
        request_id: u256,
        p_token_id: u256,
        real_money_margin: u256,
        last_cumulative_pnl_on_engine: String,
        cumulative_pnl_on_gateway: String,
        symbol_id: vector<u8>,
        trade_params: vector<String>
    }

    #[event]
    struct RequestLiquidate has drop, store {
        request_id: u256,
        p_token_id: u256,
        real_money_margin: u256,
        last_cumulative_pnl_on_engine: String,
        cumulative_pnl_on_gateway: String,
    }

    #[event]
    struct RequestTradeAndRemoveMargin has drop, store {
        request_id: u256,
        p_token_id: u256,
        real_money_margin: u256,
        last_cumulative_pnl_on_engine: String,
        cumulative_pnl_on_gateway: String,
        b_amount: u256,
        symbol_id: vector<u8>,
        trade_params: vector<String>,
    }

    #[event]
    struct FinishLiquidate has drop, store {
        request_id: u256,
        p_token_id: u256,
        lp_pnl: String,
    }

    fun init_module(deployer: &signer) {
        move_to(
            deployer,
            GatewayStorage {
                gateway_state: GatewayState {
                    vaults: vector[],
                    cumulative_pnl_on_gateway: i256::zero(),
                    liquidity_time: 0,
                    total_liquidity: 0,
                    cumulative_time_per_liquidity: i256::zero(),
                    gateway_request_id: 0,
                    d_chain_execution_fee_per_request: 0,
                    total_i_chain_execution_fee: 0,
                    cumulative_collected_protocol_fee: 0
                },
                b_token_states: smart_table::new(),
                d_token_states: smart_table::new(),
                execution_fees: ExecutionFee {
                    request_add_liquidity: 0,
                    request_remove_liquidity: 0,
                    request_remove_margin: 0,
                    request_trade: 0,
                    request_trade_and_remove_margin: 0
                }
            }
        );
    }

    #[view]
    public fun get_gateway_param(): (
        address,
        Object<Metadata>,
        address,
        u256,
        String,
        String,
        String,
        address,
        address
    ) acquires GatewayParam {
        let gateway_param = &GatewayParam[@deri];
        (
            gateway_param.vault0,
            gateway_param.token_b0,
            gateway_param.d_chain_event_signer,
            gateway_param.b0_reserve_ratio,
            gateway_param.liquidation_reward_cut_ratio.to_string(),
            gateway_param.min_liquidation_reward.to_string(),
            gateway_param.max_liquidation_reward.to_string(),
            gateway_param.protocol_fee_manager,
            gateway_param.liq_claim
        )
    }

    #[view]
    public fun get_gateway_state(): (
        vector<address>,
        String,
        u256,
        u256,
        String,
        u256,
        u256,
        u256,
        u256
    ) acquires GatewayStorage {
        let gateway_storage = &GatewayStorage[@deri].gateway_state;
        (
            gateway_storage.vaults,
            gateway_storage.cumulative_pnl_on_gateway.to_string(),
            gateway_storage.liquidity_time,
            gateway_storage.total_liquidity,
            gateway_storage.cumulative_time_per_liquidity.to_string(),
            gateway_storage.gateway_request_id,
            gateway_storage.d_chain_execution_fee_per_request,
            gateway_storage.total_i_chain_execution_fee,
            gateway_storage.cumulative_collected_protocol_fee
        )
    }

    #[view]
    public fun get_b_token_state(b_token: Object<Metadata>): (address, String, u256) acquires GatewayStorage {
        let gateway_storage = &GatewayStorage[@deri];
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&b_token));
        (
            b_token_state.vault,
            b_token_state.oracle_id,
            b_token_state.collateral_factor
        )
    }

    #[view]
    public fun get_lp_state(l_token_id: u256): (
        u256,
        Object<Metadata>,
        u256,
        String,
        String,
        u256,
        u256,
        u256,
        u256,
        u256,
    ) acquires GatewayStorage {
        let gateway_storage = &GatewayStorage[@deri];
        let d_token_state = gateway_storage.d_token_states.borrow(l_token_id);
        let b_token_addr = object::object_address(&d_token_state.b_token);
        let b_token_state = gateway_storage.b_token_states.borrow(b_token_addr);

        (
            d_token_state.request_id,
            d_token_state.b_token,
            vault::get_balance(object::address_to_object(b_token_state.vault), l_token_id),
            d_token_state.b0_amount.to_string(),
            d_token_state.last_cumulative_pnl_on_engine.to_string(),
            d_token_state.liquidity,
            d_token_state.cumulative_time,
            d_token_state.last_cumulative_time_per_liquidity,
            d_token_state.last_request_i_chain_execution_fee,
            d_token_state.cumulative_unused_i_chain_execution_fee
        )

    }

    #[view]
    public fun get_td_state(p_token_id: u256): (
        u256,
        Object<Metadata>,
        u256,
        String,
        String,
        bool,
        u256,
        u256
    ) acquires GatewayStorage {
        let gateway_storage = &GatewayStorage[@deri];
        let d_token_state = gateway_storage.d_token_states.borrow(p_token_id);
        let b_token_addr = object::object_address(&d_token_state.b_token);
        let b_token_state = gateway_storage.b_token_states.borrow(b_token_addr);

        (
            d_token_state.request_id,
            d_token_state.b_token,
            vault::get_balance(object::address_to_object(b_token_state.vault), p_token_id),
            d_token_state.b0_amount.to_string(),
            d_token_state.last_cumulative_pnl_on_engine.to_string(),
            d_token_state.single_position,
            d_token_state.last_request_i_chain_execution_fee,
            d_token_state.cumulative_unused_i_chain_execution_fee
        )
    }

    #[view]
    public fun get_cumulative_time(l_token_id: u256): (u256, u256) acquires GatewayStorage {
        let gateway_storage = &GatewayStorage[@deri];
        let gateway_state = &gateway_storage.gateway_state;
        let d_token_state = gateway_storage.d_token_states.borrow(l_token_id);

        get_cumulative_time_internal(gateway_state, d_token_state)
    }

    #[view]
    public fun get_execution_fee(): vector<u256> acquires GatewayStorage {
        let execution_fees = &GatewayStorage[@deri].execution_fees;
        vector[
            execution_fees.request_add_liquidity,
            execution_fees.request_remove_liquidity,
            execution_fees.request_remove_margin,
            execution_fees.request_trade,
            execution_fees.request_trade_and_remove_margin
        ]
    }

    //////////////////////// Setters ////////////////////////

    /// Initialize the gateway params with the vault0 for token_b0
    public entry fun initialize(
        admin: &signer,
        vault0_asset: Object<Metadata>,
        token_b0: Object<Metadata>,
        d_chain_event_signer: address,
        b0_reserve_ratio: u256,
        liquidation_reward_cut_ratio: u256,
        min_liquidation_reward: u256,
        max_liquidation_reward: u256,
        protocol_fee_manager: address,
        liq_claim: address
    ) acquires GatewayStorage {
        global_state::assert_is_admin(admin);

        // create vault0 for token_b0
        let vault = vault::create_vault(vault0_asset);

        let gateway_storage = &mut GatewayStorage[@deri];
        let vault_addr = object::object_address(&vault);
        gateway_storage.gateway_state.vaults.push_back(vault_addr);

        let gateway_param = &object::create_named_object(&global_state::config_signer(), DERI_GATEWAY_PARAM_NAME);
        let gateway_param_signer = &object::generate_signer(gateway_param);
        let gateway_stores = smart_table::new();
        gateway_stores.add(token_b0, create_gateway_store(token_b0));
        gateway_stores.add(get_aptos_coin_wrapper(), create_gateway_store(get_aptos_coin_wrapper()));

        move_to(
            gateway_param_signer,
            GatewayParam {
                vault0: vault_addr,
                token_b0,
                d_chain_event_signer,
                b0_reserve_ratio,
                liquidation_reward_cut_ratio: i256::from(liquidation_reward_cut_ratio),
                min_liquidation_reward: i256::from(min_liquidation_reward),
                max_liquidation_reward: i256::from(max_liquidation_reward),
                protocol_fee_manager,
                liq_claim,
                gateway_stores
            }
        );
    }

    /// Create vault implementation none
    public entry fun create_vault(admin: &signer, vault_asset: Object<Metadata>) acquires GatewayStorage {
        global_state::assert_is_admin(admin);

        let gateway_storage = &mut GatewayStorage[@deri];
        let vault = vault::create_vault(vault_asset);
        gateway_storage.gateway_state.vaults.push_back(object::object_address(&vault));
    }

    public entry fun add_b_token<T: key>(
        admin: &signer,
        b_token: Object<Metadata>,
        vault: Object<T>,
        oracle_id: String,
        collateral_factor: u256
    ) acquires GatewayStorage, GatewayParam {
        global_state::assert_is_admin(admin);

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &mut GatewayParam[@deri];
        let b_token_states = &mut gateway_storage.b_token_states;

        let b_token_address = object::object_address(&b_token);
        let vault_address = object::object_address(&vault);
        assert!(gateway_storage.gateway_state.vaults.contains(&vault_address), ENOT_FOUND_VAULT);

        b_token_states.add(
            b_token_address, BTokenState { vault: vault_address, oracle_id, collateral_factor }
        );

        // create store for b_token
        gateway_param.gateway_stores.add(b_token, create_gateway_store(b_token));

        event::emit(
            AddBToken {
                b_token: b_token_address,
                vault: vault_address,
                oracle_id,
                collateral_factor
            }
        );
    }

    public entry fun del_b_token() {}

    /// This function can be used to change bToken collateral factor
    public entry fun set_b_token_parameter() {}

    /// Set execution fee for all action
    public entry fun set_execution_fee(
        admin: &signer,
        request_add_liquidity: u256,
        request_remove_liquidity: u256,
        request_remove_margin: u256,
        request_trade: u256,
        request_trade_and_remove_margin: u256
    ) acquires GatewayStorage {
        global_state::assert_is_admin(admin);

        let execution_fees = &mut GatewayStorage[@deri].execution_fees;
        execution_fees.request_add_liquidity = request_add_liquidity;
        execution_fees.request_remove_liquidity = request_remove_liquidity;
        execution_fees.request_remove_margin = request_remove_margin;
        execution_fees.request_trade = request_trade;
        execution_fees.request_trade_and_remove_margin = request_trade_and_remove_margin;

        event::emit(
            SetExecutionFee {
                request_add_liquidity,
                request_remove_liquidity,
                request_remove_margin,
                request_trade,
                request_trade_and_remove_margin
            }
        );
    }

    public entry fun set_d_chain_execution_fee_per_request() {}

    /// Claim dChain executionFee to account `to`
    public entry fun claim_d_chain_execution_fee() {}

    /// Claim unused iChain execution fee for dTokenId
    public entry fun claim_unused_i_chain_execution_fee() {}

    /// Redeem B0 for burning IOU
    public entry fun redeem_IOU() {}

    //////////////////////// Interactions ////////////////////////

    public entry fun finish_collect_protocol_fee() {}

    /// Request to add liquidity with specified base token.
    public entry fun request_add_liquidity(
        user: &signer,
        l_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];
        let user_address = signer::address_of(user);
        let b_token_address = object::object_address(&b_token);
        if (l_token_id == 0) {
            l_token_id = ltoken::mint(user_address);
        } else {
            check_l_token_id_owner(l_token_id, user_address);
        };
        check_b_token_initialized(&gateway_storage.b_token_states, b_token);

        let b_token_state = gateway_storage.b_token_states.borrow(b_token_address);
        let d_token_state = gateway_storage.d_token_states.borrow_mut(l_token_id);
        let data =
            get_data_and_check_b_token_consistency(
                &gateway_storage.gateway_state,
                b_token_state,
                d_token_state,
                user_address,
                l_token_id,
                b_token
            );

        // TODO: execute fee when b token is APT? (ETH on EVM)
        if (coin_wrapper::get_wrapper<AptosCoin>() == b_token) {
            // b_amount = receive_execution_fee();
        };
        assert!(b_amount != 0, EINVALID_BTOKEN_AMOUNT);

        let b_token_asset = primary_fungible_store::withdraw(user, b_token, (b_amount as u64));
        deposit(&mut data, b_token_asset, gateway_param);
        data.get_ex_params(b_token_state, gateway_param);

        let new_liquidity = data.get_d_token_liquidity();
        data.save_data(&mut gateway_storage.gateway_state, d_token_state);
        let request_id =
            increment_request_id(
                &mut gateway_storage.gateway_state,
                d_token_state
            );

        event::emit(
            RequestUpdateLiquidty {
                request_id,
                l_token_id,
                liquidity: new_liquidity,
                last_cumulative_pnl_on_engine: data.last_cumulative_pnl_on_engine.to_string(),
                cumulative_pnl_on_gateway: data.cumulative_pnl_on_gateway.to_string(),
                remove_b_amount: 0
            }
        )
    }

    /// Request to remove liquidity with specified base token.
    public entry fun request_remove_liquidity(
        user: &signer,
        l_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let user_address = signer::address_of(user);
        let b_token_address = object::object_address(&b_token);
        check_l_token_id_owner(l_token_id, user_address);

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        let gateway_state = &mut gateway_storage.gateway_state;
        let b_token_state = gateway_storage.b_token_states.borrow(b_token_address);
        let d_token_state = gateway_storage.d_token_states.borrow_mut(l_token_id);

        // receive_execution_fee(d_token_state, gateway_state, );
        assert!(b_amount != 0, EINVALID_BTOKEN_AMOUNT);


        let data = get_data(
            &gateway_storage.gateway_state,
            b_token_state,
            d_token_state,
            user_address,
            l_token_id,
            b_token
        );

        data.get_ex_params(b_token_state, gateway_param);
        let old_liquidity = data.get_d_token_liquidity();
        let new_liquidity =
            if (data.b_token == b_token) {
                data.get_d_token_liquidity_with_remove(gateway_param, b_amount)
            } else if (b_token == gateway_param.token_b0) {
                data.get_d_token_liquidity_with_remove_b0(gateway_param, b_amount)
            } else {
                abort error::invalid_argument(EINVALID_BTOKEN)
            };

        if (new_liquidity <= old_liquidity / 100) {
            new_liquidity = 0;
        };

        let d_token_state = gateway_storage.d_token_states.borrow_mut(data.d_token_id);
        d_token_state.current_operate_token = b_token_address;
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(
            RequestUpdateLiquidty {
                request_id,
                l_token_id,
                liquidity: new_liquidity,
                last_cumulative_pnl_on_engine: data.last_cumulative_pnl_on_engine.to_string(),
                cumulative_pnl_on_gateway: data.cumulative_pnl_on_gateway.to_string(),
                remove_b_amount: b_amount
            }
        )
    }

    // Request to add margin with specified base token.
    public entry fun request_add_margin(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256,
        single_position: bool
    ) acquires GatewayStorage, GatewayParam {
        request_add_margin_internal(user, p_token_id, b_token, b_amount, single_position);
    }

    public entry fun request_add_mergin_b0(
        user: &signer,
        p_token_id: u256,
        b0_amount: u256
    ) acquires GatewayParam, GatewayStorage {
        let user_addr = signer::address_of(user);
        assert!(b0_amount > 0, EINVALID_BTOKEN_AMOUNT);
        check_p_token_id_owner(p_token_id, user_addr);
        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];
        let token_b0 = gateway_param.token_b0;

        let b0_asset = primary_fungible_store::withdraw(user, token_b0, (b0_amount as u64));
        vault::deposit(
            object::address_to_object(gateway_param.vault0),
            p_token_id,
            b0_asset
        );

        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        d_token_state.b0_amount = i256::wrapping_add(d_token_state.b0_amount, i256::from(b0_amount));
    }

    /// Request to remove margin with specified base token.
    public entry fun request_remove_margin(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        assert!(b_amount > 0, EINVALID_BTOKEN_AMOUNT);
        check_p_token_id_owner(p_token_id, user_addr);
        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        let gateway_state = &mut gateway_storage.gateway_state;
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&b_token));
        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);

        // TODO
        // _receiveExecutionFee(pTokenId, _executionFees[I.ACTION_REQUESTREMOVEMARGIN]);

        let data = get_data_and_check_b_token_consistency(
            gateway_state,
            b_token_state,
            d_token_state,
            user_addr,
            p_token_id,
            b_token
        );
        data.get_ex_params(b_token_state, gateway_param);
        let old_margin = data.get_d_token_liquidity();
        let new_margin = data.get_d_token_liquidity_with_remove(gateway_param, b_amount);
        if (new_margin <= old_margin / 100) {
            new_margin = 0;
        };
        let request_id = increment_request_id(gateway_state, d_token_state);

        event::emit(RequestREmoveMargin {
            request_id,
            p_token_id,
            real_money_margin: new_margin,
            last_cumulative_pnl_on_engine: data.last_cumulative_pnl_on_engine.to_string(),
            cumulative_pnl_on_gateway: data.cumulative_pnl_on_gateway.to_string(),
            b_amount
        })
    }

    /// Request to initiate a trade using a specified PToken, symbol identifier, and trade parameters.
    public entry fun request_trade(
        user: &signer,
        p_token_id: u256,
        symbol_id: vector<u8>,
        trade_params: vector<u256>
    ) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        check_p_token_id_owner(p_token_id, user_addr);

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        // TODO: receive_execution_fee(p_token, gateway_state, gateway_param);

        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&d_token_state.b_token));

        let data = get_data(
            &gateway_storage.gateway_state,
            b_token_state,
            d_token_state,
            user_addr,
            p_token_id,
            gateway_param.token_b0
        );
        data.get_ex_params(b_token_state, gateway_param);

        let real_money_margin = data.get_d_token_liquidity();
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);
        let trade_params_i265 = trade_params.map(|x| i256::from(x).to_string());

        event::emit(RequestTrade {
            request_id,
            p_token_id,
            real_money_margin,
            last_cumulative_pnl_on_engine: data.last_cumulative_pnl_on_engine.to_string(),
            cumulative_pnl_on_gateway: data.cumulative_pnl_on_gateway.to_string(),
            symbol_id,
            trade_params: trade_params_i265
        })
    }

    /// Request to liquidate a specified PToken.
    public entry fun request_liquidate(
        user: &signer,
        p_token_id: u256
    ) acquires GatewayStorage, GatewayParam {
        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&d_token_state.b_token));

        let data = get_data(
            &gateway_storage.gateway_state,
            b_token_state,
            d_token_state,
            ptoken::owner(p_token_id),
            p_token_id,
            gateway_param.token_b0
        );
        data.get_ex_params(b_token_state, gateway_param);

        let real_money_margin = data.get_d_token_liquidity();
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(RequestLiquidate {
            request_id,
            p_token_id,
            real_money_margin,
            last_cumulative_pnl_on_engine: data.last_cumulative_pnl_on_engine.to_string(),
            cumulative_pnl_on_gateway: data.cumulative_pnl_on_gateway.to_string(),
        })
    }

    /// Request to add margin and initiate a trade in a single transaction.
    public entry fun request_add_margin_and_trade(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256,
        symbol_id: vector<u8>,
        trade_params: vector<u256>,
        single_position: bool
    ) acquires GatewayStorage, GatewayParam {
        p_token_id = request_add_margin_internal(user, p_token_id, b_token, b_amount, single_position);
        request_trade(user, p_token_id, symbol_id, trade_params);
    }

    /// Request to initiate a trade and simultaneously remove margin from a specified PToken.
    public entry fun request_trade_and_remove_margin(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256,
        symbol_id: vector<u8>,
        trade_params: vector<u256>
    ) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        assert!(b_amount > 0, EINVALID_BTOKEN_AMOUNT);
        check_p_token_id_owner(p_token_id, user_addr);

        // TODO: receive_execution_fee(p_token, gateway_state, gateway_param);

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&b_token));

        let data = get_data(
            &gateway_storage.gateway_state,
            b_token_state,
            d_token_state,
            user_addr,
            p_token_id,
            b_token
        );
        data.get_ex_params(b_token_state, gateway_param);

        let old_margin = data.get_d_token_liquidity();
        let new_margin = data.get_d_token_liquidity_with_remove(gateway_param, b_amount);
        if (new_margin <= old_margin / 100) {
            new_margin = 0;
        };

        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(RequestTradeAndRemoveMargin {
            request_id,
            p_token_id,
            real_money_margin: new_margin,
            last_cumulative_pnl_on_engine: data.last_cumulative_pnl_on_engine.to_string(),
            cumulative_pnl_on_gateway: data.cumulative_pnl_on_gateway.to_string(),
            b_amount,
            symbol_id,
            trade_params: trade_params.map(|x| i256::from(x).to_string())
        })
    }

    /// Finalize the liquidity update based on event emitted on d-chain.
    /// eventData: the encoded event data containing information about the liquidity update, emitted on d-chain.
    /// signature: the signature used to verify the event data.
    public entry fun finish_update_liquidity(
        user: &signer,
        request_id: u256,
        l_token_id: u256,
        liquidity: u256,
        total_liquidity: u256,
        cumulative_pnl_on_gateway: u256,
        b_amount_to_remove: u256,
        signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        // TODO: verify signature

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];
        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = gateway_storage.d_token_states.borrow_mut(l_token_id);

        check_request_id(d_token_state, request_id);
        update_liquidity(gateway_state, d_token_state, liquidity, total_liquidity);

        // Cumulate unsettled PNL to b0_amount
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&d_token_state.b_token));
        let data = get_data_and_check_b_token_consistency(
            gateway_state,
            b_token_state,
            d_token_state,
            ltoken::owner(l_token_id),
            l_token_id,
            d_token_state.b_token
        );

        let (diff, _) = i256::overflowing_sub(
            i256::from(cumulative_pnl_on_gateway),
            data.last_cumulative_pnl_on_engine
        );
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        data.b0_amount = i256::wrapping_add(data.b0_amount, i256::rescale(diff, SCALE_DECIMALS, decimals_b0));
        data.last_cumulative_pnl_on_engine = i256::from(cumulative_pnl_on_gateway);

        let b_amount_removed = 0;
        let operate_token = @0x0;
        if (b_amount_to_remove != 0) {
            operate_token = d_token_state.current_operate_token;
            if (object::object_address(&data.b_token) == operate_token) {
                data.get_ex_params(b_token_state, gateway_param);
                let transfer_out_amount = if (liquidity == 0) {
                    MAX_AS_U256
                } else {
                    b_amount_to_remove
                };
                b_amount_removed = transfer_out(&mut data, gateway_param, transfer_out_amount, false);
            } else {
                assert!(operate_token == object::object_address(&gateway_param.token_b0));

                if (i256::is_greater_than_zero(data.b0_amount)) {
                    let b0_amount_removed_asset = vault::redeem(
                        object::address_to_object<Vault>(gateway_param.vault0),
                        0,
                        safe_math256::min(b_amount_removed, i256::as_u256(data.b0_amount))
                    );
                    let b0_amount_removed = (fungible_asset::amount(&b0_amount_removed_asset) as u256);
                    data.b0_amount = i256::wrapping_sub(data.b0_amount, i256::from(b0_amount_removed));

                    let b_amount_to_remove_asset = fungible_asset::extract(
                        &mut b0_amount_removed_asset,
                        (b_amount_to_remove as u64)
                    );
                    primary_fungible_store::deposit(data.account, b_amount_to_remove_asset);

                    let gateway_store = gateway_param.gateway_stores.borrow(gateway_param.token_b0);
                    fungible_asset::deposit(gateway_store.store, b0_amount_removed_asset);
                }
            }
        };

        data.save_data(gateway_state, d_token_state);
        transfer_last_request_ichain_execution_fee(
            gateway_param,
            d_token_state,
            gateway_state,
            signer::address_of(user)
        );

        if (b_amount_to_remove == 0) {
            // If bAmountToRemove == 0, it is a AddLiqudiity finalization
            event::emit(FinishAddLiquidity {
                request_id,
                l_token_id,
                liquidity,
                total_liquidity
            })
        } else {
            // If bAmountToRemove != 0, it is a RemoveLiquidity finalization
            event::emit(FinishRemoveLiquidity {
                request_id,
                l_token_id,
                liquidity,
                total_liquidity,
                b_token: operate_token,
                b_amount: b_amount_removed
            })
        }
    }

    /// Finalize the remove of margin based on event emitted on d-chain.
    public entry fun finish_remove_margin(
        user: &signer,
        request_id: u256,
        p_token_id: u256,
        required_margin: u256,
        cumulative_pnl_on_gateway: u256,
        b_amount_to_remove: u256,
        signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        // TODO: verify signature

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&d_token_state.b_token));

        check_request_id(d_token_state, request_id);
        let data = get_data_and_check_b_token_consistency(
            &gateway_storage.gateway_state,
            b_token_state,
            d_token_state,
            user_addr,
            p_token_id,
            d_token_state.b_token
        );
        let (diff, _) = i256::overflowing_sub(
            i256::from(cumulative_pnl_on_gateway),
            data.last_cumulative_pnl_on_engine
        );
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        data.b0_amount = i256::wrapping_add(data.b0_amount, i256::rescale(diff, SCALE_DECIMALS, decimals_b0));
        data.last_cumulative_pnl_on_engine = i256::from(cumulative_pnl_on_gateway);

        data.get_ex_params(b_token_state, gateway_param);
        let b_amount = transfer_out(&mut data, gateway_param, b_amount_to_remove, true);
        assert!(data.get_d_token_liquidity() > required_margin, EINSUFFICIENT_MARGIN);

        let gateway_state = &mut gateway_storage.gateway_state;
        data.save_data(gateway_state, d_token_state);
        transfer_last_request_ichain_execution_fee(gateway_param, d_token_state, gateway_state, user_addr);

        event::emit(FinishRemoveMargin {
            request_id,
            p_token_id,
            b_token: object::object_address(&data.b_token),
            b_amount
        })
    }

    /// Finalize the liquidation based on event emitted on d-chain.
    public entry fun finish_liquidate(
        user: &signer,
        requester: address,
        executor: address,
        finisher: address,
        request_id: u256,
        p_token_id: u256,
        cumulative_pnl_on_gateway: u256,
        maintenance_margin_required: u256,
        signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        // TODO: verify signature

        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        let b_token_state = gateway_storage.b_token_states.borrow(object::object_address(&d_token_state.b_token));

        let data = get_data_and_check_b_token_consistency(
            &gateway_storage.gateway_state,
            b_token_state,
            d_token_state,
            ptoken::owner(p_token_id),
            p_token_id,
            d_token_state.b_token
        );
        let (diff, _) = i256::overflowing_sub(
            i256::from(cumulative_pnl_on_gateway),
            data.last_cumulative_pnl_on_engine
        );
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        data.b0_amount = i256::wrapping_add(data.b0_amount, i256::rescale(diff, SCALE_DECIMALS, decimals_b0));
        data.last_cumulative_pnl_on_engine = i256::from(cumulative_pnl_on_gateway);

        let b0_amount_in = 0;
        let gateway_b_store = gateway_param.gateway_stores.borrow(d_token_state.b_token);

        {
            let b_asset = vault::redeem(
                object::address_to_object<Vault>(data.vault),
                data.d_token_id,
                MAX_AS_U256
            );
            let b_amount = (fungible_asset::amount(&b_asset) as u256);
            fungible_asset::deposit(gateway_b_store.store, b_asset);

            if (data.b_token == gateway_param.token_b0) {
                b0_amount_in += b_amount;
            } else {
                // TODO: liquidateRedeemAndSwap
            }
        };

        // All Lp's PNL by liquidating this trader
        let lp_pnl = i256::wrapping_add(data.b0_amount, i256::from(b0_amount_in));
        let reward = calculate_reward(
            lp_pnl,
            gateway_param.liquidation_reward_cut_ratio,
            gateway_param.min_liquidation_reward,
            gateway_param.max_liquidation_reward
        );
        let (reward, b0_amount_in) = process_reward(
            gateway_param,
            gateway_param.token_b0,
            gateway_param.vault0,
            reward,
            b0_amount_in,
            executor,
            finisher
        );
        lp_pnl = i256::wrapping_sub(lp_pnl, reward);

        if (b0_amount_in > 0) {
            let gateway_b_store = gateway_param.gateway_stores.borrow(gateway_param.token_b0);
            let gateway_b_signer = &object::generate_signer_for_extending(&gateway_b_store.store_extend_ref);
            let b0_asset = fungible_asset::withdraw(gateway_b_signer, gateway_b_store.store, (b0_amount_in as u64));
            vault::deposit(
                object::address_to_object<Vault>(gateway_param.vault0),
                0,
                b0_asset
            );
        };

        // Cumulate lpPnl into cumulativePnlOnGateway,
        // which will be distributed to all LPs on all i-chains with next request process
        data.cumulative_pnl_on_gateway = i256::wrapping_add(
            data.cumulative_pnl_on_gateway,
            i256::rescale(lp_pnl, decimals_b0, SCALE_DECIMALS)
        );
        data.b0_amount = i256::zero();

        let gateway_state = &mut gateway_storage.gateway_state;
        data.save_data(gateway_state, d_token_state);

        {
            let last_request_ichain_execution_fee = d_token_state.last_request_i_chain_execution_fee;
            let cumulative_unused_i_chain_execution_fee = d_token_state.cumulative_unused_i_chain_execution_fee;

            d_token_state.last_request_i_chain_execution_fee = 0;
            d_token_state.cumulative_unused_i_chain_execution_fee = 0;

            gateway_state.total_i_chain_execution_fee = gateway_state.total_i_chain_execution_fee - last_request_ichain_execution_fee + cumulative_unused_i_chain_execution_fee
        };

        ptoken::burn(p_token_id);

        event::emit(FinishLiquidate {
            request_id,
            p_token_id,
            lp_pnl: lp_pnl.to_string(),
        })
    }

    //////////////////////// Internal functions ////////////////////////

    fun request_add_margin_internal(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256,
        single_position: bool
    ): u256 acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        let gateway_storage = &mut GatewayStorage[@deri];
        let gateway_param = &GatewayParam[@deri];

        assert!(b_amount > 0, EINVALID_BTOKEN_AMOUNT);

        if (p_token_id == 0) {
            p_token_id = ptoken::mint(user_addr);
            if (single_position) {
                let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
                d_token_state.single_position = true;
            }
        } else {
            check_p_token_id_owner(p_token_id, signer::address_of(user));
        };
        check_b_token_initialized(&gateway_storage.b_token_states, b_token);

        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = gateway_storage.d_token_states.borrow_mut(p_token_id);
        let data = get_data_and_check_b_token_consistency(
            gateway_state,
            gateway_storage.b_token_states.borrow(object::object_address(&b_token)),
            d_token_state,
            user_addr,
            p_token_id,
            b_token
        );

        let b_token_asset = primary_fungible_store::withdraw(user, b_token, (b_amount as u64));
        deposit(&mut data, b_token_asset, gateway_param);

        data.save_data(gateway_state, d_token_state);
        let request_id = increment_request_id(gateway_state, d_token_state);

        event::emit(FinishAddMargin {
            request_id,
            p_token_id,
            b_token: object::object_address(&b_token),
            b_amount
        });

        p_token_id
    }

    fun get_data(
        gateway_state: &GatewayState,
        b_token_state: &BTokenState,
        d_token_state: &DTokenState,
        account: address,
        d_token_id: u256,
        b_token: Object<Metadata>
    ): Data {
        let cumulative_pnl_on_gateway = gateway_state.cumulative_pnl_on_gateway;

        Data {
            account,
            d_token_id,
            b_token,
            cumulative_pnl_on_gateway,
            vault: b_token_state.vault,
            b0_amount: d_token_state.b0_amount,
            last_cumulative_pnl_on_engine: d_token_state.last_cumulative_pnl_on_engine,
            collateral_factor: 0,
            b_price: 0
        }
    }

    fun get_data_and_check_b_token_consistency(
        gateway_state: &GatewayState,
        b_token_state: &BTokenState,
        d_token_state: &DTokenState,
        account: address,
        d_token_id: u256,
        b_token: Object<Metadata>
    ): Data {
        let data = get_data(gateway_state, b_token_state, d_token_state, account, d_token_id, b_token);
        check_b_token_consistency(
            d_token_state,
            b_token_state,
            d_token_id,
            b_token
        );
        data
    }

    fun save_data(
        self: &Data,
        gateway_state: &mut GatewayState,
        d_token_state: &mut DTokenState
    ) {
        gateway_state.cumulative_pnl_on_gateway = self.cumulative_pnl_on_gateway;

        d_token_state.b_token = self.b_token;
        d_token_state.b0_amount = self.b0_amount;
        d_token_state.last_cumulative_pnl_on_engine = self.last_cumulative_pnl_on_engine;
    }

    /// Check callback's requestId is the same as the current request_id stored for user
    /// If a new request is submitted before the callback for last request, request_id will not match,
    /// and this callback cannot be executed anymore
    fun check_request_id(
        d_token_state: &DTokenState,
        request_id: u256
    ) {
        assert!(d_token_state.request_id == request_id, EINVALD_REQUEST_ID);
    }

    /// Increment gateway requestId and user requestId and returns the combined requestId for this request
    fun increment_request_id(
        gateway_state: &mut GatewayState,
        d_token_state: &mut DTokenState
    ): u256 {
        let gateway_request_id = gateway_state.gateway_request_id + 1;
        gateway_state.gateway_request_id = gateway_request_id;

        let user_request_id = d_token_state.request_id + 1;
        d_token_state.request_id = user_request_id;

        (gateway_request_id << 32) + user_request_id
    }

    fun check_b_token_initialized(
        b_token_states: &SmartTable<address, BTokenState>, b_token: Object<Metadata>
    ) {
        let b_token_address = object::object_address(&b_token);
        assert!(b_token_states.contains(b_token_address), EINVALID_BTOKEN);
    }

    fun check_b_token_consistency(
        d_token_state: &DTokenState,
        b_token_state: &BTokenState,
        d_token_id: u256,
        b_token: Object<Metadata>
    ) {
        let pre_b_token = d_token_state.b_token;
        let pre_b_token_addr = object::object_address(&pre_b_token);
        if (pre_b_token_addr != ZERO_ADDRESS && pre_b_token != b_token) {
            let vault_address = b_token_state.vault;

            let st_amount = vault::st_amounts(object::address_to_object(vault_address), d_token_id);
            assert!(st_amount == 0, EINVALID_BTOKEN);
        }
    }

    fun check_l_token_id_owner(l_token_id: u256, user_address: address) {
        let l_token_addr = ltoken::get_token_address(l_token_id);
        let l_token = object::address_to_object<LToken>(l_token_addr);
        assert!(object::owner(l_token) == user_address, EINVALID_LTOKEN_ID);
    }

    fun check_p_token_id_owner(p_token_id: u256, user_address: address) {
        let p_token_addr = ltoken::get_token_address(p_token_id);
        let p_token = object::address_to_object<PToken>(p_token_addr);
        assert!(object::owner(p_token) == user_address, EINVALID_PTOKEN_ID);
    }

    fun receive_execution_fee(
        d_token_state: &mut DTokenState,
        gateway_state: &mut GatewayState,
        execution_fee: u256,
        value: u256
    ): u256 {
        let d_chain_execution_fee = gateway_state.d_chain_execution_fee_per_request;
        assert!(value >= execution_fee, EINSUFFICIENT_EXECUTION_FEE);

        let i_chain_execution_fee = execution_fee - d_chain_execution_fee;
        gateway_state.total_i_chain_execution_fee += i_chain_execution_fee;

        let last_request_i_chain_execution_fee = d_token_state.last_request_i_chain_execution_fee;
        let cumulative_unused_i_chain_execution_fee = d_token_state.cumulative_unused_i_chain_execution_fee;
        cumulative_unused_i_chain_execution_fee += last_request_i_chain_execution_fee;
        last_request_i_chain_execution_fee = i_chain_execution_fee;

        d_token_state.last_request_i_chain_execution_fee = last_request_i_chain_execution_fee;
        d_token_state.cumulative_unused_i_chain_execution_fee = cumulative_unused_i_chain_execution_fee;

        value - execution_fee
    }

    fun transfer_last_request_ichain_execution_fee(
        gateway_param: &GatewayParam,
        d_token_state: &mut DTokenState,
        gateway_state: &mut GatewayState,
        to: address,
    ) {
        let last_request_i_chain_execution_fee = d_token_state.last_request_i_chain_execution_fee;
        if (last_request_i_chain_execution_fee > 0) {
            gateway_state.total_i_chain_execution_fee -= last_request_i_chain_execution_fee;
            d_token_state.last_request_i_chain_execution_fee = 0;

            let gateway_store = get_gateway_store(gateway_param, get_aptos_coin_wrapper());
            let apt_wrapper_asset = fungible_asset::withdraw(
                &object::generate_signer_for_extending(&gateway_store.store_extend_ref),
                gateway_store.store,
                (last_request_i_chain_execution_fee as u64)
            );
            aptos_account::deposit_coins(to, coin_wrapper::unwrap<AptosCoin>(apt_wrapper_asset));
        }
    }

    /// b_price * b_amount / UONE = b0_amount, b0_amount in decimals_b0
    fun get_b_price(b_token: Object<Metadata>, gateway_param: &GatewayParam): u256 {
        if (b_token == gateway_param.token_b0) { UONE }
        else {
            let _b_token_decimals = fungible_asset::decimals(b_token);
            // TODO: get price from oracle

            UONE
        }
    }

    fun get_ex_params(
        self: &mut Data,
        b_token_state: &BTokenState,
        gateway_param: &GatewayParam
    ) {
        self.collateral_factor = b_token_state.collateral_factor;
        self.b_price = get_b_price(self.b_token, gateway_param);
    }

    /// Calculate the liquidity associated with current dTokenId
    fun get_d_token_liquidity(self: &Data): u256 {
        let b0_amount_in_vault =
            vault::get_balance(object::address_to_object<Vault>(self.vault), self.d_token_id)
                * self.b_price / UONE + self.collateral_factor / UONE;
        let b0_shortage = if (!i256::is_neg(self.b0_amount)) { 0 }
        else {
            i256::abs_u256(self.b0_amount)
        };

        if (b0_amount_in_vault >= b0_shortage) {
            b0_amount_in_vault + b0_shortage
        } else { 0 }
    }

    /// Calculate the liquidity associated with current dTokenId if `bAmount` in bToken is removed
    fun get_d_token_liquidity_with_remove(
        self: &Data, gateway_param: &GatewayParam, b_amount: u256
    ): u256 {
        let liquidity = 0;
        // make sure b_amount * b_price won't overflow
        if (b_amount < MAX_AS_U256 / self.b_price) {
            let b_amount_in_vault =
                vault::get_balance(object::address_to_object<Vault>(self.vault), self.d_token_id);
            if (b_amount >= b_amount_in_vault) {
                if (i256::is_greater_than_zero(self.b0_amount)) {
                    let b0_shortage = (b_amount - b_amount_in_vault) * self.b_price / UONE;
                    let b0_amount = i256::as_u256(self.b0_amount);
                    if (b0_amount > b0_shortage) {
                        liquidity = b0_amount - b0_shortage;
                    }
                }
            } else {
                // discounted
                let b0_excessive =
                    (b_amount_in_vault - b_amount) * self.b_price / UONE * self.collateral_factor
                        / UONE;
                if (!i256::is_neg(self.b0_amount)) {
                    liquidity = b0_excessive + i256::as_u256(self.b0_amount);
                } else {
                    let b0_shortage = i256::abs_u256(self.b0_amount);
                    if (b0_excessive > b0_shortage) {
                        liquidity = b0_excessive - b0_shortage;
                    }
                }
            };

            if (liquidity > 0) {
                let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
                liquidity = safe_math256::rescale(liquidity, decimals_b0, SCALE_DECIMALS);
            }
        };

        liquidity
    }

    /// Calculate the liquidity (in 8 decimals) associated with current dTokenId if `bAmount` in bToken is removed
    fun get_d_token_liquidity_with_remove_b0(
        self: &Data, gateway_param: &GatewayParam, b0_amount_to_remove: u256
    ): u256 {
        let b_amount_in_vault =
            vault::get_balance(object::address_to_object<Vault>(self.vault), self.d_token_id);
        // discounted
        let b0_value_of_b_amount_in_vault =
            b_amount_in_vault * self.b_price / UONE * self.collateral_factor / UONE;
        let b0_total =
            if (!i256::is_neg(self.b0_amount)) {
                b0_value_of_b_amount_in_vault + i256::as_u256(self.b0_amount)
            } else {
                b0_value_of_b_amount_in_vault - i256::abs_u256(self.b0_amount)
            };

        if (b0_total > b0_amount_to_remove) {
            let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
            safe_math256::rescale(b0_total - b0_amount_to_remove, decimals_b0, SCALE_DECIMALS)
        } else { 0 }
    }

    fun deposit(
        data: &mut Data, b_token_asset: FungibleAsset, gateway_param: &GatewayParam
    ) {
        let b_amount = (fungible_asset::amount(&b_token_asset) as u256);
        if (data.b_token == gateway_param.token_b0) {
            let reserved = b_amount * gateway_param.b0_reserve_ratio / UONE;
            vault::deposit(
                object::address_to_object(gateway_param.vault0),
                0,
                fungible_asset::extract(&mut b_token_asset, (reserved as u64))
            );
            data.b0_amount = i256::add(data.b0_amount, i256::from(reserved));
        };

        vault::deposit(
            object::address_to_object(data.vault),
            data.d_token_id,
            b_token_asset
        );
    }

    /// Transfer a specified amount of bToken, handling various cases
    fun transfer_out(
        data: &mut Data,
        gateway_param: &GatewayParam,
        b_amount_out: u256,
        // A flag indicating whether the transfer is for a trader (true) or not (false).
        is_td: bool
    ): u256 {
        let b_amount = b_amount_out;
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        let token_b0_store = get_gateway_store(gateway_param, gateway_param.token_b0);
        let token_b_store = get_gateway_store(gateway_param, data.b_token);

        // min swap b0Amount of 0.01 USDC
        let min_swap_b0_amount = (math64::pow(10, ((decimals_b0 - 2) as u64)) as u256);

        // Handle redemption of additional tokens to cover a negative B0 amount.
        if (b_amount < MAX_AS_U256 / UONE && i256::is_neg(data.b0_amount)) {
            if (data.b_token == gateway_param.token_b0) {
                // Redeem B0 tokens to cover the negative B0 amount.
                b_amount += i256::abs_u256(data.b0_amount);
            } else {
                b_amount += i256::abs_u256(data.b0_amount) * UONE / data.b_price;
            }
        };

        // Redeem tokens from the vault
        // currentlly only support vault implementation none
        let vault_obj = object::address_to_object<Vault>(data.vault);
        let b_fungible_asset = vault::redeem(
            vault_obj,
            data.d_token_id,
            b_amount
        );
        let b_amount = (fungible_asset::amount(&b_fungible_asset) as u256);
        fungible_asset::deposit(token_b_store.store, b_fungible_asset);

        // Amount of B0 tokens going to reserves.
        let b0_amount_in = 0;
        // Amount of B0 tokens going to user.
        let b0_amount_out = 0;
        // Amount of IOU tokens going to the trader.
        let iou_amount = 0;

        // Handle excessive tokens (more than bAmountOut).
        if (b_amount > b_amount_out) {
            let b_excesive = b_amount - b_amount_out;
            let b0_excessive = 0;
            if (data.b_token == gateway_param.token_b0) {
                b0_excessive = b_excesive;
                b_amount -= b0_excessive;
            } else if (data.b_token == get_aptos_coin_wrapper()) {
                // TODO: swap APT to B0
                // (uint256 resultB0, uint256 resultBX) = swapper.swapExactETHForB0{value: bExcessive}();
                // b0Excessive = resultB0;
                // bAmount -= resultBX;
            } else {
                // TODO: swap to B0
                // (uint256 resultB0, uint256 resultBX) = swapper.swapExactBXForB0(data.bToken, bExcessive);
                // b0Excessive = resultB0;
                // bAmount -= resultBX;
            };

            b0_amount_in += b0_excessive;
            data.b0_amount = i256::add(data.b0_amount, i256::from(b0_excessive));
        };

        // Handle filling the negative B0 balance, by swapping bToken into B0, if necessary.
        if (b_amount > 0 && i256::is_neg(data.b0_amount)) {
            let owe = i256::abs_u256(data.b0_amount);
            let b0_fill = 0;
            if (data.b_token == gateway_param.token_b0) {
                if (b_amount >= owe) {
                    b0_fill = owe;
                    b_amount -= owe;
                } else {
                    b0_fill = b_amount;
                    b_amount = 0;
                }
            } else {
                // let owe equals to minSwapB0Amount if small, otherwise swap may fail
                if (owe < min_swap_b0_amount) {
                    owe = min_swap_b0_amount;
                };
                if (data.b_token == get_aptos_coin_wrapper()) {
                    // TODO: swap APT to B0
                    // (uint256 resultB0, uint256 resultBX) = swapper.swapETHForExactB0{value: bAmount}(owe);
                    // b0Fill = resultB0;
                    // bAmount -= resultBX;
                } else {
                    // TODO: swap to B0
                    // (uint256 resultB0, uint256 resultBX) = swapper.swapBXForExactB0(data.bToken, owe, bAmount);
                    // b0Fill = resultB0;
                    // bAmount -= resultBX;
                }
            };
            b0_amount_in += b0_fill;
            data.b0_amount = i256::add(data.b0_amount, i256::from(b0_fill));
        };

        // Handle reserved portion when withdrawing all or operating token is token_b0
        if (i256::is_greater_than_zero(data.b0_amount)) {
            let amount = 0;
            if (b_amount_out >= MAX_AS_U256 / UONE) {
                // withdraw all
                amount = i256::as_u256(data.b0_amount);
            } else if (data.b_token == gateway_param.token_b0 && b_amount < b_amount_out) {
                // shortage on tokenB0
                amount = safe_math256::min(i256::as_u256(data.b0_amount), b_amount_out - b_amount);
            };

            if (amount > 0) {
                let b0_out = 0;
                if (amount > b0_amount_in) {
                    // Redeem B0 tokens from vault0
                    let b0_redeemed_fungible_asset = vault::redeem(
                        object::address_to_object<Vault>(gateway_param.vault0),
                        0,
                        amount - b0_amount_in
                    );
                    let b0_redeemed = (fungible_asset::amount(&b0_redeemed_fungible_asset) as u256);
                    fungible_asset::deposit(
                        get_gateway_store(gateway_param, gateway_param.token_b0).store,
                        b0_redeemed_fungible_asset
                    );

                    if (b0_redeemed < amount - b0_amount_in) {
                        // b0 insufficent
                        if (is_td) {
                            // Issue IOU for trader when B0 insufficent
                            iou_amount = amount - b0_amount_in - b0_redeemed;
                        } else {
                            // Revert for Lp when B0 insufficent
                            abort error::aborted(EINSUFFICIENT_B0_BALANCE)
                        }
                    };
                    b0_out = b0_amount_in + b0_redeemed;
                    b0_amount_in = 0;
                } else {
                    b0_out = amount;
                    b0_amount_in -= amount;
                };
                b0_amount_out = b0_out;
                data.b0_amount = i256::sub(data.b0_amount, i256::from(iou_amount));
            };
        };

        // Deposit B0 tokens into the vault0, if any
        if (b0_amount_in > 0) {
            let b0_fungible_asset = fungible_asset::withdraw(
                &object::generate_signer_for_extending(&token_b0_store.store_extend_ref),
                token_b0_store.store,
                (b0_amount_in as u64)
            );

            vault::deposit(
                object::address_to_object(gateway_param.vault0),
                0,
                b0_fungible_asset
            );
        };

        // Transfer B0 tokens or swap them to the current operating token
        if (b0_amount_out > 0) {
            if (is_td) {
                // No swap from B0 to BX for trader
                if (data.b_token == gateway_param.token_b0) {
                    b_amount += b0_amount_out;
                } else {
                    fungible_asset::transfer(
                        &object::generate_signer_for_extending(&token_b0_store.store_extend_ref),
                        token_b0_store.store,
                        primary_fungible_store::ensure_primary_store_exists(data.account, gateway_param.token_b0),
                        (b0_amount_out as u64)
                    )
                }
            } else {
                // Swap B0 into BX for Lp
                if (data.b_token == gateway_param.token_b0) {
                    b_amount += b0_amount_out;
                } else if (b0_amount_out < min_swap_b0_amount) {
                    // cannot swap such small amount of B0, cumulate it into cumulative_pnl_on_gateway
                    data.cumulative_pnl_on_gateway = i256::wrapping_add(
                        data.cumulative_pnl_on_gateway,
                        i256::rescale(
                            i256::from(b0_amount_out),
                            fungible_asset::decimals(gateway_param.token_b0),
                            SCALE_DECIMALS
                        )
                    )
                } else if (data.b_token == get_aptos_coin_wrapper()) {
                    // TODO: swap B0 to APT
                    // (, uint256 resultBX) = swapper.swapExactB0ForETH(b0AmountOut);
                    // bAmount += resultBX;
                } else {
                    // TODO: swap B0 to BX
                    // (, uint256 resultBX) = swapper.swapExactB0ForBX(data.bToken, b0AmountOut);
                    // bAmount += resultBX;
                }
            }
        };

        // Transfer the remaining bAmount to the user's account.
        if (b_amount > 0) {
            fungible_asset::transfer(
                &object::generate_signer_for_extending(&token_b_store.store_extend_ref),
                token_b_store.store,
                primary_fungible_store::ensure_primary_store_exists(data.account, data.b_token),
                (b_amount as u64)
            )
        };

        // Mint IOU tokens for the trader, if any.
        if (iou_amount > 0) {
            iou::mint(data.account, (iou_amount as u64));
        };

        b_amount
    }

    /// Update liquidity-related state variables for a specific l_token
    fun update_liquidity(
        gateway_state: &mut GatewayState,
        d_token_state: &mut DTokenState,
        new_liquidity: u256,
        new_total_liquidity: u256,
    ) {
        let (cumulative_time_per_liquidity, cumulative_time) = get_cumulative_time_internal(
            gateway_state,
            d_token_state
        );

        gateway_state.liquidity_time = (timestamp::now_seconds() as u256);
        gateway_state.total_liquidity = new_total_liquidity;
        gateway_state.cumulative_time_per_liquidity = i256::from(cumulative_time_per_liquidity);

        d_token_state.liquidity = new_liquidity;
        d_token_state.cumulative_time = cumulative_time;
        d_token_state.last_cumulative_time_per_liquidity = cumulative_time_per_liquidity;
    }

    /// Internal function
    fun get_cumulative_time_internal(
        gateway_state: &GatewayState,
        d_token_state: &DTokenState,
    ): (u256, u256) {
        let liquidity_time = gateway_state.liquidity_time;
        let total_liquidity = gateway_state.total_liquidity;

        let cumulative_time_per_liquidity = i256::as_u256(gateway_state.cumulative_time_per_liquidity);
        let liquidity = d_token_state.liquidity;
        let cumulative_time = d_token_state.cumulative_time;
        let last_cumulative_time_per_liquidity = d_token_state.last_cumulative_time_per_liquidity;

        if (total_liquidity != 0) {
            let now_seconds = (timestamp::now_seconds() as u256);
            let diff1 = (now_seconds - liquidity_time) * UONE * UONE / total_liquidity;
            cumulative_time_per_liquidity += diff1;

            if (liquidity != 0) {
                let diff2 = cumulative_time_per_liquidity - last_cumulative_time_per_liquidity;
                cumulative_time += diff2 * liquidity / UONE;
            };
        };
        (cumulative_time_per_liquidity, cumulative_time)
    }

    fun calculate_reward(
        lp_pnl: I256,
        min_liquidation_reward: I256,
        max_liquidation_reward: I256,
        liquidation_reward_cut_ratio: I256
    ): I256 {
        if (i256::lte(lp_pnl, min_liquidation_reward)) {
            min_liquidation_reward
        } else {
            i256::min(
                (
                    i256::add(
                        i256::div(
                            i256::mul(
                                i256::sub(lp_pnl, min_liquidation_reward),
                                liquidation_reward_cut_ratio
                            ),
                            i256::from(UONE)
                        ),
                        min_liquidation_reward
                    )
                ),
                max_liquidation_reward
            )
        }
    }

    fun process_reward(
        gateway_param: &GatewayParam,
        token_b0: Object<Metadata>,
        vault0: address,
        reward: I256,
        b0_amount_in: u256,
        executor: address,
        finisher: address
    ): (I256, u256) {
        let u_reward = i256::as_u256(reward);
        let gateway_b0_store = get_gateway_store(gateway_param, token_b0);
        let gateway_b0_signer = &object::generate_signer_for_extending(&gateway_b0_store.store_extend_ref);

        if (u_reward <= b0_amount_in) {
            b0_amount_in -= u_reward;
        } else {
            let b0_redeemed_asset = vault::redeem(
                object::address_to_object<Vault>(vault0),
                0,
                u_reward - b0_amount_in
            );
            let b0_redeemed = (fungible_asset::amount(&b0_redeemed_asset) as u256);
            fungible_asset::deposit(
                gateway_b0_store.store,
                b0_redeemed_asset
            );
            u_reward = b0_amount_in + b0_redeemed;
            reward = i256::from(u_reward);
            b0_amount_in = 0;
        };

        if (u_reward > 0) {
            let reward_excutor = u_reward * 80 / 100;
            let reward_finisher = u_reward - reward_excutor;
            let executor_store = primary_fungible_store::ensure_primary_store_exists(executor, token_b0);
            let finisher_store = primary_fungible_store::ensure_primary_store_exists(finisher, token_b0);
            fungible_asset::transfer(gateway_b0_signer, gateway_b0_store.store, executor_store,
                (reward_excutor as u64)
            );
            fungible_asset::transfer(gateway_b0_signer, gateway_b0_store.store, finisher_store,
                (reward_finisher as u64)
            );
        };

        (reward, b0_amount_in)
    }

    inline fun get_aptos_coin_wrapper(): Object<Metadata> {
        coin_wrapper::get_wrapper<AptosCoin>()
    }

    inline fun create_gateway_store(token: Object<Metadata>): GatewayStore {
        let store_constructor_ref = &object::create_object_from_account(&global_state::config_signer());
        let store = fungible_asset::create_store(store_constructor_ref, token);
        GatewayStore {
            store,
            store_extend_ref: object::generate_extend_ref(store_constructor_ref),
        }
    }

    inline fun get_gateway_store(gateway_param: &GatewayParam, token: Object<Metadata>): &GatewayStore {
        gateway_param.gateway_stores.borrow(token)
    }
}

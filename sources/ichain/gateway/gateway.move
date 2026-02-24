module deri::gateway {
    use supra_framework::supra_account;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::chain_id;
    use supra_framework::coin::Coin;
    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::fungible_asset::{Self, Metadata, FungibleAsset, FungibleStore};
    use supra_framework::object::{Self, Object, ExtendRef};
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;
    use aptos_std::aptos_hash;
    use aptos_std::from_bcs;
    use aptos_std::math64;
    use aptos_std::secp256k1;
    use aptos_std::smart_table::{Self, SmartTable};
    use deri::coin_wrapper;
    use deri::global_state;
    use deri::i256::{Self, I256};
    use deri::iou;
    use deri::ltoken::{Self, LToken};
    use deri::ptoken::{Self, PToken};
    use deri::reward_store;
    use deri::safe_math256;
    use deri::vault::{Self, Vault};
    use std::error;
    use std::option;
    use std::signer;
    use std::string::String;
    use std::vector;

    /// TODO: update value for deployment
    const B0_RESERVE_RATIO: u256 = 200_000_000_000_000_000;
    const LIQUIDATION_REWARD_CUT_RATIO: u256 = 500_000_000_000_000_000;
    const MIN_LIQUIDATION_REWARD: u256 = 0;
    const MAX_LIQUIDATION_REWARD: u256 = 500_000_000;
    const D_CHAIN_EVENT_SIGNER: vector<u8> = x"a51Cd97F3090f6a16Cf0cdC12B0cB4b0a95b38EA";

    const MAX_AS_U256: u256 = 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    const SCALE_DECIMALS: u8 = 18;
    /// 1 UONE = 1e18
    const UONE: u256 = 1_000_000_000_000_000_000;
    const ZERO_ADDRESS: address = @0x0;

    // Constants for signature components
    const SIGNATURE_R_LENGTH: u64 = 32;
    const SIGNATURE_S_LENGTH: u64 = 32;
    const SIGNATURE_RS_LENGTH: u64 = 64;
    // R + S
    const SIGNATURE_V_INDEX: u64 = 64; // Index of V in signature

    // Constants for Ethereum address derivation
    const ETH_ADDRESS_LENGTH: u64 = 20;
    const PUBKEY_HASH_START: u64 = 12;
    // 32 - 20 = 12, start index to get last 20 bytes
    const PUBKEY_HASH_END: u64 = 32; // Full length of keccak256 hash

    // Ethereum signature constants
    const ETH_SIGNATURE_V_OFFSET: u8 = 27;
    // Ethereum adds 27 to recovery_id
    const ETH_PREFIX: vector<u8> = b"\x19Ethereum Signed Message:\n32";

    //////////////////////// Errors ////////////////////////
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
    /// Cannot delete BToken
    const ENOT_DELETE_BTOKEN: u64 = 10;
    /// Not implemented
    const ENOT_IMPLEMENTED: u64 = 11;
    /// Not authorized
    const ENOT_AUTHORIZED: u64 = 12;
    /// Not valid chain id
    const EINVALID_CHAIN_ID: u64 = 13;
    /// Invalid operation token
    const EINVALID_OPERATE_TOKEN: u64 = 14;
    /// Deprecated
    const EDEPRECATED: u64 = 1001;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct GatewayStorage has key {
        gateway_state: GatewayState,
        // b_token address => state
        b_token_states: SmartTable<address, BTokenState>,
        // d_token address => state
        d_token_states: SmartTable<u256, DTokenState>,
        // actionId => executionFee
        execution_fees: ExecutionFee
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct GatewayParam has key {
        // Vault for holding reserved B0, used for payments on regular bases
        vault0: address,
        // B0, settlement base token, e.g. USDC native
        token_b0: Object<Metadata>,
        // EVM address of the dChain event signer
        d_chain_event_signer: vector<u8>,
        b0_reserve_ratio: u256,
        liquidation_reward_cut_ratio: I256,
        min_liquidation_reward: I256,
        max_liquidation_reward: I256,
        protocol_fee_manager: address,
        liq_claim: address,
        gateway_stores: SmartTable<Object<Metadata>, GatewayStore>
    }

    /// Data regarding the store object for a specific fungible asset.
    struct GatewayStore has store, drop {
        store: Object<FungibleStore>,
        store_extend_ref: ExtendRef
    }

    struct GatewayState has store, drop, copy {
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
    struct UpdateBToken has drop, store {
        b_token: address
    }

    #[event]
    struct DelBToken has drop, store {
        b_token: address
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
    struct RequestUpdateLiquidity has drop, store {
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
    struct RequestRemoveMargin has drop, store {
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
        cumulative_pnl_on_gateway: String
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
        trade_params: vector<String>
    }

    #[event]
    struct FinishLiquidate has drop, store {
        request_id: u256,
        p_token_id: u256,
        lp_pnl: String
    }

    #[event]
    struct FinishCollectProtocolFee has drop, store {
        amount: u256
    }

    fun init_module(deri_signer: &signer) {
        // create wrap APT
        coin_wrapper::create_fungible_asset<SupraCoin>();

        let gateway_storage = GatewayStorage {
            gateway_state: GatewayState {
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
        };

        let gateway_stores = smart_table::new();
        smart_table::add(
            &mut gateway_stores,
            get_aptos_coin_wrapper(),
            create_gateway_store(get_aptos_coin_wrapper())
        );

        move_to(
            deri_signer,
            GatewayParam {
                vault0: ZERO_ADDRESS,
                // B0, settlement base token, e.g. USDC native, setup in initialize step
                token_b0: get_aptos_coin_wrapper(),
                d_chain_event_signer: D_CHAIN_EVENT_SIGNER,
                b0_reserve_ratio: B0_RESERVE_RATIO,
                liquidation_reward_cut_ratio: i256::from(LIQUIDATION_REWARD_CUT_RATIO),
                min_liquidation_reward: i256::from(MIN_LIQUIDATION_REWARD),
                max_liquidation_reward: i256::from(MAX_LIQUIDATION_REWARD),
                protocol_fee_manager: @protocol_fee_manager,
                liq_claim: @liq_claim,
                gateway_stores
            }
        );

        move_to(deri_signer, gateway_storage);
    }

    /// Issue: https://github.com/aptos-labs/aptos-core/issues/11038
    /// so can not create vault in init_module
    public entry fun initialize_with_fa(admin: &signer, token_b0: Object<Metadata>) acquires GatewayParam {
        initialize_internal(admin, token_b0)
    }

    public entry fun initialize_with_coin<T>(admin: &signer) acquires GatewayParam {
        let token_b0 = coin_wrapper::create_fungible_asset<T>();
        initialize_internal(admin, token_b0)
    }

    fun initialize_internal(admin: &signer, token_b0: Object<Metadata>) acquires GatewayParam {
        global_state::assert_is_admin(admin);

        let gateway_param = borrow_global_mut<GatewayParam>(@deri);
        let gateway_stores = &mut gateway_param.gateway_stores;

        smart_table::add(gateway_stores, token_b0, create_gateway_store(token_b0));

        // create vault0 for token_b0
        let vault = vault::create_vault(token_b0);
        let vault_addr = object::object_address(&vault);

        // update vault0 in GatewayParam
        gateway_param.vault0 = vault_addr;
        gateway_param.token_b0 = token_b0;

        // create reward store for token_b0
        reward_store::create_reward_store(token_b0)
    }

    #[view]
    public fun get_gateway_param(): (address, Object<Metadata>, vector<u8>, u256, String, String, String, address, address) acquires GatewayParam {
        let gateway_param = borrow_global<GatewayParam>(@deri);
        (
            gateway_param.vault0,
            gateway_param.token_b0,
            gateway_param.d_chain_event_signer,
            gateway_param.b0_reserve_ratio,
            i256::to_string(gateway_param.liquidation_reward_cut_ratio),
            i256::to_string(gateway_param.min_liquidation_reward),
            i256::to_string(gateway_param.max_liquidation_reward),
            gateway_param.protocol_fee_manager,
            gateway_param.liq_claim
        )
    }

    #[view]
    public fun get_gateway_state(): (String, u256, u256, String, u256, u256, u256, u256) acquires GatewayStorage {
        let gateway_storage = borrow_global<GatewayStorage>(@deri).gateway_state;
        (
            i256::to_string(gateway_storage.cumulative_pnl_on_gateway),
            gateway_storage.liquidity_time,
            gateway_storage.total_liquidity,
            i256::to_string(gateway_storage.cumulative_time_per_liquidity),
            gateway_storage.gateway_request_id,
            gateway_storage.d_chain_execution_fee_per_request,
            gateway_storage.total_i_chain_execution_fee,
            gateway_storage.cumulative_collected_protocol_fee
        )
    }

    #[view]
    public fun get_b_token_state(b_token: Object<Metadata>): (address, String, u256) acquires GatewayStorage {
        let gateway_storage = borrow_global<GatewayStorage>(@deri);
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, object::object_address(&b_token));
        (b_token_state.vault, b_token_state.oracle_id, b_token_state.collateral_factor)
    }

    #[view]
    public fun get_lp_state(
        l_token_id: u256
    ): (u256, Object<Metadata>, u256, String, String, u256, u256, u256, u256, u256) acquires GatewayStorage {
        let gateway_storage = borrow_global<GatewayStorage>(@deri);
        let d_token_state = smart_table::borrow(&gateway_storage.d_token_states, l_token_id);
        let b_token_addr = object::object_address(&d_token_state.b_token);
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, b_token_addr);

        (
            d_token_state.request_id,
            d_token_state.b_token,
            vault::get_balance(object::address_to_object(b_token_state.vault), l_token_id),
            i256::to_string(d_token_state.b0_amount),
            i256::to_string(d_token_state.last_cumulative_pnl_on_engine),
            d_token_state.liquidity,
            d_token_state.cumulative_time,
            d_token_state.last_cumulative_time_per_liquidity,
            d_token_state.last_request_i_chain_execution_fee,
            d_token_state.cumulative_unused_i_chain_execution_fee
        )
    }

    #[view]
    public fun get_td_state(p_token_id: u256): (u256, Object<Metadata>, u256, String, String, bool, u256, u256) acquires GatewayStorage {
        let gateway_storage = borrow_global<GatewayStorage>(@deri);
        let d_token_state = smart_table::borrow(&gateway_storage.d_token_states, p_token_id);
        let b_token_addr = object::object_address(&d_token_state.b_token);
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, b_token_addr);

        (
            d_token_state.request_id,
            d_token_state.b_token,
            vault::get_balance(object::address_to_object(b_token_state.vault), p_token_id),
            i256::to_string(d_token_state.b0_amount),
            i256::to_string(d_token_state.last_cumulative_pnl_on_engine),
            d_token_state.single_position,
            d_token_state.last_request_i_chain_execution_fee,
            d_token_state.cumulative_unused_i_chain_execution_fee
        )
    }

    #[view]
    public fun get_cumulative_time(l_token_id: u256): (u256, u256) acquires GatewayStorage {
        let gateway_storage = borrow_global<GatewayStorage>(@deri);
        let gateway_state = &gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow(&gateway_storage.d_token_states, l_token_id);

        get_cumulative_time_internal(gateway_state, d_token_state)
    }

    #[view]
    public fun get_execution_fee(): vector<u256> acquires GatewayStorage {
        let execution_fees = borrow_global<GatewayStorage>(@deri).execution_fees;
        vector[
            execution_fees.request_add_liquidity,
            execution_fees.request_remove_liquidity,
            execution_fees.request_remove_margin,
            execution_fees.request_trade,
            execution_fees.request_trade_and_remove_margin
        ]
    }

    #[view]
    public fun get_event_signer_address(signature_bytes: vector<u8>, event_data: vector<u8>): vector<u8> {
        let signature = secp256k1::ecdsa_signature_from_bytes(vector::slice(&signature_bytes, 0, SIGNATURE_RS_LENGTH));

        let ecdsa_recover =
            secp256k1::ecdsa_recover(
                eth_signed_message_hash(event_data),
                *vector::borrow(&signature_bytes, SIGNATURE_V_INDEX) - ETH_SIGNATURE_V_OFFSET,
                &signature
            );

        let pubkey =
            aptos_hash::keccak256(
                secp256k1::ecdsa_raw_public_key_to_bytes(&option::destroy_some(ecdsa_recover))
            );
        vector::slice(&pubkey, PUBKEY_HASH_START, PUBKEY_HASH_END)
    }

    // Ethereum signed message prefix
    public fun eth_signed_message_hash(event_data: vector<u8>): vector<u8> {
        let message = ETH_PREFIX;
        vector::append(&mut message, aptos_hash::keccak256(event_data));

        aptos_hash::keccak256(message)
    }

    //////////////////////// Setters ////////////////////////

    /// Create vault implementation none
    public entry fun create_vault(admin: &signer, vault_asset: Object<Metadata>) {
        global_state::assert_is_admin(admin);
        vault::create_vault(vault_asset);
    }

    public entry fun create_vault_coin<T>(admin: &signer) {
        let vault_asset = coin_wrapper::create_fungible_asset<T>();

        global_state::assert_is_admin(admin);
        vault::create_vault(vault_asset);
    }

    public entry fun add_b_token(
        admin: &signer,
        b_token: Object<Metadata>,
        vault_address: address,
        oracle_id: String,
        collateral_factor: u256
    ) acquires GatewayStorage, GatewayParam {
        add_b_token_internal(admin, b_token, vault_address, oracle_id, collateral_factor)
    }

    public entry fun add_b_token_coin<T>(
        admin: &signer,
        vault_address: address,
        oracle_id: String,
        collateral_factor: u256
    ) acquires GatewayStorage, GatewayParam {
        let b_token = coin_wrapper::create_fungible_asset<T>();
        add_b_token_internal(admin, b_token, vault_address, oracle_id, collateral_factor)
    }

    fun add_b_token_internal(
        admin: &signer,
        b_token: Object<Metadata>,
        vault_address: address,
        oracle_id: String,
        collateral_factor: u256
    ) acquires GatewayStorage, GatewayParam {
        global_state::assert_is_admin(admin);

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global_mut<GatewayParam>(@deri);
        let b_token_states = &mut gateway_storage.b_token_states;

        let b_token_address = object::object_address(&b_token);
        let vault = object::address_to_object<Vault>(vault_address);

        assert!(vault::asset(vault) == b_token, EINVALID_BTOKEN);
        smart_table::add(
            b_token_states,
            b_token_address,
            BTokenState { vault: vault_address, oracle_id, collateral_factor }
        );

        // create store for b_token
        smart_table::upsert(&mut gateway_param.gateway_stores, b_token, create_gateway_store(b_token));

        event::emit(
            AddBToken { b_token: b_token_address, vault: vault_address, oracle_id, collateral_factor }
        );
    }

    public entry fun del_b_token(admin: &signer, b_token: Object<Metadata>) acquires GatewayStorage {
        del_b_token_internal(admin, b_token)
    }

    public entry fun del_b_token_coin<T>(admin: &signer) acquires GatewayStorage {
        let b_token = coin_wrapper::get_wrapper<T>();

        del_b_token_internal(admin, b_token)
    }


    fun del_b_token_internal(admin: &signer, b_token: Object<Metadata>) acquires GatewayStorage {
        global_state::assert_is_admin(admin);

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let b_token_states = &mut gateway_storage.b_token_states;
        let b_token_address = object::object_address(&b_token);
        let b_token_state = smart_table::borrow(b_token_states, b_token_address);

        let vault = object::address_to_object<Vault>(b_token_state.vault);
        assert!(vault::st_total_amount(vault) == 0, ENOT_DELETE_BTOKEN);

        smart_table::remove(b_token_states, b_token_address);

        event::emit(DelBToken { b_token: b_token_address });
    }

    /// This function can be used to change bToken collateral factor
    public entry fun set_b_token_parameter(
            admin: &signer,
            b_token: Object<Metadata>,
            vault_address: address,
            oracle_id: String,
            collateral_factor: u256
    ) acquires GatewayStorage {
        set_b_token_parameter_internal(admin, b_token, vault_address, oracle_id, collateral_factor)
    }

    public entry fun set_b_token_parameter_coin<T>(
        admin: &signer,
        vault_address: address,
        oracle_id: String,
        collateral_factor: u256
    ) acquires GatewayStorage {
        let b_token = coin_wrapper::get_wrapper<T>();

        set_b_token_parameter_internal(admin, b_token, vault_address, oracle_id, collateral_factor)
    }


    fun set_b_token_parameter_internal(
        admin: &signer,
        b_token: Object<Metadata>,
        vault_address: address,
        oracle_id: String,
        collateral_factor: u256
    ) acquires GatewayStorage {
        global_state::assert_is_admin(admin);

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let b_token_states = &mut gateway_storage.b_token_states;
        let b_token_address = object::object_address(&b_token);
        let b_token_state = smart_table::borrow_mut(b_token_states, b_token_address);

        let vault = object::address_to_object<Vault>(vault_address);
        assert!(vault::asset(vault) == b_token, EINVALID_BTOKEN);

        b_token_state.vault = vault_address;
        b_token_state.oracle_id = oracle_id;
        b_token_state.collateral_factor = collateral_factor;

        event::emit(UpdateBToken { b_token: b_token_address });
    }

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

        let execution_fees = &mut borrow_global_mut<GatewayStorage>(@deri).execution_fees;
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

    public entry fun set_d_chain_execution_fee_per_request(
        admin: &signer, d_chain_execution_fee_per_request: u256
    ) acquires GatewayStorage {
        global_state::assert_is_admin(admin);

        let gateway_state = &mut borrow_global_mut<GatewayStorage>(@deri).gateway_state;
        gateway_state.d_chain_execution_fee_per_request = d_chain_execution_fee_per_request;
    }

    public entry fun set_d_chain_event_signer(admin: &signer, d_chain_event_signer: vector<u8>) acquires GatewayParam {
        global_state::assert_is_admin(admin);

        let gateway_param = borrow_global_mut<GatewayParam>(@deri);
        gateway_param.d_chain_event_signer = d_chain_event_signer;
    }

    /// Claim dChain executionFee to account `to`
    public entry fun claim_d_chain_execution_fee(admin: &signer, to: address) acquires GatewayStorage, GatewayParam {
        global_state::assert_is_admin(admin);

        let gateway_state = &mut borrow_global_mut<GatewayStorage>(@deri).gateway_state;
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let gateway_store = get_gateway_store(gateway_param, get_aptos_coin_wrapper());

        let execution_fee =
            (fungible_asset::balance(gateway_store.store) as u256) - gateway_state.total_i_chain_execution_fee;
        let apt = withdraw_aptos_coin_from_store(gateway_store, execution_fee);
        supra_account::deposit_coins(to, apt);
    }

    /// Claim unused iChain execution fee for dTokenId
    public entry fun claim_unused_i_chain_execution_fee(d_token_id: u256, is_lp: bool) acquires GatewayStorage, GatewayParam {
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, d_token_id);

        let owner_addr = if (is_lp) {
            ltoken::owner(d_token_id)
        } else {
            ptoken::owner(d_token_id)
        };
        let cumulative_unused_i_chain_execution_fee = d_token_state.cumulative_unused_i_chain_execution_fee;
        if (cumulative_unused_i_chain_execution_fee > 0) {
            let total_i_chain_execution_fee = gateway_state.total_i_chain_execution_fee;
            total_i_chain_execution_fee = total_i_chain_execution_fee - cumulative_unused_i_chain_execution_fee;
            gateway_state.total_i_chain_execution_fee = total_i_chain_execution_fee;

            d_token_state.cumulative_unused_i_chain_execution_fee = 0;
            let gateway_param = borrow_global<GatewayParam>(@deri);
            let gateway_store = get_gateway_store(gateway_param, get_aptos_coin_wrapper());
            let apt = withdraw_aptos_coin_from_store(gateway_store, cumulative_unused_i_chain_execution_fee);
            supra_account::deposit_coins(owner_addr, apt);
        }
    }

    /// Redeem B0 for burning IOU
    public entry fun redeem_IOU(user: &signer, b0_amount: u256) acquires GatewayParam {
        if (b0_amount > 0) {
            let user_addr = signer::address_of(user);
            let gateway_param = borrow_global<GatewayParam>(@deri);

            let vault0 = object::address_to_object<Vault>(gateway_param.vault0);
            let b0_redeemed_asset = vault::redeem(vault0, 0, b0_amount);
            let b0_redeemed = fungible_asset::amount(&b0_redeemed_asset);
            assert!(b0_redeemed > 0, EINVALID_BTOKEN_AMOUNT);

            iou::burn(user_addr, b0_redeemed);
            primary_fungible_store::deposit(user_addr, b0_redeemed_asset);
        }
    }

    //////////////////////// Interactions ////////////////////////

    public entry fun finish_collect_protocol_fee(
        admin: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let b0_asset = finish_collect_protocol_fee_internal(admin, event_data, signature);

        let gateway_param = borrow_global<GatewayParam>(@deri);
        primary_fungible_store::deposit(gateway_param.protocol_fee_manager, b0_asset);
    }

    public entry fun finish_collect_protocol_fee_coin<T>(
        admin: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let b0_asset = finish_collect_protocol_fee_internal(admin, event_data, signature);

        let gateway_param = borrow_global<GatewayParam>(@deri);
        let b0_coin = coin_wrapper::unwrap<T>(b0_asset);

        supra_account::deposit_coins(gateway_param.protocol_fee_manager, b0_coin)
    }

    fun finish_collect_protocol_fee_internal(
        admin: &signer, event_data: vector<u8>, signature: vector<u8>
    ): FungibleAsset acquires GatewayStorage, GatewayParam {
        global_state::assert_is_admin(admin);

        let chain_id = vector_to_u256(extract_event_data(event_data, 0));
        let cumulative_collected_protocol_fee_on_engine = vector_to_u256(extract_event_data(event_data, 1));

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        assert!(
            gateway_param.d_chain_event_signer == get_event_signer_address(signature, event_data),
            ENOT_AUTHORIZED
        );
        let gateway_state = &mut gateway_storage.gateway_state;
        let fa_return = fungible_asset::zero(gateway_param.token_b0);

        assert!(chain_id == (chain_id::get() as u256), EINVALID_CHAIN_ID);
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        let cumulative_collected_protocol_fee_on_gateway = gateway_state.cumulative_collected_protocol_fee;
        if (cumulative_collected_protocol_fee_on_engine > cumulative_collected_protocol_fee_on_gateway) {
            let amount =
                safe_math256::rescale_down(
                    (cumulative_collected_protocol_fee_on_engine - cumulative_collected_protocol_fee_on_gateway),
                    SCALE_DECIMALS,
                    decimals_b0
                );
            if (amount > 0) {
                let vault0 = object::address_to_object<Vault>(gateway_param.vault0);
                let b0_asset = vault::redeem(vault0, 0, amount);
                amount = (fungible_asset::amount(&b0_asset) as u256);

                cumulative_collected_protocol_fee_on_gateway = cumulative_collected_protocol_fee_on_gateway
                    + safe_math256::rescale(amount, decimals_b0, SCALE_DECIMALS);
                gateway_state.cumulative_collected_protocol_fee = cumulative_collected_protocol_fee_on_gateway;

                event::emit(FinishCollectProtocolFee { amount });

                fungible_asset::merge(&mut fa_return, b0_asset);
            }
        };

        fa_return
    }

    /// Request to add liquidity with specified base token.
    public entry fun request_add_liquidity(
        user: &signer,
        l_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let b_token_asset = primary_fungible_store::withdraw(user, b_token, (b_amount as u64));

        request_add_liquidity_internal(user, l_token_id, b_token_asset)
    }

    public entry fun request_add_liquidity_coin<T>(
        user: &signer,
        l_token_id: u256,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let b_coin = coin::withdraw<T>(user, (b_amount as u64));
        let b_token_asset = coin_wrapper::wrap(b_coin);

        request_add_liquidity_internal(user, l_token_id, b_token_asset)
    }


    fun request_add_liquidity_internal(
        user: &signer,
        l_token_id: u256,
        b_asset: FungibleAsset
    ) acquires GatewayStorage, GatewayParam {
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let user_address = signer::address_of(user);
        let b_token = fungible_asset::metadata_from_asset(&b_asset);
        let b_amount = (fungible_asset::amount(&b_asset) as u256);
        let b_token_address = object::object_address(&b_token);
        if (l_token_id == 0) {
            l_token_id = ltoken::mint(user_address);
            smart_table::add(
                &mut gateway_storage.d_token_states,
                l_token_id,
                empty_d_token_state(b_token)
            );
        } else {
            check_l_token_id_owner(l_token_id, user_address);
        };
        check_b_token_initialized(&gateway_storage.b_token_states, b_token);

        let gateway_state = &mut gateway_storage.gateway_state;
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, b_token_address);
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, l_token_id);
        let data =
            get_data_and_check_b_token_consistency(
                gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                user_address,
                l_token_id,
                b_token
            );

        let request_add_liquidity_fee = gateway_storage.execution_fees.request_add_liquidity;

        let apt_fee_asset = coin_wrapper::wrap(coin::withdraw<SupraCoin>(user, (request_add_liquidity_fee as u64)));
        let apt_amount =
            receive_execution_fee(
                d_token_state,
                gateway_state,
                gateway_param,
                request_add_liquidity_fee,
                apt_fee_asset
            );
        assert!(b_amount != 0, EINVALID_BTOKEN_AMOUNT);

        deposit(&mut data, b_asset, gateway_param);
        get_ex_params(&mut data, b_token_state, gateway_param);

        let new_liquidity = get_d_token_liquidity(&data, gateway_param);
        save_data(&data, &mut gateway_storage.gateway_state, d_token_state);
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(
            RequestUpdateLiquidity {
                request_id,
                l_token_id,
                liquidity: new_liquidity,
                last_cumulative_pnl_on_engine: i256::to_string(data.last_cumulative_pnl_on_engine),
                cumulative_pnl_on_gateway: i256::to_string(data.cumulative_pnl_on_gateway),
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
        request_remove_liquidity_internal(user, l_token_id, b_token, b_amount);
    }

    public entry fun request_remove_liquidity_coin<T>(
        user: &signer,
        l_token_id: u256,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let b_token = coin_wrapper::get_wrapper<T>();

        request_remove_liquidity_internal(user, l_token_id, b_token, b_amount);
    }

    fun request_remove_liquidity_internal(
        user: &signer,
        l_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let user_address = signer::address_of(user);
        let b_token_address = object::object_address(&b_token);
        check_l_token_id_owner(l_token_id, user_address);

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);

        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, l_token_id);
        // original_b_token user is deposit b token, not current operate token, which is `b_token`
        // for example, original_b_token may be ETH, lp initially deposited ETH to provide liquidity
        // later, LP may request to remove ETH, or token b0 USDC which is his cumulated PNL
        // note: currently we only have token b0, this functionality is not supported yet, so original_b_token === b_token
        let original_b_token = d_token_state.b_token;
        let original_b_token_address = object::object_address(&original_b_token);
        let original_b_token_state = smart_table::borrow(&gateway_storage.b_token_states, original_b_token_address);

        let request_remove_liquidity_fee = gateway_storage.execution_fees.request_remove_liquidity;
        let apt_fee_asset = coin_wrapper::wrap(
            coin::withdraw<SupraCoin>(user, (request_remove_liquidity_fee as u64))
        );
        receive_execution_fee(
            d_token_state,
            gateway_state,
            gateway_param,
            request_remove_liquidity_fee,
            apt_fee_asset
        );
        assert!(b_amount != 0, EINVALID_BTOKEN_AMOUNT);

        let data = get_data(
            gateway_state,
            original_b_token_state,
            d_token_state,
            user_address,
            l_token_id,
            original_b_token
        );

        get_ex_params(&mut data, original_b_token_state, gateway_param);
        let old_liquidity = get_d_token_liquidity(&data, gateway_param);
        let new_liquidity =
            if (data.b_token == b_token) {
                get_d_token_liquidity_with_remove(&data, gateway_param, b_amount)
            } else if (b_token == gateway_param.token_b0) {
                get_d_token_liquidity_with_remove_b0(&data, gateway_param, b_amount)
            } else {
                abort error::invalid_argument(EINVALID_BTOKEN)
            };

        if (new_liquidity <= old_liquidity / 100) {
            new_liquidity = 0;
        };

        d_token_state.current_operate_token = b_token_address;
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(
            RequestUpdateLiquidity {
                request_id,
                l_token_id,
                liquidity: new_liquidity,
                last_cumulative_pnl_on_engine: i256::to_string(data.last_cumulative_pnl_on_engine),
                cumulative_pnl_on_gateway: i256::to_string(data.cumulative_pnl_on_gateway),
                remove_b_amount: b_amount
            }
        )
    }

    /// Request to add margin with specified base token.
    public entry fun request_add_margin(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256,
        single_position: bool
    ) acquires GatewayStorage, GatewayParam {
        let b_token_asset = primary_fungible_store::withdraw(user, b_token, (b_amount as u64));

        request_add_margin_internal(user, p_token_id, b_token_asset, single_position);
    }

    public entry fun request_add_margin_coin<T>(
        user: &signer,
        p_token_id: u256,
        b_amount: u256,
        single_position: bool
    ) acquires GatewayStorage, GatewayParam {
        let b_token_coin = coin::withdraw<T>(user, (b_amount as u64));

        request_add_margin_internal(user, p_token_id, coin_wrapper::wrap(b_token_coin), single_position);
    }

    #[deprecated]
    public entry fun request_add_margin_b0(user: &signer, p_token_id: u256, b0_amount: u256) {
        // let gateway_param = borrow_global<GatewayParam>(@deri);
        // let token_b0 = gateway_param.token_b0;
        // let b0_asset = primary_fungible_store::withdraw(user, token_b0, (b0_amount as u64));

        // request_add_margin_b0_internal(user, p_token_id, b0_asset);
        abort error::aborted(EDEPRECATED)
    }

    #[deprecated]
    public entry fun request_add_margin_b0_coin<T>(user: &signer, p_token_id: u256, b0_amount: u256) {
        // let b0_coin = coin::withdraw<T>(user, (b0_amount as u64));
        // let b0_asset = coin_wrapper::wrap(b0_coin);

        // request_add_margin_b0_internal(user, p_token_id, b0_asset);
        abort error::aborted(EDEPRECATED)
    }

    fun request_add_margin_b0_internal(user: &signer, p_token_id: u256, b0_asset: FungibleAsset) acquires GatewayParam, GatewayStorage {
        let user_addr = signer::address_of(user);
        let b0_amount = (fungible_asset::amount(&b0_asset) as u256);
        let token_b0 = fungible_asset::metadata_from_asset(&b0_asset);
        assert!(b0_amount > 0, EINVALID_BTOKEN_AMOUNT);
        check_p_token_id_owner(p_token_id, user_addr);
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);

        vault::deposit(object::address_to_object(gateway_param.vault0), 0, b0_asset);

        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);
        d_token_state.b0_amount = i256::wrapping_add(d_token_state.b0_amount, i256::from(b0_amount));

        let gateway_state = &mut gateway_storage.gateway_state;
        let request_id = increment_request_id(gateway_state, d_token_state);

        event::emit(
            FinishAddMargin { request_id, p_token_id, b_token: object::object_address(&token_b0), b_amount: b0_amount }
        );
    }

    /// Request to remove margin with specified base token.
    public entry fun request_remove_margin(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        request_remove_margin_internal(user, p_token_id, b_token, b_amount);
    }

    public entry fun request_remove_margin_coin<T>(
        user: &signer,
        p_token_id: u256,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let b_token = coin_wrapper::get_wrapper<T>();
        request_remove_margin_internal(user, p_token_id, b_token, b_amount);
    }

    fun request_remove_margin_internal(
        user: &signer,
        p_token_id: u256,
        b_token: Object<Metadata>,
        b_amount: u256
    ) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        assert!(b_amount > 0, EINVALID_BTOKEN_AMOUNT);
        check_p_token_id_owner(p_token_id, user_addr);
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);

        let gateway_state = &mut gateway_storage.gateway_state;
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, object::object_address(&b_token));
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);

        let request_remove_margin_fee = gateway_storage.execution_fees.request_remove_margin;
        let apt_fee_asset = coin_wrapper::wrap(
            coin::withdraw<SupraCoin>(user, (request_remove_margin_fee as u64))
        );
        receive_execution_fee(
            d_token_state,
            gateway_state,
            gateway_param,
            request_remove_margin_fee,
            apt_fee_asset
        );

        let data =
            get_data_and_check_b_token_consistency(
                gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                user_addr,
                p_token_id,
                b_token
            );

        get_ex_params(&mut data, b_token_state, gateway_param);
        let old_margin = get_d_token_liquidity(&data, gateway_param);
        let new_margin = get_d_token_liquidity_with_remove(&data, gateway_param, b_amount);
        if (new_margin <= old_margin / 100) {
            new_margin = 0;
        };
        let request_id = increment_request_id(gateway_state, d_token_state);

        event::emit(
            RequestRemoveMargin {
                request_id,
                p_token_id,
                real_money_margin: new_margin,
                last_cumulative_pnl_on_engine: i256::to_string(data.last_cumulative_pnl_on_engine),
                cumulative_pnl_on_gateway: i256::to_string(data.cumulative_pnl_on_gateway),
                b_amount
            }
        )
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

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);

        let request_trade_fee = gateway_storage.execution_fees.request_trade;
        let apt_fee_asset = coin_wrapper::wrap(coin::withdraw<SupraCoin>(user, (request_trade_fee as u64)));
        receive_execution_fee(
            d_token_state,
            gateway_state,
            gateway_param,
            request_trade_fee,
            apt_fee_asset
        );

        let b_token_state =
            smart_table::borrow(
                &gateway_storage.b_token_states,
                object::object_address(&d_token_state.b_token)
            );

        let data = get_data(
            gateway_state,
            b_token_state,
            d_token_state,
            user_addr,
            p_token_id,
            gateway_param.token_b0
        );
        get_ex_params(&mut data, b_token_state, gateway_param);

        let real_money_margin = get_d_token_liquidity(&data, gateway_param);
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);
        let trade_params_i265 = vector::map(trade_params, (|x| i256::to_string(i256::from_uncheck(x))));

        event::emit(
            RequestTrade {
                request_id,
                p_token_id,
                real_money_margin,
                last_cumulative_pnl_on_engine: i256::to_string(data.last_cumulative_pnl_on_engine),
                cumulative_pnl_on_gateway: i256::to_string(data.cumulative_pnl_on_gateway),
                symbol_id,
                trade_params: trade_params_i265
            }
        )
    }

    /// Request to liquidate a specified PToken.
    public entry fun request_liquidate(_user: &signer, p_token_id: u256) acquires GatewayStorage, GatewayParam {
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);

        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);
        let b_token_state =
            smart_table::borrow(
                &gateway_storage.b_token_states,
                object::object_address(&d_token_state.b_token)
            );

        let data =
            get_data(
                &gateway_storage.gateway_state,
                b_token_state,
                d_token_state,
                ptoken::owner(p_token_id),
                p_token_id,
                gateway_param.token_b0
            );
        get_ex_params(&mut data, b_token_state, gateway_param);

        let real_money_margin = get_d_token_liquidity(&data, gateway_param);
        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(
            RequestLiquidate {
                request_id,
                p_token_id,
                real_money_margin,
                last_cumulative_pnl_on_engine: i256::to_string(data.last_cumulative_pnl_on_engine),
                cumulative_pnl_on_gateway: i256::to_string(data.cumulative_pnl_on_gateway)
            }
        )
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
        let b_token_asset = primary_fungible_store::withdraw(user, b_token, (b_amount as u64));
        p_token_id = request_add_margin_internal(user, p_token_id, b_token_asset, single_position);
        request_trade(user, p_token_id, symbol_id, trade_params);
    }

    public entry fun request_add_margin_and_trade_coin<T>(
        user: &signer,
        p_token_id: u256,
        b_amount: u256,
        symbol_id: vector<u8>,
        trade_params: vector<u256>,
        single_position: bool
    ) acquires GatewayStorage, GatewayParam {
        let b_token_coin = coin::withdraw<T>(user, (b_amount as u64));


        p_token_id = request_add_margin_internal(user, p_token_id, coin_wrapper::wrap(b_token_coin), single_position);
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
        request_trade_and_remove_margin_internal(user, p_token_id, b_token, b_amount, symbol_id, trade_params);
    }

    public entry fun request_trade_and_remove_margin_coin<T>(
        user: &signer,
        p_token_id: u256,
        b_amount: u256,
        symbol_id: vector<u8>,
        trade_params: vector<u256>
    ) acquires GatewayStorage, GatewayParam {
        let b_token = coin_wrapper::get_wrapper<T>();
        request_trade_and_remove_margin_internal(user, p_token_id, b_token, b_amount, symbol_id, trade_params);
    }

    fun request_trade_and_remove_margin_internal(
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

        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);

        let request_trade_and_remove_margin_fee = gateway_storage.execution_fees.request_trade_and_remove_margin;
        let apt_fee_asset =
            coin_wrapper::wrap(
                coin::withdraw<SupraCoin>(user, (request_trade_and_remove_margin_fee as u64))
            );
        receive_execution_fee(
            d_token_state,
            gateway_state,
            gateway_param,
            request_trade_and_remove_margin_fee,
            apt_fee_asset
        );

        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, object::object_address(&b_token));

        let data =
            get_data_and_check_b_token_consistency(
                gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                user_addr,
                p_token_id,
                b_token
            );
        get_ex_params(&mut data, b_token_state, gateway_param);

        let old_margin = get_d_token_liquidity(&data, gateway_param);
        let new_margin = get_d_token_liquidity_with_remove(&data, gateway_param, b_amount);
        if (new_margin <= old_margin / 100) {
            new_margin = 0;
        };

        let request_id = increment_request_id(&mut gateway_storage.gateway_state, d_token_state);

        event::emit(
            RequestTradeAndRemoveMargin {
                request_id,
                p_token_id,
                real_money_margin: new_margin,
                last_cumulative_pnl_on_engine: i256::to_string(data.last_cumulative_pnl_on_engine),
                cumulative_pnl_on_gateway: i256::to_string(data.cumulative_pnl_on_gateway),
                b_amount,
                symbol_id,
                trade_params: vector::map(trade_params, (|x| i256::to_string(i256::from_uncheck(x))))
            }
        )
    }

    /// Finalize the liquidity update based on event emitted on d-chain.
    /// eventData: the encoded event data containing information about the liquidity update, emitted on d-chain.
    /// signature: the signature used to verify the event data.
    public entry fun finish_update_liquidity(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let (account_addr, b_amount_to_remove_asset) = finish_update_liquidity_internal(user, event_data, signature);

        primary_fungible_store::deposit(account_addr, b_amount_to_remove_asset);
    }

    public entry fun finish_update_liquidity_coin<T>(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let (account_addr, fa) = finish_update_liquidity_internal(user, event_data, signature);

        let b_amount_to_remove_coin = coin_wrapper::unwrap<T>(fa);
        supra_account::deposit_coins(account_addr, b_amount_to_remove_coin);
    }

    fun finish_update_liquidity_internal(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ): (address, FungibleAsset) acquires GatewayStorage, GatewayParam {
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);

        let request_id = vector_to_u256(extract_event_data(event_data, 0));
        let l_token_id = vector_to_u256(extract_event_data(event_data, 1));
        let liquidity = vector_to_u256(extract_event_data(event_data, 2));
        let total_liquidity = vector_to_u256(extract_event_data(event_data, 3));
        let cumulative_pnl_on_engine = i256::from_uncheck(vector_to_u256(extract_event_data(event_data, 4)));
        let b_amount_to_remove = vector_to_u256(extract_event_data(event_data, 5));

        assert!(
            get_event_signer_address(signature, event_data) == gateway_param.d_chain_event_signer,
            ENOT_AUTHORIZED
        );

        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, l_token_id);
        let fa_return = fungible_asset::zero(gateway_param.token_b0);

        check_request_id(d_token_state, request_id);
        update_liquidity(gateway_state, d_token_state, liquidity, total_liquidity);

        // Cumulate unsettled PNL to b0_amount
        let b_token = d_token_state.b_token;
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, object::object_address(&b_token));
        let data =
            get_data_and_check_b_token_consistency(
                gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                ltoken::owner(l_token_id),
                l_token_id,
                b_token
            );

        let (diff, _) = i256::overflowing_sub(
            cumulative_pnl_on_engine,
            data.last_cumulative_pnl_on_engine
        );
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        data.b0_amount = i256::wrapping_add(
            data.b0_amount,
            i256::rescale(diff, SCALE_DECIMALS, decimals_b0)
        );
        data.last_cumulative_pnl_on_engine = cumulative_pnl_on_engine;

        let b_amount_removed = 0;
        let operate_token = object::object_address(&data.b_token);
        if (b_amount_to_remove != 0) {
            operate_token = d_token_state.current_operate_token;
            if (object::object_address(&data.b_token) == operate_token) {
                get_ex_params(&mut data, b_token_state, gateway_param);
                let transfer_out_amount = if (liquidity == 0) {
                    MAX_AS_U256
                } else {
                    b_amount_to_remove
                };
                let (b_amount_removed_from_transfer_out, _, fa) = transfer_out(&mut data, gateway_param, transfer_out_amount, false);
                b_amount_removed = b_amount_removed_from_transfer_out;
                fungible_asset::merge(&mut fa_return, fa);
            } else {
                assert!(
                    operate_token == object::object_address(&gateway_param.token_b0),
                    EINVALID_OPERATE_TOKEN
                );

                if (i256::is_greater_than_zero(data.b0_amount)) {
                    let b_amount_removed_asset =
                        vault::redeem(
                            object::address_to_object<Vault>(gateway_param.vault0),
                            0,
                            safe_math256::min(b_amount_to_remove, i256::as_u256(data.b0_amount))
                        );
                    let b_amount_removed = (fungible_asset::amount(&b_amount_removed_asset) as u256);
                    data.b0_amount = i256::wrapping_sub(data.b0_amount, i256::from(b_amount_removed));

                    let b_amount_to_remove_asset =
                        fungible_asset::extract(&mut b_amount_removed_asset, (b_amount_to_remove as u64));
                    fungible_asset::merge(&mut fa_return, b_amount_to_remove_asset);

                    let gateway_store = smart_table::borrow(&gateway_param.gateway_stores, gateway_param.token_b0);
                    fungible_asset::deposit(gateway_store.store, b_amount_removed_asset);
                }
            }
        };

        save_data(&data, gateway_state, d_token_state);
        transfer_last_request_ichain_execution_fee(
            gateway_param,
            d_token_state,
            gateway_state,
            signer::address_of(user)
        );

        if (b_amount_to_remove == 0) {
            // If bAmountToRemove == 0, it is a AddLiqudiity finalization
            event::emit(
                FinishAddLiquidity { request_id, l_token_id, liquidity, total_liquidity }
            )
        } else {
            // If bAmountToRemove != 0, it is a RemoveLiquidity finalization
            event::emit(
                FinishRemoveLiquidity {
                    request_id,
                    l_token_id,
                    liquidity,
                    total_liquidity,
                    b_token: operate_token,
                    b_amount: b_amount_removed
                }
            )
        };

        (data.account, fa_return)
    }

    /// Finalize the remove of margin based on event emitted on d-chain.
    public entry fun finish_remove_margin(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let (account_addr, fa) = finish_remove_margin_internal(user, event_data, signature);
        primary_fungible_store::deposit(account_addr, fa);
    }

    public entry fun finish_remove_margin_coin<T>(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let (account_addr, fa) = finish_remove_margin_internal(user, event_data, signature);

        let b_amount_to_remove_coin = coin_wrapper::unwrap<T>(fa);
        supra_account::deposit_coins(account_addr, b_amount_to_remove_coin);
    }

    fun finish_remove_margin_internal(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ): (address, FungibleAsset) acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let fa_return = fungible_asset::zero(gateway_param.token_b0);

        let request_id = vector_to_u256(extract_event_data(event_data, 0));
        let p_token_id = vector_to_u256(extract_event_data(event_data, 1));
        let required_margin = vector_to_u256(extract_event_data(event_data, 2));
        let cumulative_pnl_on_engine = i256::from_uncheck(vector_to_u256(extract_event_data(event_data, 3)));
        let b_amount_to_remove = vector_to_u256(extract_event_data(event_data, 4));

        let gateway_param = borrow_global<GatewayParam>(@deri);
        assert!(
            get_event_signer_address(signature, event_data) == gateway_param.d_chain_event_signer,
            ENOT_AUTHORIZED
        );

        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);
        let b_token = d_token_state.b_token;
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, object::object_address(&b_token));

        check_request_id(d_token_state, request_id);
        let data =
            get_data_and_check_b_token_consistency(
                &gateway_storage.gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                ptoken::owner(p_token_id),
                p_token_id,
                b_token
            );

        let (diff, _) = i256::overflowing_sub(
            cumulative_pnl_on_engine,
            data.last_cumulative_pnl_on_engine
        );
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        data.b0_amount = i256::wrapping_add(
            data.b0_amount,
            i256::rescale(diff, SCALE_DECIMALS, decimals_b0)
        );
        data.last_cumulative_pnl_on_engine = cumulative_pnl_on_engine;

        get_ex_params(&mut data, b_token_state, gateway_param);
        let (b_amount, _, fa) = transfer_out(&mut data, gateway_param, b_amount_to_remove, true);
        fungible_asset::merge(&mut fa_return, fa);
        assert!(
            get_d_token_liquidity(&data, gateway_param) >= required_margin,
            EINSUFFICIENT_MARGIN
        );

        let gateway_state = &mut gateway_storage.gateway_state;
        save_data(&data, gateway_state, d_token_state);
        transfer_last_request_ichain_execution_fee(gateway_param, d_token_state, gateway_state, user_addr);

        event::emit(
            FinishRemoveMargin { request_id, p_token_id, b_token: object::object_address(&data.b_token), b_amount }
        );

        (data.account, fa_return)
    }

    /// Finalize the liquidation based on event emitted on d-chain.
    public entry fun finish_liquidate(
        user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let _requester = extract_event_data(event_data, 0);
        let executor = extract_event_data(event_data, 1);
        let finisher = extract_event_data(event_data, 2);
        let request_id = vector_to_u256(extract_event_data(event_data, 3));
        let p_token_id = vector_to_u256(extract_event_data(event_data, 4));
        let cumulative_pnl_on_engine = vector_to_u256(extract_event_data(event_data, 5));
        let _maintenance_margin_required = vector_to_u256(extract_event_data(event_data, 6));

        let gateway_param = borrow_global<GatewayParam>(@deri);
        assert!(
            get_event_signer_address(signature, event_data) == gateway_param.d_chain_event_signer,
            ENOT_AUTHORIZED
        );

        finish_liquidate_internal(
            user,
            _requester,
            executor,
            finisher,
            request_id,
            p_token_id,
            i256::from_uncheck(cumulative_pnl_on_engine),
            i256::from_uncheck(_maintenance_margin_required)
        );
    }

    fun finish_liquidate_internal(
        _user: &signer,
        _requester: vector<u8>,
        executor: vector<u8>,
        finisher: vector<u8>,
        request_id: u256,
        p_token_id: u256,
        cumulative_pnl_on_engine: I256,
        _maintenance_margin_required: I256
    ) acquires GatewayStorage, GatewayParam {
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);

        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);
        let b_token = d_token_state.b_token;

        let data =
            get_data_and_check_b_token_consistency(
                &gateway_storage.gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                ptoken::owner(p_token_id),
                p_token_id,
                b_token
            );
        let (diff, _) = i256::overflowing_sub(
            cumulative_pnl_on_engine,
            data.last_cumulative_pnl_on_engine
        );
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        data.b0_amount = i256::wrapping_add(
            data.b0_amount,
            i256::rescale(diff, SCALE_DECIMALS, decimals_b0)
        );
        data.last_cumulative_pnl_on_engine = cumulative_pnl_on_engine;

        let b0_amount_in = 0;
        let gateway_b_store = smart_table::borrow(&gateway_param.gateway_stores, b_token);

        {
            let b_asset = vault::redeem(
                object::address_to_object<Vault>(data.vault),
                data.d_token_id,
                MAX_AS_U256
            );
            let b_amount = (fungible_asset::amount(&b_asset) as u256);
            fungible_asset::deposit(gateway_b_store.store, b_asset);

            if (data.b_token == gateway_param.token_b0) {
                b0_amount_in = b0_amount_in + b_amount;
            } else {
                // TODO: liquidateRedeemAndSwap
                abort error::not_implemented(ENOT_IMPLEMENTED)
            }
        };

        // All Lp's PNL by liquidating this trader
        let lp_pnl = i256::wrapping_add(data.b0_amount, i256::from(b0_amount_in));
        let reward =
            calculate_reward(
                lp_pnl,
                gateway_param.min_liquidation_reward,
                gateway_param.max_liquidation_reward,
                gateway_param.liquidation_reward_cut_ratio
            );
        let (reward, b0_amount_in) =
            process_reward(
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
            let gateway_b_store = smart_table::borrow(&gateway_param.gateway_stores, gateway_param.token_b0);
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
        save_data(&data, gateway_state, d_token_state);

        {
            let last_request_ichain_execution_fee = d_token_state.last_request_i_chain_execution_fee;
            let cumulative_unused_i_chain_execution_fee = d_token_state.cumulative_unused_i_chain_execution_fee;

            d_token_state.last_request_i_chain_execution_fee = 0;
            d_token_state.cumulative_unused_i_chain_execution_fee = 0;

            gateway_state.total_i_chain_execution_fee = gateway_state.total_i_chain_execution_fee
                - (last_request_ichain_execution_fee + cumulative_unused_i_chain_execution_fee)
        };

        ptoken::burn(p_token_id);

        event::emit(FinishLiquidate { request_id, p_token_id, lp_pnl: i256::to_string(lp_pnl) })
    }

    /// Claim reward for excutor and finisher for finishing liquidation.
    public entry fun claim_reward_liquidate(
        _user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayParam {
        let (account_addr, fa) = claim_reward_liquidate_internal(_user, event_data, signature);

        primary_fungible_store::deposit(account_addr, fa);
    }

    public entry fun claim_reward_liquidate_coin<T>(
        _user: &signer, event_data: vector<u8>, signature: vector<u8>
    ) acquires GatewayParam {
        let (account_addr, fa) = claim_reward_liquidate_internal(_user, event_data, signature);

        let reward_coin = coin_wrapper::unwrap<T>(fa);
        supra_account::deposit_coins(account_addr, reward_coin);
    }

    fun claim_reward_liquidate_internal(
        _user: &signer, event_data: vector<u8>, signature: vector<u8>
    ): (address, FungibleAsset) acquires GatewayParam {
        let chain_id = vector_to_u256(extract_event_data(event_data, 0));
        let module_address = from_bcs::to_address(extract_event_data(event_data, 1));
        let user_address = extract_event_data(event_data, 2);
        let recepient = from_bcs::to_address(extract_event_data(event_data, 3));

        assert!(chain_id == (chain_id::get() as u256), EINVALID_CHAIN_ID);
        assert!(module_address == @deri, ENOT_AUTHORIZED);

        let gateway_param = borrow_global<GatewayParam>(@deri);
        assert!(
            get_event_signer_address(signature, event_data) == gateway_param.d_chain_event_signer,
            ENOT_AUTHORIZED
        );

        let fa = reward_store::claim_reward(user_address, gateway_param.token_b0);

        (recepient, fa)
    }

    public fun extract_event_data(event_data: vector<u8>, position: u64): vector<u8> {
        let start_byte = position * 32;
        let end_byte = start_byte + 32;

        vector::slice(&event_data, start_byte, end_byte)
    }

    public fun vector_to_u256(data: vector<u8>): u256 {
        vector::reverse(&mut data);

        from_bcs::to_u256(data)
    }

    //////////////////////// Internal functions ////////////////////////

    fun request_add_margin_internal(
        user: &signer,
        p_token_id: u256,
        b_token_asset: FungibleAsset,
        single_position: bool
    ): u256 acquires GatewayStorage, GatewayParam {
        let user_addr = signer::address_of(user);
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let b_token = fungible_asset::metadata_from_asset(&b_token_asset);
        let b_amount = (fungible_asset::amount(&b_token_asset) as u256);

        assert!(b_amount > 0, EINVALID_BTOKEN_AMOUNT);

        if (p_token_id == 0) {
            p_token_id = ptoken::mint(user_addr);
            smart_table::add(
                &mut gateway_storage.d_token_states,
                p_token_id,
                empty_d_token_state(b_token)
            );

            if (single_position) {
                let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);
                d_token_state.single_position = true;
            }
        } else {
            check_p_token_id_owner(p_token_id, signer::address_of(user));
        };
        check_b_token_initialized(&gateway_storage.b_token_states, b_token);

        let gateway_state = &mut gateway_storage.gateway_state;
        let d_token_state = smart_table::borrow_mut(&mut gateway_storage.d_token_states, p_token_id);

        let data =
            get_data_and_check_b_token_consistency(
                gateway_state,
                &gateway_storage.b_token_states,
                d_token_state,
                user_addr,
                p_token_id,
                b_token
            );

        deposit(&mut data, b_token_asset, gateway_param);

        save_data(&data, gateway_state, d_token_state);
        let request_id = increment_request_id(gateway_state, d_token_state);

        event::emit(
            FinishAddMargin { request_id, p_token_id, b_token: object::object_address(&b_token), b_amount }
        );

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
        b_token_states: &SmartTable<address, BTokenState>,
        d_token_state: &DTokenState,
        account: address,
        d_token_id: u256,
        b_token: Object<Metadata>
    ): Data {
        let b_token_state = smart_table::borrow(b_token_states, object::object_address(&b_token));
        let data = get_data(
            gateway_state,
            b_token_state,
            d_token_state,
            account,
            d_token_id,
            b_token
        );
        check_b_token_consistency(d_token_state, b_token_states, d_token_id, b_token);
        data
    }

    fun save_data(
        self: &Data, gateway_state: &mut GatewayState, d_token_state: &mut DTokenState
    ) {
        gateway_state.cumulative_pnl_on_gateway = self.cumulative_pnl_on_gateway;

        d_token_state.b_token = self.b_token;
        d_token_state.b0_amount = self.b0_amount;
        d_token_state.last_cumulative_pnl_on_engine = self.last_cumulative_pnl_on_engine;
    }

    /// Check callback's requestId is the same as the current request_id stored for user
    /// If a new request is submitted before the callback for last request, request_id will not match,
    /// and this callback cannot be executed anymore
    fun check_request_id(d_token_state: &mut DTokenState, request_id: u256) {
        let user_request_id = i256::lower_128_bits(request_id);
        assert!(d_token_state.request_id == user_request_id, EINVALD_REQUEST_ID);
        d_token_state.request_id = d_token_state.request_id + 1;
    }

    /// Increment gateway requestId and user requestId and returns the combined requestId for this request
    fun increment_request_id(gateway_state: &mut GatewayState, d_token_state: &mut DTokenState): u256 {
        let gateway_request_id = gateway_state.gateway_request_id + 1;
        gateway_state.gateway_request_id = gateway_request_id;

        let user_request_id = d_token_state.request_id + 1;
        d_token_state.request_id = user_request_id;
        (gateway_request_id << 128) + user_request_id
    }

    fun check_b_token_initialized(
        b_token_states: &SmartTable<address, BTokenState>, b_token: Object<Metadata>
    ) {
        let b_token_address = object::object_address(&b_token);
        assert!(smart_table::contains(b_token_states, b_token_address), EINVALID_BTOKEN);
    }

    fun check_b_token_consistency(
        d_token_state: &DTokenState,
        b_token_states: &SmartTable<address, BTokenState>,
        d_token_id: u256,
        b_token: Object<Metadata>
    ) {
        let pre_b_token = d_token_state.b_token;
        let pre_b_token_addr = object::object_address(&pre_b_token);
        let pre_b_token_state = smart_table::borrow(b_token_states, pre_b_token_addr);
        if (pre_b_token_addr != ZERO_ADDRESS && pre_b_token != b_token) {
            let vault_address = pre_b_token_state.vault;

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
        let p_token_addr = ptoken::get_token_address(p_token_id);
        let p_token = object::address_to_object<PToken>(p_token_addr);
        assert!(object::owner(p_token) == user_address, EINVALID_PTOKEN_ID);
    }

    fun receive_execution_fee(
        d_token_state: &mut DTokenState,
        gateway_state: &mut GatewayState,
        gateway_param: &GatewayParam,
        execution_fee: u256,
        apt_asset: FungibleAsset
    ): u256 {
        let value = (fungible_asset::amount(&apt_asset) as u256);
        let d_chain_execution_fee = gateway_state.d_chain_execution_fee_per_request;
        assert!(value >= execution_fee, EINSUFFICIENT_EXECUTION_FEE);

        // Difference EVM, ETH fee can transfer directly to the gateway by msg.value, but in Aptos, we need to transfer it manually
        let gateway_store = get_gateway_store(gateway_param, get_aptos_coin_wrapper());
        fungible_asset::deposit(gateway_store.store, apt_asset);

        let i_chain_execution_fee = execution_fee - d_chain_execution_fee;
        gateway_state.total_i_chain_execution_fee = gateway_state.total_i_chain_execution_fee + i_chain_execution_fee;

        let last_request_i_chain_execution_fee = d_token_state.last_request_i_chain_execution_fee;
        let cumulative_unused_i_chain_execution_fee = d_token_state.cumulative_unused_i_chain_execution_fee;
        cumulative_unused_i_chain_execution_fee = cumulative_unused_i_chain_execution_fee
            + last_request_i_chain_execution_fee;
        last_request_i_chain_execution_fee = i_chain_execution_fee;

        d_token_state.last_request_i_chain_execution_fee = last_request_i_chain_execution_fee;
        d_token_state.cumulative_unused_i_chain_execution_fee = cumulative_unused_i_chain_execution_fee;

        value - execution_fee
    }

    fun transfer_last_request_ichain_execution_fee(
        gateway_param: &GatewayParam,
        d_token_state: &mut DTokenState,
        gateway_state: &mut GatewayState,
        to: address
    ) {
        let last_request_i_chain_execution_fee = d_token_state.last_request_i_chain_execution_fee;
        if (last_request_i_chain_execution_fee > 0) {
            gateway_state.total_i_chain_execution_fee = gateway_state.total_i_chain_execution_fee
                - last_request_i_chain_execution_fee;
            d_token_state.last_request_i_chain_execution_fee = 0;

            let gateway_store = get_gateway_store(gateway_param, get_aptos_coin_wrapper());
            let apt_wrapper_asset =
                fungible_asset::withdraw(
                    &object::generate_signer_for_extending(&gateway_store.store_extend_ref),
                    gateway_store.store,
                    (last_request_i_chain_execution_fee as u64)
                );
            supra_account::deposit_coins(to, coin_wrapper::unwrap<SupraCoin>(apt_wrapper_asset));
        }
    }

    /// b_price * b_amount / UONE = b0_amount, b0_amount in decimals_b0
    fun get_b_price(b_token: Object<Metadata>, gateway_param: &GatewayParam): u256 {
        if (b_token == gateway_param.token_b0) { UONE }
        else {
            // TODO: get b_price from oracle
            abort error::not_implemented(ENOT_IMPLEMENTED)
        }
    }

    fun get_ex_params(
        self: &mut Data, b_token_state: &BTokenState, gateway_param: &GatewayParam
    ) {
        self.collateral_factor = b_token_state.collateral_factor;
        self.b_price = get_b_price(self.b_token, gateway_param);
    }

    /// Calculate the liquidity associated with current dTokenId
    fun get_d_token_liquidity(self: &Data, gateway_param: &GatewayParam): u256 {
        let b0_amount_in_vault =
            (((vault::get_balance(
                object::address_to_object<Vault>(self.vault),
                self.d_token_id
            ) * self.b_price) / UONE) * self.collateral_factor) / UONE;
        let b0_shortage = if (i256::is_greater_than_zero(self.b0_amount)) { 0 }
        else {
            i256::abs_u256(self.b0_amount)
        };

        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        if (b0_amount_in_vault >= b0_shortage) {
            if (i256::is_greater_than_zero(self.b0_amount)) {
                safe_math256::rescale(
                    (b0_amount_in_vault + i256::abs_u256(self.b0_amount)),
                    decimals_b0,
                    SCALE_DECIMALS
                )
            } else {
                safe_math256::rescale(
                    (b0_amount_in_vault - i256::abs_u256(self.b0_amount)),
                    decimals_b0,
                    SCALE_DECIMALS
                )
            }
        } else { 0 }
    }

    /// Calculate the liquidity associated with current dTokenId if `bAmount` in bToken is removed
    fun get_d_token_liquidity_with_remove(
        self: &Data, gateway_param: &GatewayParam, b_amount: u256
    ): u256 {
        let liquidity = 0;
        // make sure b_amount * b_price won't overflow
        if (b_amount < MAX_AS_U256 / self.b_price) {
            let b_amount_in_vault = vault::get_balance(object::address_to_object<Vault>(self.vault), self.d_token_id);
            if (b_amount >= b_amount_in_vault) {
                if (i256::is_greater_than_zero(self.b0_amount)) {
                    let b0_shortage = ((b_amount - b_amount_in_vault) * self.b_price) / UONE;
                    let b0_amount = i256::as_u256(self.b0_amount);
                    if (b0_amount > b0_shortage) {
                        liquidity = b0_amount - b0_shortage;
                    }
                }
            } else {
                // discounted
                let b0_excessive = ((((b_amount_in_vault - b_amount) * self.b_price) / UONE) * self.collateral_factor) / UONE;
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
        let b_amount_in_vault = vault::get_balance(object::address_to_object<Vault>(self.vault), self.d_token_id);
        // discounted
        let b0_value_of_b_amount_in_vault = b_amount_in_vault * self.b_price / UONE * self.collateral_factor / UONE;
        let b0_total =
            if (!i256::is_neg(self.b0_amount)) {
                b0_value_of_b_amount_in_vault + i256::as_u256(self.b0_amount)
            } else if (b0_value_of_b_amount_in_vault > i256::abs_u256(self.b0_amount)) {
                b0_value_of_b_amount_in_vault - i256::abs_u256(self.b0_amount)
            } else { 0 };

        if (b0_total > b0_amount_to_remove) {
            let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
            safe_math256::rescale(b0_total - b0_amount_to_remove, decimals_b0, SCALE_DECIMALS)
        } else { 0 }
    }

    fun deposit(data: &mut Data, b_token_asset: FungibleAsset, gateway_param: &GatewayParam) {
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
    ): (u256, address, FungibleAsset) {
        let fa_return = fungible_asset::zero(gateway_param.token_b0);
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
                b_amount = b_amount + i256::abs_u256(data.b0_amount);
            } else {
                b_amount = b_amount + i256::abs_u256(data.b0_amount) * UONE / data.b_price * 105 / 100;
            }
        };

        // Redeem tokens from the vault
        // currently only support vault implementation none
        let vault_obj = object::address_to_object<Vault>(data.vault);
        let b_fungible_asset = vault::redeem(vault_obj, data.d_token_id, b_amount);
        b_amount = (fungible_asset::amount(&b_fungible_asset) as u256);
        fungible_asset::deposit(token_b_store.store, b_fungible_asset);

        // Amount of B0 tokens going to reserves.
        let b0_amount_in = 0;
        // Amount of B0 tokens going to user.
        let b0_amount_out = 0;
        // Amount of IOU tokens going to the trader.
        let iou_amount = 0;

        // Handle excessive tokens (more than bAmountOut).
        if (b_amount > b_amount_out) {
            let b_excessive = b_amount - b_amount_out;
            let b0_excessive;
            if (data.b_token == gateway_param.token_b0) {
                b0_excessive = b_excessive;
                b_amount = b_amount - b0_excessive;
            } else if (data.b_token == get_aptos_coin_wrapper()) {
                // TODO: swap APT to B0
                // (uint256 resultB0, uint256 resultBX) = swapper.swapExactETHForB0{value: bExcessive}();
                // b0Excessive = resultB0;
                // bAmount -= resultBX;

                abort error::not_implemented(ENOT_IMPLEMENTED)
            } else {
                // TODO: swap to B0
                // (uint256 resultB0, uint256 resultBX) = swapper.swapExactBXForB0(data.bToken, bExcessive);
                // b0Excessive = resultB0;
                // bAmount -= resultBX;

                abort error::not_implemented(ENOT_IMPLEMENTED)
            };

            b0_amount_in = b0_amount_in + b0_excessive;
            data.b0_amount = i256::add(data.b0_amount, i256::from(b0_excessive));
        };

        // Handle filling the negative B0 balance, by swapping bToken into B0, if necessary.
        if (b_amount > 0 && i256::is_neg(data.b0_amount)) {
            let _owe = i256::abs_u256(data.b0_amount);
            let b0_fill;
            if (data.b_token == gateway_param.token_b0) {
                if (b_amount >= _owe) {
                    b0_fill = _owe;
                    b_amount = b_amount - _owe;
                } else {
                    b0_fill = b_amount;
                    b_amount = 0;
                }
            } else {
                // let _owe equals to minSwapB0Amount if small, otherwise swap may fail
                if (_owe < min_swap_b0_amount) {
                    _owe = min_swap_b0_amount;
                };
                if (data.b_token == get_aptos_coin_wrapper()) {
                    // TODO: swap APT to B0
                    // (uint256 resultB0, uint256 resultBX) = swapper.swapETHForExactB0{value: bAmount}(owe);
                    // b0Fill = resultB0;
                    // bAmount -= resultBX;

                    abort error::not_implemented(ENOT_IMPLEMENTED)
                } else {
                    // TODO: swap to B0
                    // (uint256 resultB0, uint256 resultBX) = swapper.swapBXForExactB0(data.bToken, owe, bAmount);
                    // b0Fill = resultB0;
                    // bAmount -= resultBX;

                    abort error::not_implemented(ENOT_IMPLEMENTED)
                }
            };
            b0_amount_in = b0_amount_in + b0_fill;
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
                let b0_out;
                if (amount > b0_amount_in) {
                    // Redeem B0 tokens from vault0
                    let b0_redeemed_fungible_asset =
                        vault::redeem(
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
                    b0_amount_in = b0_amount_in - amount;
                };
                b0_amount_out = b0_amount_out + b0_out;
                data.b0_amount = i256::sub(
                    data.b0_amount,
                    i256::add(i256::from(b0_out), i256::from(iou_amount))
                );
            };
        };

        // Deposit B0 tokens into the vault0, if any
        if (b0_amount_in > 0) {
            let b0_fungible_asset =
                fungible_asset::withdraw(
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
                    b_amount = b_amount + b0_amount_out;
                } else {
                    fungible_asset::merge(&mut fa_return, fungible_asset::withdraw(
                        &object::generate_signer_for_extending(&token_b0_store.store_extend_ref),
                        token_b0_store.store,
                        (b0_amount_out as u64)
                    ));
                }
            } else {
                // Swap B0 into BX for Lp
                if (data.b_token == gateway_param.token_b0) {
                    b_amount = b_amount + b0_amount_out;
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

                    abort error::not_implemented(ENOT_IMPLEMENTED)
                } else {
                    // TODO: swap B0 to BX
                    // (, uint256 resultBX) = swapper.swapExactB0ForBX(data.bToken, b0AmountOut);
                    // bAmount += resultBX;

                    abort error::not_implemented(ENOT_IMPLEMENTED)
                }
            }
        };

        // Transfer the remaining bAmount to the user's account.
        if (b_amount > 0) {
            fungible_asset::merge(&mut fa_return, fungible_asset::withdraw(
                &object::generate_signer_for_extending(&token_b_store.store_extend_ref),
                token_b_store.store,
                (b_amount as u64)
            ));
        };

        // Mint IOU tokens for the trader, if any.
        if (iou_amount > 0) {
            iou::mint(data.account, (iou_amount as u64));
        };

        (b_amount, data.account, fa_return)
    }

    /// Update liquidity-related state variables for a specific l_token
    fun update_liquidity(
        gateway_state: &mut GatewayState,
        d_token_state: &mut DTokenState,
        new_liquidity: u256,
        new_total_liquidity: u256
    ) {
        let (cumulative_time_per_liquidity, cumulative_time) =
            get_cumulative_time_internal(gateway_state, d_token_state);

        gateway_state.liquidity_time = (timestamp::now_seconds() as u256);
        gateway_state.total_liquidity = new_total_liquidity;
        gateway_state.cumulative_time_per_liquidity = i256::from(cumulative_time_per_liquidity);

        d_token_state.liquidity = new_liquidity;
        d_token_state.cumulative_time = cumulative_time;
        d_token_state.last_cumulative_time_per_liquidity = cumulative_time_per_liquidity;
    }

    /// Internal function
    fun get_cumulative_time_internal(gateway_state: &GatewayState, d_token_state: &DTokenState): (u256, u256) {
        let liquidity_time = gateway_state.liquidity_time;
        let total_liquidity = gateway_state.total_liquidity;

        let cumulative_time_per_liquidity = i256::as_u256(gateway_state.cumulative_time_per_liquidity);
        let liquidity = d_token_state.liquidity;
        let cumulative_time = d_token_state.cumulative_time;
        let last_cumulative_time_per_liquidity = d_token_state.last_cumulative_time_per_liquidity;

        if (total_liquidity != 0) {
            let now_seconds = (timestamp::now_seconds() as u256);
            let diff1 = (now_seconds - liquidity_time) * UONE * UONE / total_liquidity;
            cumulative_time_per_liquidity = cumulative_time_per_liquidity + diff1;

            if (liquidity != 0) {
                let diff2 = cumulative_time_per_liquidity - last_cumulative_time_per_liquidity;
                cumulative_time = cumulative_time + (diff2 * liquidity / UONE);
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
        executor: vector<u8>,
        finisher: vector<u8>
    ): (I256, u256) {
        let u_reward = i256::as_u256(reward);
        let gateway_b0_store = get_gateway_store(gateway_param, token_b0);

        if (u_reward <= b0_amount_in) {
            b0_amount_in = b0_amount_in - u_reward;
        } else {
            let b0_redeemed_asset = vault::redeem(
                object::address_to_object<Vault>(vault0),
                0,
                u_reward - b0_amount_in
            );
            let b0_redeemed = (fungible_asset::amount(&b0_redeemed_asset) as u256);
            fungible_asset::deposit(gateway_b0_store.store, b0_redeemed_asset);
            u_reward = b0_amount_in + b0_redeemed;
            reward = i256::from(u_reward);
            b0_amount_in = 0;
        };

        // if (u_reward > 0) {
        //     let reward_executor = u_reward * 80 / 100;
        //     let reward_finisher = u_reward - reward_executor;
        //     let reward_executor_asset =
        //         fungible_asset::withdraw(
        //             &object::generate_signer_for_extending(&gateway_b0_store.store_extend_ref),
        //             gateway_b0_store.store,
        //             (reward_executor as u64)
        //         );

        //     let reward_finisher_asset =
        //         fungible_asset::withdraw(
        //             &object::generate_signer_for_extending(&gateway_b0_store.store_extend_ref),
        //             gateway_b0_store.store,
        //             (reward_finisher as u64)
        //         );

        //     reward_store::deposit_reward(executor, reward_executor_asset);
        //     reward_store::deposit_reward(finisher, reward_finisher_asset);
        // };

        /// Only reward finisher, as executor is an EVM address
        if (u_reward > 0) {
            let reward_finisher_asset =
                fungible_asset::withdraw(
                    &object::generate_signer_for_extending(&gateway_b0_store.store_extend_ref),
                    gateway_b0_store.store,
                    (u_reward as u64)
                );
            reward_store::deposit_reward(finisher, reward_finisher_asset);
        };

        (reward, b0_amount_in)
    }

    inline fun get_aptos_coin_wrapper(): Object<Metadata> {
        coin_wrapper::get_wrapper<SupraCoin>()
    }

    inline fun create_gateway_store(token: Object<Metadata>): GatewayStore {
        let store_constructor_ref = &object::create_object(global_state::config_address());
        let store = fungible_asset::create_store(store_constructor_ref, token);
        GatewayStore { store, store_extend_ref: object::generate_extend_ref(store_constructor_ref) }
    }

    inline fun get_gateway_store(gateway_param: &GatewayParam, token: Object<Metadata>): &GatewayStore {
        smart_table::borrow(&gateway_param.gateway_stores, token)
    }

    inline fun withdraw_aptos_coin_wrapper(user: &signer, amount: u256): FungibleAsset {
        let aptos_coin_wrapper = get_aptos_coin_wrapper();
        primary_fungible_store::withdraw(user, aptos_coin_wrapper, (amount as u64))
    }

    inline fun withdraw_aptos_coin_from_store(store: &GatewayStore, amount: u256): Coin<SupraCoin> {
        let gateway_signer = &object::generate_signer_for_extending(&store.store_extend_ref);
        coin_wrapper::unwrap<SupraCoin>(fungible_asset::withdraw(gateway_signer, store.store, (amount as u64)))
    }

    inline fun empty_d_token_state(b_token: Object<Metadata>): DTokenState {
        DTokenState {
            request_id: 0,
            b_token,
            b0_amount: i256::zero(),
            last_cumulative_pnl_on_engine: i256::zero(),
            liquidity: 0,
            cumulative_time: 0,
            last_cumulative_time_per_liquidity: 0,
            single_position: false,
            last_request_i_chain_execution_fee: 0,
            // User cumulaitve iChain execution fee for requests cannot be finished, users can claim back
            cumulative_unused_i_chain_execution_fee: 0,
            current_operate_token: ZERO_ADDRESS
        }
    }

    /// Revert the changes due to liquidation reward calculation error on 20250425
    public entry fun fix_liquidation_reward_error_20250425(admin: &signer) acquires GatewayParam, GatewayStorage {
        global_state::assert_is_admin(admin);

        let user_address: vector<u8> = x"000000000000000000000000db744342500024b3d5c401151e24636023b17fcb";
        let reward_amount: u64 = 241710333;

        // Return wrong reward fungible asset amount of 241710333 back to Vault0
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let b0_asset = reward_store::fix_liquidation_reward_error_20250425(
            gateway_param.token_b0,
            user_address,
            reward_amount
        );
        vault::deposit(
            object::address_to_object<Vault>(gateway_param.vault0),
            0,
            b0_asset
        );

        // Correct cumulative_pnl_on_gateway, adding reward_amount back since we are returning this amount to Vault0
        let decimals_b0 = fungible_asset::decimals(gateway_param.token_b0);
        let gateway_storage = borrow_global_mut<GatewayStorage>(@deri);
        let gateway_state = &mut gateway_storage.gateway_state;
        let new_cumulative_pnl_on_gateway = i256::wrapping_add(
            gateway_state.cumulative_pnl_on_gateway,
            i256::rescale(i256::from((reward_amount as u256)), decimals_b0, SCALE_DECIMALS)
        );
        gateway_state.cumulative_pnl_on_gateway = new_cumulative_pnl_on_gateway;
    }

    #[test_only]
    use std::string;
    #[test_only]
    use std::debug::print;

    #[test_only]
    public fun init_for_test(deployer: &signer, token_b0: Object<Metadata>) {
        // create wrap APT
        coin_wrapper::create_fungible_asset<SupraCoin>();

        let gateway_storage = GatewayStorage {
            gateway_state: GatewayState {
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
        };

        let gateway_stores = smart_table::new();
        smart_table::add(&mut gateway_stores, token_b0, create_gateway_store(token_b0));
        smart_table::add(
            &mut gateway_stores,
            get_aptos_coin_wrapper(),
            create_gateway_store(get_aptos_coin_wrapper())
        );

        move_to(
            deployer,
            GatewayParam {
                vault0: ZERO_ADDRESS,
                token_b0,
                d_chain_event_signer: D_CHAIN_EVENT_SIGNER,
                b0_reserve_ratio: B0_RESERVE_RATIO,
                liquidation_reward_cut_ratio: i256::from(LIQUIDATION_REWARD_CUT_RATIO),
                min_liquidation_reward: i256::from(MIN_LIQUIDATION_REWARD),
                max_liquidation_reward: i256::from(MAX_LIQUIDATION_REWARD),
                protocol_fee_manager: @protocol_fee_manager,
                liq_claim: @liq_claim,
                gateway_stores
            }
        );

        move_to(deployer, gateway_storage);
    }

    #[test_only]
    public fun deserialize_request_update_liquidity_event(event: &RequestUpdateLiquidity):
        (
        u256, u256, u256, String, String, u256
    ) {
        (
            event.request_id,
            event.l_token_id,
            event.liquidity,
            event.last_cumulative_pnl_on_engine,
            event.cumulative_pnl_on_gateway,
            event.remove_b_amount
        )
    }

    #[test_only]
    public fun deserialize_finish_add_margin_event(event: &FinishAddMargin): (u256, u256, address, u256) {
        (event.request_id, event.p_token_id, event.b_token, event.b_amount)
    }

    #[test_only]
    public fun deserialize_request_remove_margin_event(event: &RequestRemoveMargin):
        (u256, u256, u256, String, String, u256) {
        (
            event.request_id,
            event.p_token_id,
            event.real_money_margin,
            event.last_cumulative_pnl_on_engine,
            event.cumulative_pnl_on_gateway,
            event.b_amount
        )
    }

    #[test_only]
    public fun print_d_token_state(d_token_id: u256) acquires GatewayStorage {
        let gateway_storage = borrow_global<GatewayStorage>(@deri);
        let d_token_state = smart_table::borrow(&gateway_storage.d_token_states, d_token_id);
        let b_token_addr = object::object_address(&d_token_state.b_token);
        let b_token_state = smart_table::borrow(&gateway_storage.b_token_states, b_token_addr);
        print(&string::utf8(b"balance vault address 0:"));
        print(&vault::get_balance(object::address_to_object(b_token_state.vault), 0));
        print(&string::utf8(b"balance vault d_token_id:"));
        print(
            &vault::get_balance(object::address_to_object(b_token_state.vault), d_token_id)
        );
        print(&string::utf8(b"d_token_state:"));
        print(d_token_state);
    }

    #[test_only]
    public fun test_finish_update_liquidity(
        user: &signer,
        event_data: vector<u8>,
        signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let (account_addr, b_amount_to_remove_asset) = finish_update_liquidity_internal(user, event_data, signature);

        primary_fungible_store::deposit(account_addr, b_amount_to_remove_asset);
    }

    #[test_only]
    public fun test_finish_remove_margin(
        user: &signer,
        event_data: vector<u8>,
        signature: vector<u8>
    ) acquires GatewayStorage, GatewayParam {
        let (account_addr, b_amount_to_remove_asset) = finish_remove_margin_internal(
            user,
            event_data,
            signature
        );

        primary_fungible_store::deposit(account_addr, b_amount_to_remove_asset);
    }

    #[test_only]
    public fun get_vault_b0_address(): address acquires GatewayStorage, GatewayParam {
        let gateway_storage = borrow_global<GatewayStorage>(@deri);
        let gateway_param = borrow_global<GatewayParam>(@deri);
        let b_token_state =
            smart_table::borrow(
                &gateway_storage.b_token_states,
                object::object_address(&gateway_param.token_b0)
            );

        b_token_state.vault
    }
}

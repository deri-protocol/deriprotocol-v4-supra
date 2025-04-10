module deri::global_state {
    use std::option;
    use std::option::Option;
    use supra_framework::object::{Self, ExtendRef};
    use std::signer;

    friend deri::coin_wrapper;
    friend deri::reward_store;

    const GLOBAL_STATE_NAME: vector<u8> = b"deri::global_state";

    /// Caller is not authorized
    const ENOT_AUTHORIZED: u64 = 1;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct GlobalState has key {
        extend_ref: ExtendRef,
        admin: address,
        pending_admin: Option<address>
    }

    fun init_module(deri_signer: &signer) {
        let global_state = &object::create_named_object(deri_signer, GLOBAL_STATE_NAME);
        move_to(
            deri_signer,
            GlobalState {
                extend_ref: object::generate_extend_ref(global_state),
                admin: @admin,
                pending_admin: option::none()
            }
        );
    }

    #[view]
    public fun config_address(): address {
        object::create_object_address(&@deri, GLOBAL_STATE_NAME)
    }

    public(friend) fun config_signer(): signer acquires GlobalState {
        object::generate_signer_for_extending(&borrow_global<GlobalState>(@deri).extend_ref)
    }

    public entry fun transfer_admin(admin: &signer, new_admin: address) acquires GlobalState {
        assert_is_admin(admin);
        let global_config = borrow_global_mut<GlobalState>(@deri);
        global_config.pending_admin = option::some(new_admin)
    }

    public entry fun accept_admin(new_admin: &signer) acquires GlobalState {
        let global_config = borrow_global_mut<GlobalState>(@deri);
        let current_pending_admin = option::extract(&mut global_config.pending_admin);
        assert!(signer::address_of(new_admin) == current_pending_admin, ENOT_AUTHORIZED);
        global_config.admin = current_pending_admin;
        global_config.pending_admin = option::none();
    }

    public fun assert_is_admin(admin: &signer) acquires GlobalState {
        let config = borrow_global<GlobalState>(@deri);
        assert!(signer::address_of(admin) == config.admin, ENOT_AUTHORIZED);
    }

    #[test_only]
    public fun init_for_test(deployer: &signer) {
        init_module(deployer);
    }
}

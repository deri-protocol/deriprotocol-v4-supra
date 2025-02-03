/**
* @title lToken Contract
* @dev lToken (NFT) contract designed to represent Liquidity Providers (Lp)
*      This contract allows for the creation and management of unique tokens representing ownership or
*      participation in various activities within the ecosystem.
*/
module deri::ltoken {
    use aptos_framework::chain_id;
    use aptos_framework::event;
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_token_objects::collection::{Self, MutatorRef};
    use aptos_token_objects::token::{Self, BurnRef};
    use deri::global_state;
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string;

    friend deri::gateway;

    const LTOKEN_COLLECTION_NAME: vector<u8> = b"lToken Collection";
    const LTOKEN_COLLECTION_DESC: vector<u8> = b"lToken Collection";

    /// TODO: update later
    const URI: vector<u8> = b"";
    const UNIQUE_IDENTIFIER: u8 = 1;

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct CollectionConfig has key {
        creator: ExtendRef,
        // For modifying the NFT collection's name, description or image uri in case.
        mutator_ref: MutatorRef,
        total_minted: u256,
        base_token_id: u256
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    // These are permissions to modify the NFT as Fungible Assets
    struct LToken has key {
        burn_ref: BurnRef
    }

    #[event]
    struct LTokenMinted has drop, store {
        nft: Object<LToken>,
        to: address
    }

    #[event]
    struct LTokenBurned has drop, store {
        nft: Object<LToken>,
        from: address
    }

    fun init_module(deployer: &signer) {
        // Create an unlimited NFT collection with no royalty
        let creator =
            &object::create_named_object(&global_state::config_signer(), LTOKEN_COLLECTION_NAME);
        let collection =
            &collection::create_unlimited_collection(
                &object::generate_signer(creator),
                string::utf8(LTOKEN_COLLECTION_NAME),
                string::utf8(LTOKEN_COLLECTION_DESC),
                option::none(),
                string::utf8(URI)
            );

        move_to(
            deployer,
            CollectionConfig {
                creator: object::generate_extend_ref(creator),
                mutator_ref: collection::generate_mutator_ref(collection),
                total_minted: 0,
                base_token_id: ((UNIQUE_IDENTIFIER as u256) << 248) + ((chain_id::get() as u256) << 160)
            }
        );
    }

    #[view]
    public fun collection_address(): address acquires CollectionConfig {
        let creator_addr = signer::address_of(creator_signer());
        collection::create_collection_address(
            &creator_addr, &string::utf8(LTOKEN_COLLECTION_NAME)
        )
    }

    #[view]
    public fun get_token_address(token_id: u256): address acquires CollectionConfig {
        let seed = token::create_token_seed(&string::utf8(LTOKEN_COLLECTION_NAME), &string::utf8(bcs::to_bytes(&token_id)));
        let signer_addr = signer::address_of(creator_signer());
        object::create_object_address(&signer_addr, seed)
    }

    #[view]
    public fun owner(token_id: u256): address acquires CollectionConfig {
        let nft_addr = get_token_address(token_id);
        let nft = object::address_to_object<LToken>(nft_addr);
        object::owner(nft)
    }

    #[view]
    public fun total_minted(): u256 acquires CollectionConfig {
        borrow_global<CollectionConfig>(@deri).total_minted
    }

    friend fun mint(to: address): u256 acquires CollectionConfig {
        let collection_config = &mut CollectionConfig[@deri];
        collection_config.total_minted += 1;

        let nft =
            &token::create_named_token(
                &object::generate_signer_for_extending(&collection_config.creator),
                string::utf8(LTOKEN_COLLECTION_NAME),
                string::utf8(b""),
                string::utf8(bcs::to_bytes(&(collection_config.base_token_id + collection_config.total_minted))),
                option::none(),
                string::utf8(b"")
            );

        move_to(
            &object::generate_signer(nft),
            LToken { burn_ref: token::generate_burn_ref(nft) }
        );

        let transfer_ref = object::generate_transfer_ref(nft);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&transfer_ref);
        object::transfer_with_ref(linear_transfer_ref, to);

        event::emit(LTokenMinted { nft: object::object_from_constructor_ref(nft), to });

        collection_config.base_token_id + collection_config.total_minted
    }

    friend fun burn(token_id: u256) acquires LToken, CollectionConfig {
        let nft_addr = get_token_address(token_id);
        let nft = object::address_to_object<LToken>(nft_addr);
        let owner_address = object::owner(nft);
        let ltoken = move_from<LToken>(nft_addr);
        let LToken { burn_ref } = ltoken;
        token::burn(burn_ref);

        event::emit(LTokenBurned { nft, from: owner_address });
    }

    inline fun creator_signer(): &signer acquires CollectionConfig {
        &object::generate_signer_for_extending(&CollectionConfig[@deri].creator)
    }
}

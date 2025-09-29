/**
* @title lToken Contract
* @dev lToken (NFT) contract designed to represent Liquidity Providers (Lp)
*      This contract allows for the creation and management of unique tokens representing ownership or
*      participation in various activities within the ecosystem.
*/
module deri::ltoken {
    use supra_framework::chain_id;
    use supra_framework::event;
    use supra_framework::object::{Self, ExtendRef, Object};
    use aptos_token_objects::collection::{Self, MutatorRef};
    use aptos_token_objects::token::{Self, BurnRef};
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string;
    use aptos_std::string_utils;

    friend deri::gateway;

    const LTOKEN_COLLECTION_NAME: vector<u8> = b"lToken Collection";
    const LTOKEN_COLLECTION_DESC: vector<u8> = b"lToken Collection";

    /// TODO: update later
    const URI: vector<u8> = b"";
    const UNIQUE_IDENTIFIER: u8 = 1;

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct CollectionConfig has key {
        creator: ExtendRef,
        // For modifying the NFT collection's name, description or image uri in case.
        mutator_ref: MutatorRef,
        total_minted: u256,
        base_token_id: u256
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
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

    fun init_module(deri_signer: &signer) {
        // Create an unlimited NFT collection with no royalty
        let creator = &object::create_named_object(deri_signer, LTOKEN_COLLECTION_NAME);
        let collection =
            &collection::create_unlimited_collection(
                &object::generate_signer(creator),
                string::utf8(LTOKEN_COLLECTION_NAME),
                string::utf8(LTOKEN_COLLECTION_DESC),
                option::none(),
                string::utf8(URI)
            );

        move_to(
            deri_signer,
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
        collection::create_collection_address(&creator_addr, &string::utf8(LTOKEN_COLLECTION_NAME))
    }

    #[view]
    public fun get_token_address(token_id: u256): address acquires CollectionConfig {
        let collection_config = borrow_global<CollectionConfig>(@deri);
        let total_minted_value = token_id - collection_config.base_token_id;

        let token_name_string = if (total_minted_value < 128) {
            string::utf8(bcs::to_bytes(&token_id))
        } else {
            string_utils::to_string(&token_id)
        };

        let seed =
            token::create_token_seed(
                &string::utf8(LTOKEN_COLLECTION_NAME),
                &token_name_string
            );
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

    public(friend) fun mint(to: address): u256 acquires CollectionConfig {
        let collection_config = borrow_global_mut<CollectionConfig>(@deri);
        collection_config.total_minted = collection_config.total_minted + 1;

        let token_name = if (collection_config.total_minted < 128) {
            string::utf8(bcs::to_bytes(&(collection_config.base_token_id + collection_config.total_minted)))
        } else {
            string_utils::to_string(&(collection_config.base_token_id + collection_config.total_minted))
        };

        let nft =
            &token::create_named_token(
                &object::generate_signer_for_extending(&collection_config.creator),
                string::utf8(LTOKEN_COLLECTION_NAME),
                string::utf8(LTOKEN_COLLECTION_DESC),
                token_name,
                option::none(),
                string::utf8(URI)
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

    public(friend) fun burn(token_id: u256) acquires LToken, CollectionConfig {
        let nft_addr = get_token_address(token_id);
        let nft = object::address_to_object<LToken>(nft_addr);
        let owner_address = object::owner(nft);
        let ltoken = move_from<LToken>(nft_addr);
        let LToken { burn_ref } = ltoken;
        token::burn(burn_ref);

        event::emit(LTokenBurned { nft, from: owner_address });
    }

    inline fun creator_signer(): &signer acquires CollectionConfig {
        &object::generate_signer_for_extending(&borrow_global<CollectionConfig>(@deri).creator)
    }

    #[test_only]
    public fun init_for_test(deployer: &signer) {
        init_module(deployer);
    }
}

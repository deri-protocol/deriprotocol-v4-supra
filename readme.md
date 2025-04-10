# deri-contract

# Deploy code to object and publish package

First you need calculate the contract address and deploy the contract code to the object storage. Then you can publish the package to the package registry.

### 1. Calculate the contract address

- Get object contract address

```shell
supra move tool view --function-id '0xe02e347d3461d4fe0366243642baf6e5ead39cb751650fa3f94f4d23ae5a2186::object_deployment::get_object_address' --args address:0xa466c7f3ae080d3570de98fb5c37fa0e40242d0aa221da4fc386a58da44b2b78 --url https://rpc-testnet.supra.com --profile deri1
```

### 2. Build publish payload

```shell
supra move tool build-publish-payload --package-dir /supra/configs/deri-contracts \
--named-addresses deri="<contract_address>",admin="0xa466c7f3ae080d3570de98fb5c37fa0e40242d0aa221da4fc386a58da44b2b78",protocol_fee_manager="0xa466c7f3ae080d3570de98fb5c37fa0e40242d0aa221da4fc386a58da44b2b78",liq_claim="0xa466c7f3ae080d3570de98fb5c37fa0e40242d0aa221da4fc386a58da44b2b78",b0_token="0xdb0a9c771aad8de01c250de6b4230c16c7a0475f333c8da2e68040c9ca5e704e" \
--json-output-file ./configs/deri-contracts/contract.json --included-artifacts none
```

### 3. Deploy contract code to object storage

- In file `contract.json`, replace funtion_id to `0x1::object_code_deployment::publish`
- Deploy the contract code to object storage

```shell
supra move tool run --json-file /supra/configs/deri-contracts/contract.json --url https://rpc-testnet.supra.com --profile deri1
```

### 4. Upgrade object package

- In file `contract.json`, replace funtion_id to `0x1::object_code_deployment::upgrade`
- Add more params in args

```json
{
  "type": "address",
  "value": "<contract_address>"
}
```

- Upgrade the object package

```shell
supra move tool run --json-file /supra/configs/deri-contracts/contract.json --url https://rpc-testnet.supra.com --profile deri1
```

# Setup deri gateway

### 1. Initialize the gateway
example: USC address: 0x7d2b35ed9abb99b7dc2afa97403c4bc1c98c16342b33ffcc416ccb5f133b3b9f::usdc_coin::USDC

```shell
supra move tool run --function-id '<contract_address>::gateway::initialize_with_coin' --type-args '<USC address>' --url https://rpc-testnet.supra.com --profile deri1
```

### 2. Add b token (USDC)

- Create vault:

```shell
supra move tool run --function-id '<contract_address>::gateway::create_create_vault_coin' --type-args '<USC address>' --url https://rpc-testnet.supra.com --profile deri1
```

- Add b token

```shell
supra move tool run --function-id '<contract_address>::gateway::add_b_token_coin' --type-args '<USC address>' --args address:<usdc_vault_address> String:USDCUSD u256:1000000000000000000 --url https://rpc-testnet.supra.com --profile deri1
```

### 3. Set d_chain execution fee per request

```shell
supra move tool run --function-id '<contract_address>::gateway::set_d_chain_execution_fee_per_request' --args u256:10000 --url https://rpc-testnet.supra.com --profile deri1
```

### 4. Set execution

```shell
supra move tool run --function-id '<contract_address>::gateway::set_execution_fee' --args u256:11000 u256:14000  u256:11000  u256:10000  u256:11000  --url https://rpc-testnet.supra.com --profile deri1
```

# How to faucet USDC testnet on Supra

```shell
supra move tool run --function-id '0x7d2b35ed9abb99b7dc2afa97403c4bc1c98c16342b33ffcc416ccb5f133b3b9f::usdc_coin::mint' --args u64:1000000000 --url https://rpc-testnet.supra.com --profile deri1

```

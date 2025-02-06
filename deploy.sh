#!/bin/bash

DEPLOYER=524ca96664241784ed52f630acb4c6cbfef47dd648cc3f40e0da161cca43acc4
PROTOCOL_FEE_MANAGER=524ca96664241784ed52f630acb4c6cbfef47dd648cc3f40e0da161cca43acc4
LIQ_CLAIM=524ca96664241784ed52f630acb4c6cbfef47dd648cc3f40e0da161cca43acc4

PROFILE=deri1

echo "create object and publish package"

aptos move create-object-and-publish-package --address-name \
deri --named-addresses \
deployer=$DEPLOYER,protocol_fee_manager=$PROTOCOL_FEE_MANAGER,liq_claim=$LIQ_CLAIM \
--profile $PROFILE --assume-yes --included-artifacts none

#aptos move compile --named-addresses deri=$DEPLOYER,deployer=$DEPLOYER
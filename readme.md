# deri-contract

# Deploy code to object and publish package
```shell
aptos move create-object-and-publish-package --address-name \
deri --named-addresses \
deployer=$DEPLOYER \
--profile $PROFILE --assume-yes --included-artifacts none
```

# Upgrade object package
```shell
aptos move upgrade-object-package \
--object-address $OBJ_ADDRESS \
--named-addresses \
deri=$OBJ_ADDRESS,deployer=$DEPLOYER \
--profile $PROFILE --assume-yes --included-artifacts none
```

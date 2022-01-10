# Flex Strategy UniswapV3 Rebalancer
A contract designed to maintain a default (and adjustable) ±30% position on the DAI/WETH pool on UniswapV3 with rebalancing features.
* Much of the code is reused from [G-Uni Pools](https://github.com/gelatodigital/g-uni-v1-core).
* Requires an off-chain component to call rebalancing functions with good swap amounts (not included in this repo). The rebalancing swap then takes place within the contract via the UniswapV3 pool we supply for.
* Should not store tokens inside of itself. Transfers tokens from the user as they are needed, which means the user must approve tokens before interacting with the contract.
* Current implementation is Ownable, which means that only one address can manage the contract at a time. May be changed in the future.
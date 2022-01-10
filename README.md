# Flex Strategy UniswapV3 Rebalancer
A contract designed to maintain a default (and adjustable) ±30% position on the DAI/WETH pool on UniswapV3 with rebalancing features.
Much of the code is reused from [G-Uni Pools](https://github.com/gelatodigital/g-uni-v1-core).
Requires an off-chain component to call rebalancing functions with good swap amounts in order to rebalance via UniswapV3 swap.
Should not store tokens inside of itself.
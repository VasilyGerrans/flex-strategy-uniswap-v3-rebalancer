// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.11;

import { IUniswapV3MintCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import { IUniswapV3SwapCallback } from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import { IUniswapV3Pool } from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TickMath } from "./vendor/uniswap/TickMath.sol";
import { FullMath, LiquidityAmounts } from "./vendor/uniswap/LiquidityAmounts.sol";

contract FLEXUniswapV3 is
    IUniswapV3MintCallback,
    IUniswapV3SwapCallback,
    Ownable
{
    using SafeERC20 for IERC20;

    int24 public lowerTick;
    int24 public upperTick;

    uint16 public slippageBPS;
    uint32 public slippageInterval;

    IUniswapV3Pool public pool;                 // DAI/ETH pool
    IERC20 public immutable token0;             // DAI
    IERC20 public immutable token1;             // ETH
    int24 public immutable tickSpacing = 60;    // spacing of the DAI/ETH pool

    uint256 public constant SQRT_70_PERCENT = 836660026534075547;
    uint256 public constant SQRT_130_PERCENT = 1140175425099137979;

    // solhint-disable-next-line max-line-length
    constructor(address _pool) {
        // these variables are immutable after initialization
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());

        // these variables can be udpated by the manager
        (lowerTick, upperTick) = _getSpreadTicks();
        slippageBPS = 500;                              // default: 5% slippage
        slippageInterval = 5 minutes;                   // default: last five minutes;
    } 

    /// @notice Uniswap V3 callback fn, called back on pool.mint
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /*_data*/
    ) external override {
        require(msg.sender == address(pool), "callback caller");

        if (amount0Owed > 0) token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) token1.safeTransfer(msg.sender, amount1Owed);
    }

    /// @notice Uniswap v3 callback fn, called back on pool.swap
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata /*data*/
    ) external override {
        require(msg.sender == address(pool), "callback caller");

        if (amount0Delta > 0)
            token0.safeTransfer(msg.sender, uint256(amount0Delta));
        else if (amount1Delta > 0)
            token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }

    /// @notice mint liquidity on current UniswapV3 position
    /// @return amount0 amount of token0 transferred from msg.sender to mint `mintAmount`
    /// @return amount1 amount of token1 transferred from msg.sender to mint `mintAmount`
    /// @return liquidityMinted amount of liquidity added to the underlying Uniswap V3 position
    // solhint-disable-next-line function-max-lines, code-complexity
    function mint(uint256 max0In, uint256 max1In)
        external
        onlyOwner
        returns (
            uint256 amount0,
            uint256 amount1,
            uint128 liquidityMinted
        )
    {
        require(max0In > 0 && max1In > 0, "mint 0");

        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(upperTick);

        liquidityMinted = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96, 
            sqrtRatioAX96, 
            sqrtRatioBX96, 
            max0In, 
            max1In
        );

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtRatioX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidityMinted
        );

        // undo rounding down
        amount0++;
        amount1++;

        // transfer amounts owed to contract
        if (amount0 > 0) {
            token0.safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            token1.safeTransferFrom(msg.sender, address(this), amount1);
        }

        pool.mint(address(this), lowerTick, upperTick, liquidityMinted, "");
    }

    /// @notice burn liquidity in current position and receive tokens
    /// @param burnAmount The amount of liquidity to burn
    /// @param receiver The account to receive the underlying amounts of token0 and token1
    /// @return amount0 amount of token0 transferred to receiver for burning `burnAmount`
    /// @return amount1 amount of token1 transferred to receiver for burning `burnAmount`
    // solhint-disable-next-line function-max-lines
    function burn(uint128 burnAmount, address receiver)
        public
        onlyOwner
        returns (
            uint256 amount0,
            uint256 amount1
        )
    {
        require(burnAmount > 0, "burn 0");
        _withdraw(lowerTick, upperTick, burnAmount);
        return withdraw(receiver);
    }

    function burnAll(address receiver)
        external
        onlyOwner
        returns (
            uint256 amount0,
            uint256 amount1
        )
    {
        (uint128 liquidity,,,,) = pool.positions(_getPositionID());
        return burn(liquidity, receiver);
    }

    /// @notice withdraw all relevant tokens present in the contract
    function withdraw(address receiver) 
        public 
        onlyOwner
        returns (
            uint256 amount0, 
            uint256 amount1
        ) 
    {
        (amount0, amount1) = (token0.balanceOf(address(this)), token1.balanceOf(address(this)));

        if (amount0 > 0) token0.safeTransfer(receiver, amount0);
        if (amount1 > 0) token1.safeTransfer(receiver, amount1);
    }

    /// @notice Execute `executiveRebalance` with default ±30% spread around current price.
    function defaultExecutiveRebalance(
        uint256 swapAmountBPS,
        bool zeroForOne
    ) external onlyOwner {
        (int24 newLowerTick, int24 newUpperTick) = _getSpreadTicks();
        executiveRebalance(newLowerTick, newUpperTick, swapAmountBPS, zeroForOne);
    }

    /// @notice Change the range of underlying UniswapV3 position
    /// @dev When changing the range the inventory of token0 and token1 may be rebalanced
    /// with a swap to deposit as much liquidity as possible into the new position. Swap parameters
    /// can be computed by simulating the whole operation: remove all liquidity, deposit as much
    /// as possible into new position, then observe how much of token0 or token1 is leftover.
    /// Swap a proportion of this leftover to deposit more liquidity into the position, since
    /// any leftover will be unused and sit idle until the next rebalance.
    /// @param newLowerTick The new lower bound of the position's range
    /// @param newUpperTick The new upper bound of the position's range
    /// @param swapAmountBPS amount of token to swap as proportion of total. Pass 0 to ignore swap.
    /// @param zeroForOne Which token to input into the swap (true = token0, false = token1)
    function executiveRebalance(
        int24 newLowerTick,
        int24 newUpperTick,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) public onlyOwner {
        (uint128 liquidity,,,,) = pool.positions(_getPositionID());
        if (liquidity > 0) _withdraw(lowerTick, upperTick, liquidity);

        lowerTick = newLowerTick;
        upperTick = newUpperTick;

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        _deposit(
            newLowerTick,
            newUpperTick,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            (sqrtPriceX96 * (10000 - slippageBPS)) / 10000,
            swapAmountBPS,
            zeroForOne
        );

        (uint128 newLiquidity,,,,) = pool.positions(_getPositionID());
        require(newLiquidity > 0, "new position 0");
    }

    /// @notice Reinvest fees earned into underlying position
    function rebalance(
        uint256 swapAmountBPS,
        bool zeroForOne
    ) external onlyOwner {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint160 swapThresholdPrice = (sqrtPriceX96 * (10000 - slippageBPS)) / 10000;

        if (swapAmountBPS > 0) {
            _checkSlippage(swapThresholdPrice, zeroForOne);
        }

        (uint128 liquidity,,,,) = pool.positions(_getPositionID());
        _rebalance(
            liquidity,
            swapThresholdPrice,
            swapAmountBPS,
            zeroForOne
        );

        (uint128 newLiquidity,,,,) = pool.positions(_getPositionID());
        require(newLiquidity >= liquidity, "liquidity decrease");
    }

    /// @notice change configurable parameters
    /// @param newSlippageBPS maximum slippage on swaps during rebalance
    /// @param newSlippageInterval length of time for TWAP used in computing slippage on swaps
    // solhint-disable-next-line code-complexity
    function updateParams(
        uint16 newSlippageBPS,
        uint32 newSlippageInterval
    ) external onlyOwner {
        require(newSlippageBPS <= 10000, "BPS");

        if (newSlippageBPS != 0) slippageBPS = newSlippageBPS;
        if (newSlippageInterval != 0) slippageInterval = newSlippageInterval;
    }

    function renounceOwnership() public virtual override onlyOwner {
        super.renounceOwnership();
    }

    /// @notice compute total underlying holdings
    /// includes current liquidity invested in uniswap position, current fees earned
    /// and any uninvested leftover
    /// @return amount0Current current total underlying balance of token0
    /// @return amount1Current current total underlying balance of token1
    function getUnderlyingBalances()
        public
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        (uint160 sqrtRatioX96, int24 tick,,,,,) = pool.slot0();
        return _getUnderlyingBalances(sqrtRatioX96, tick);
    }

    function getUnderlyingBalancesAtPrice(uint160 sqrtRatioX96)
        external
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        (,int24 tick,,,,,) = pool.slot0();
        return _getUnderlyingBalances(sqrtRatioX96, tick);
    }

    function getPositionID() external view returns (bytes32 positionID) {
        return _getPositionID();
    }

    function _getPositionID() internal view returns (bytes32 positionID) {
        return keccak256(abi.encodePacked(address(this), lowerTick, upperTick));
    }

    // solhint-disable-next-line function-max-lines
    function _getUnderlyingBalances(uint160 sqrtRatioX96, int24 tick)
        internal
        view
        returns (uint256 amount0Current, uint256 amount1Current)
    {
        (
            uint128 liquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = pool.positions(_getPositionID());

        // compute current holdings from liquidity
        (amount0Current, amount1Current) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                liquidity
            );

        // compute current fees earned
        uint256 fee0 =
            _computeFeesEarned(true, feeGrowthInside0Last, tick, liquidity) +
                uint256(tokensOwed0);
        uint256 fee1 =
            _computeFeesEarned(false, feeGrowthInside1Last, tick, liquidity) +
                uint256(tokensOwed1);

        // add any leftover in contract to current holdings
        amount0Current +=
            fee0 +
            token0.balanceOf(address(this));
        amount1Current +=
            fee1 +
            token1.balanceOf(address(this));
    }

    /// @notice Calculates lower and upper ticks designed to be rougly
    /// ±30% of the current price, preferring a slightly narrower spread
    /// where possible.
    /// @dev Uses square root constants for optimisation.
    /// tickSpacing calculation adjustments take into account the fact
    /// that Solidity always rounds division towards 0.
    function _getSpreadTicks() 
        internal
        view 
        returns (
            int24 _lowerTick, 
            int24 _upperTick
        ) 
    {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();

        _lowerTick = TickMath.getTickAtSqrtRatio(uint160((sqrtPriceX96 * SQRT_70_PERCENT) / 1e18));
        _upperTick = TickMath.getTickAtSqrtRatio(uint160((sqrtPriceX96 * SQRT_130_PERCENT) / 1e18));

        _lowerTick = _lowerTick % tickSpacing == 0 ? _lowerTick :   // accept valid tickSpacing
            _lowerTick > 0 ?                                        // else, round up to closest valid tickSpacing
                (_lowerTick / tickSpacing + 1) * tickSpacing : 
                (_lowerTick / tickSpacing) * tickSpacing;                       
        _upperTick = _upperTick % tickSpacing == 0 ? _upperTick :   // accept valid tickSpacing
            _upperTick > 0 ?                                        // else, round down to closest valid tickSpacing
                (_upperTick / tickSpacing) * tickSpacing :     
                (_upperTick / tickSpacing - 1) * tickSpacing;                   
    }

    // solhint-disable-next-line function-max-lines
    function _rebalance(
        uint128 liquidity,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) private {
        _withdraw(lowerTick, upperTick, liquidity);
        _deposit(
            lowerTick,
            upperTick,
            token0.balanceOf(address(this)),
            token1.balanceOf(address(this)),
            swapThresholdPrice,
            swapAmountBPS,
            zeroForOne
        );
    }

    // solhint-disable-next-line function-max-lines
    function _withdraw(
        int24 lowerTick_,
        int24 upperTick_,
        uint128 liquidity
    ) private {
        pool.burn(lowerTick_, upperTick_, liquidity);
        pool.collect(
            address(this),
            lowerTick_,
            upperTick_,
            type(uint128).max,
            type(uint128).max
        );
    }

    // solhint-disable-next-line function-max-lines
    function _deposit(
        int24 lowerTick_,
        int24 upperTick_,
        uint256 amount0,
        uint256 amount1,
        uint160 swapThresholdPrice,
        uint256 swapAmountBPS,
        bool zeroForOne
    ) private {
        if (swapAmountBPS > 0) {
            (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
            // First, deposit as much as we can
            uint128 baseLiquidity =
                LiquidityAmounts.getLiquidityForAmounts(
                    sqrtRatioX96,
                    TickMath.getSqrtRatioAtTick(lowerTick_),
                    TickMath.getSqrtRatioAtTick(upperTick_),
                    amount0,
                    amount1
                );
            if (baseLiquidity > 0) {
                (uint256 amountDeposited0, uint256 amountDeposited1) =
                    pool.mint(
                        address(this),
                        lowerTick_,
                        upperTick_,
                        baseLiquidity,
                        ""
                    );

                amount0 -= amountDeposited0;
                amount1 -= amountDeposited1;
            }
            int256 swapAmount =
                SafeCast.toInt256(
                    ((zeroForOne ? amount0 : amount1) * swapAmountBPS) / 10000
                );
            if (swapAmount > 0) {
                _swapAndDeposit(
                    lowerTick_,
                    upperTick_,
                    amount0,
                    amount1,
                    swapAmount,
                    swapThresholdPrice,
                    zeroForOne
                );
            }
        }
    }

    function _swapAndDeposit(
        int24 lowerTick_,
        int24 upperTick_,
        uint256 amount0,
        uint256 amount1,
        int256 swapAmount,
        uint160 swapThresholdPrice,
        bool zeroForOne
    ) private returns (uint256 finalAmount0, uint256 finalAmount1) {
        (int256 amount0Delta, int256 amount1Delta) =
            pool.swap(
                address(this),
                zeroForOne,
                swapAmount,
                swapThresholdPrice,
                ""
            );
        finalAmount0 = uint256(SafeCast.toInt256(amount0) - amount0Delta);
        finalAmount1 = uint256(SafeCast.toInt256(amount1) - amount1Delta);

        // Add liquidity a second time
        (uint160 sqrtRatioX96,,,,,,) = pool.slot0();
        uint128 liquidityAfterSwap =
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(lowerTick_),
                TickMath.getSqrtRatioAtTick(upperTick_),
                finalAmount0,
                finalAmount1
            );
        if (liquidityAfterSwap > 0) {
            pool.mint(
                address(this),
                lowerTick_,
                upperTick_,
                liquidityAfterSwap,
                ""
            );
        }
    }

    // solhint-disable-next-line function-max-lines
    function _computeFeesEarned(
        bool isZero,
        uint256 feeGrowthInsideLast,
        int24 tick,
        uint128 liquidity
    ) private view returns (uint256 fee) {
        uint256 feeGrowthOutsideLower;
        uint256 feeGrowthOutsideUpper;
        uint256 feeGrowthGlobal;
        if (isZero) {
            feeGrowthGlobal = pool.feeGrowthGlobal0X128();
            (,,feeGrowthOutsideLower,,,,,) = pool.ticks(lowerTick);
            (,,feeGrowthOutsideUpper,,,,,) = pool.ticks(upperTick);
        } else {
            feeGrowthGlobal = pool.feeGrowthGlobal1X128();
            (,,,feeGrowthOutsideLower,,,,) = pool.ticks(lowerTick);
            (,,,feeGrowthOutsideUpper,,,,) = pool.ticks(upperTick);
        }

        unchecked {
            // calculate fee growth below
            uint256 feeGrowthBelow;
            if (tick >= lowerTick) {
                feeGrowthBelow = feeGrowthOutsideLower;
            } else {
                feeGrowthBelow = feeGrowthGlobal - feeGrowthOutsideLower;
            }

            // calculate fee growth above
            uint256 feeGrowthAbove;
            if (tick < upperTick) {
                feeGrowthAbove = feeGrowthOutsideUpper;
            } else {
                feeGrowthAbove = feeGrowthGlobal - feeGrowthOutsideUpper;
            }

            uint256 feeGrowthInside =
                feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove;
            fee = FullMath.mulDiv(
                liquidity,
                feeGrowthInside - feeGrowthInsideLast,
                0x100000000000000000000000000000000
            );
        }
    }

    function _checkSlippage(uint160 swapThresholdPrice, bool zeroForOne)
        private
        view
    {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = slippageInterval;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);

        require(tickCumulatives.length == 2, "array len");
        uint160 avgSqrtRatioX96;
        unchecked {
            int24 avgTick =
                int24(
                    (tickCumulatives[1] - tickCumulatives[0]) /
                        int56(uint56(slippageInterval))
                );
            avgSqrtRatioX96 = TickMath.getSqrtRatioAtTick(avgTick);
        }

        uint160 maxSlippage = (avgSqrtRatioX96 * slippageBPS) / 10000;
        if (zeroForOne) {
            require(
                swapThresholdPrice >= avgSqrtRatioX96 - maxSlippage,
                "high slippage"
            );
        } else {
            require(
                swapThresholdPrice <= avgSqrtRatioX96 + maxSlippage,
                "high slippage"
            );
        }
    }
}
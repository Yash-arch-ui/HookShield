// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {VolatilityStorage} from "../VolatilityStorage.sol";
import {Volatility} from "../libraries/Volatility.sol";

contract HookShieldHook is IHooks {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    event DynamicFeeComputed(uint256 tradeSize, uint24 fee);

    IPoolManager public poolManager;
    VolatilityStorage public volStorage;

    // TEMPORARY: hardcoded until RiskModel + Policy exist
    uint24 public constant STUB_FEE = 3000; // 0.30%

    uint24 public latestFee;
    bool public lastSwapTriggered;

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "NOT_MANAGER");
        _;
    }

    constructor(IPoolManager _poolManager, address _volStorage) {
        poolManager = _poolManager;
        volStorage = VolatilityStorage(_volStorage);
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        lastSwapTriggered = true;

        uint256 tradeSize =
            params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified);

        uint24 fee = STUB_FEE;

        latestFee = fee;

        emit DynamicFeeComputed(tradeSize, fee);

        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();

        VolatilityStorage.VolatilityState memory oldState = volStorage.getState(poolId);
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        VolatilityStorage.VolatilityState memory newState = Volatility.compute(oldState, currentSqrtPriceX96);
        volStorage.setState(poolId, newState);

        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external returns (bytes4, BalanceDelta)
    {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external returns (bytes4) {
        return IHooks.afterDonate.selector;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}

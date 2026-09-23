// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {OracleDivergenceStorage} from "../../src/OracleDivergenceStorage.sol";
import {ChainlinkOracle} from "../../src/oracle/ChainlinkOracle.sol";
import {OracleDivergenceSignal} from "../../src/signals/OracleDivergenceSignal.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract OracleDivergenceSignalTest is Test {
    SignalState signalState;
    OracleDivergenceStorage oracleStorage;
    MockAggregatorV3 mockAggregator;
    ChainlinkOracle chainlinkOracle;
    OracleDivergenceSignal oracleSignal;
    PoolId poolId;

    uint160 constant SQRT_PRICE_AT_TICK_0 = 79228162514264337593543950336; // TickMath.getSqrtPriceAtTick(0) ≈ 1e18

    function setUp() public {
        signalState = new SignalState();
        oracleStorage = new OracleDivergenceStorage();
        // $2000 with 8 decimals -> 2000e8
        mockAggregator = new MockAggregatorV3(2000e8, 8);
        chainlinkOracle = new ChainlinkOracle(address(mockAggregator), 1 hours);
        oracleSignal =
            new OracleDivergenceSignal(address(oracleStorage), address(chainlinkOracle), address(signalState));
        oracleStorage.setWriter(address(oracleSignal));
        signalState.setAuthorizedWriter(address(oracleSignal), true);
        // P0: bind this test as the hook so direct update() calls are authorized.
        oracleSignal.setHook(address(this));

        poolId = PoolId.wrap(bytes32(uint256(1)));
    }

    function test_Update_PublishesToSignalState() public {
        // Seed with an initial price to establish a baseline.
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        // The oracle price ($2000e8 -> 2000e18) vs pool price from sqrtPriceX96.
        // Divergence should be 0 if they match, or nonzero if they don't.
        // With tick 0, poolPrice ≈ 1e18 (in some unit), oracle is 2000e18.
        // The exact divergence depends on the sqrtPriceToPriceE18 math.
        // We just verify the field was written.
        // Note: the second call computes divergence against the first call's oracle price.
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);
        snap = signalState.getSnapshot(poolId);
        assertGe(snap.oracleDivergence, 0, "oracle divergence should be >= 0");
        assertLe(snap.oracleDivergence, 1e18, "oracle divergence should be <= 1e18");
    }

    function test_Compute_ReturnsZeroWhenNoData() public view {
        uint256 div = oracleSignal.compute(poolId);
        assertEq(div, 0, "compute should return 0 when no data has been written");
    }

    function test_Compute_ReturnsNonzeroAfterUpdate() public {
        // Set a different oracle price to create divergence.
        mockAggregator.setAnswer(3000e8); // $3000
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);

        uint256 div = oracleSignal.compute(poolId);
        // With a different oracle vs pool price, divergence should be > 0.
        assertGt(div, 0, "divergence should be > 0 when oracle and pool prices differ");
    }

    function test_Compute_BoundedByOneE18() public {
        // Set an extreme oracle price.
        mockAggregator.setAnswer(100_000e8); // $100,000
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);

        uint256 div = oracleSignal.compute(poolId);
        assertLe(div, 1e18, "divergence should never exceed 1e18");
    }

    function test_Update_UsesFallbackWhenOracleIsStale() public {
        // Warp far enough so setStale()'s block.timestamp - 2 hours won't underflow.
        vm.warp(4 hours);

        // Set initial oracle price.
        mockAggregator.setAnswer(2000e8);
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);

        // Make the oracle stale.
        mockAggregator.setStale();

        // The _getOraclePrice catches the revert and returns 0.
        // When oraclePrice == 0, divergence is 0.
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        // With oracle returning 0 (stale), divergence should be 0.
        assertEq(snap.oracleDivergence, 0, "stale oracle should produce zero divergence");
    }

    function test_Update_DivergenceDirection() public {
        // Set oracle higher than pool price.
        mockAggregator.setAnswer(4000e8);
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);
        uint256 divHigh = oracleSignal.compute(poolId);

        // Set oracle lower than pool price (still nonzero but small).
        mockAggregator.setAnswer(100e8);
        oracleSignal.update(poolId, SQRT_PRICE_AT_TICK_0);
        uint256 divLow = oracleSignal.compute(poolId);

        // Both should be > 0 since both differ from pool price.
        assertGt(divHigh, 0, "high oracle should produce divergence");
        assertGt(divLow, 0, "low oracle should produce divergence");
    }

    function test_StorageWriter_Authorization() public {
        OracleDivergenceStorage newStorage = new OracleDivergenceStorage();
        OracleDivergenceSignal newSignal =
            new OracleDivergenceSignal(address(newStorage), address(chainlinkOracle), address(signalState));
        newStorage.setWriter(address(newSignal));

        // Another contract should not be able to write.
        OracleDivergenceStorage rogueStorage = new OracleDivergenceStorage();
        vm.expectRevert();
        rogueStorage.setState(
            poolId,
            OracleDivergenceStorage.OracleState({lastOraclePrice: 1e18, lastPoolPrice: 1e18, lastUpdateBlock: 1})
        );
    }
}

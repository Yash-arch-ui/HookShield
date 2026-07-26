// SPDX-License-Identifier:MIT
import {PoolId} from "v4-core/types/PoolId.sol";
import {VolatilityStorage} from "../VolatilityStorage.sol";
import {Volatility} from "../libraries/Volatility.sol";
import {ISignal} from "../interfaces/ISignal.sol";
import {SignalState} from "./SignalState.sol";

contract VolatilitySignal is ISignal {
    VolatilityStorage public immutable volatilityStorage;
    SignalState public immutable signalState;

    constructor(address _volatilityStorage, address _signalState) {
        require(_volatilityStorage != address(0), "zero volStorage");
        require(_signalState != address(0), "zero signalState");
        volatilityStorage = VolatilityStorage(_volatilityStorage);
        signalState= SignalState(_signalState);
    }
    function update( PoolId poolId, uint160 newSqrtPriceX96) external override{
        VolatilityStorage.VolatilityState memory oldState = volatilityStorage.getState(poolId);
        VolatilityStorage.VolatilityState memory newState = Volatility.compute(oldState, newSqrtPriceX96);
        volatilityStorage.setState(poolId, newState);
        signalState.setVolatility(poolId, newState.ewmaVolatility);

    }
    function compute(PoolId poolId) external view override returns(uint256 value){
        return volatilityStorage.getState(poolId).ewmaVolatility;
    }
}
//SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import {SignalTypes} from "./types/SignalTypes.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol"; 
import "./libraries/Volatility.sol" ;
contract SignalEngine{
   using SignalTypes for *;
   using Volatility for uint256;
   /*
   OracleDivergence oracle;
   Inventory inventory;
   JITDetector jit;
   
   constructor (address _oracle, address _volatility, address _inventory, address _jit){
        oracle = OracleDivergence(_oracle);

    inventory = Inventory(_inventory);

    jit = JITDetector(_jit);
   }

   

  function computeSignal( PoolId poolId,uint160 sqrtPriceX96, uint128 liquidity,
  uint256 swapAmount, bool zeroForOne) returns (SignalResult){

  }
  */
}

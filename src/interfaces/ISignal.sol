// SPDX-License-Identifier:MIT
pragma solidity ^0.8.19;
import "../SignalEngine.sol";
interface ISignal{
    SignalEngine signalEngine;
   function compute(signalEngine) external 
   returns(uint256 signalScore);
}
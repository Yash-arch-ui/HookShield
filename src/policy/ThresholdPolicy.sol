// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPolicy, PolicyAction} from "./IPolicy.sol";

contract ThresholdPolicy is IPolicy, Ownable {
    uint256 public constant SCALE = 1e18;
    uint256 public tier1Threshold = 0.2e18;
    uint256 public tier2Threshold = 0.4e18;
    uint256 public tier3Threshold = 0.6e18;
    uint256 public tier4Threshold = 0.8e18;
    uint24 public tier0Fee = 3000; // < tier1: 0.30%
    uint24 public tier1Fee = 4000; // tier1-tier2: 0.40%
    uint24 public tier2Fee = 6000; // tier2-tier3: 0.60%
    uint24 public tier3Fee = 9000; // tier3-tier4: 0.90%
    uint24 public tier4Fee = 12000; // >= tier4: 1.20% (capped)

    constructor() Ownable(msg.sender) {}

    function action(PoolId, uint256 riskE18) external view override returns (PolicyAction memory) {
        if (riskE18 < tier1Threshold) {
            return PolicyAction({fee: tier0Fee, pauseSwaps: false, tier: 0});
        } else if (riskE18 < tier2Threshold) {
            return PolicyAction({fee: tier1Fee, pauseSwaps: false, tier: 1});
        } else if (riskE18 < tier3Threshold) {
            return PolicyAction({fee: tier2Fee, pauseSwaps: false, tier: 2});
        } else if (riskE18 < tier4Threshold) {
            return PolicyAction({fee: tier3Fee, pauseSwaps: false, tier: 3});
        } else {
            return PolicyAction({fee: tier4Fee, pauseSwaps: false, tier: 4});
        }
    }

    function setThresholds(uint256 _tier1, uint256 _tier2, uint256 _tier3, uint256 _tier4) external onlyOwner {
        require(_tier1 < _tier2 && _tier2 < _tier3 && _tier3 < _tier4 && _tier4 <= SCALE, "invalid thresholds");
        tier1Threshold = _tier1;
        tier2Threshold = _tier2;
        tier3Threshold = _tier3;
        tier4Threshold = _tier4;
    }

    function setFees(uint24 _tier0Fee, uint24 _tier1Fee, uint24 _tier2Fee, uint24 _tier3Fee, uint24 _tier4Fee)
        external
        onlyOwner
    {
        tier0Fee = _tier0Fee;
        tier1Fee = _tier1Fee;
        tier2Fee = _tier2Fee;
        tier3Fee = _tier3Fee;
        tier4Fee = _tier4Fee;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SignalState} from "../signals/SignalState.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ReporterSignalStore
/// @notice Receives off-chain signal reports (JIT, Sandwich, Flashloan, ToxicFlow, MEV)
///         signed by authorized reporters, verifies EIP-712 signatures, and writes
///         the scores into the central SignalState contract.
contract ReporterSignalStore is EIP712, Ownable {
    using ECDSA for bytes32;

    enum SignalType {
        Sandwich,
        Flashloan,
        ToxicFlow,
        Jit,
        Mev
    }

    struct SignalReport {
        bytes32 poolId;
        uint8 signalType;
        uint256 score;
        uint256 nonce;
        uint256 validUntil;
    }

    bytes32 private constant SIGNAL_REPORT_TYPEHASH =
        keccak256("SignalReport(bytes32 poolId,uint8 signalType,uint256 score,uint256 nonce,uint256 validUntil)");

    error NotAuthorizedReporter();
    error InvalidNonce();
    error ReportExpired();
    error InvalidSignalType();

    SignalState public immutable signalState;

    mapping(address => bool) public authorizedReporters;
    mapping(address => uint256) public lastNonce;

    constructor(address _signalState, address initialOwner) EIP712("HookShieldReporter", "1") Ownable(initialOwner) {
        signalState = SignalState(_signalState);
    }

    function setAuthorizedReporter(address reporter, bool authorized) external onlyOwner {
        authorizedReporters[reporter] = authorized;
    }

    function submitScore(SignalReport calldata report, bytes calldata signature) external {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SIGNAL_REPORT_TYPEHASH,
                    report.poolId,
                    report.signalType,
                    report.score,
                    report.nonce,
                    report.validUntil
                )
            )
        );

        address signer = ECDSA.recover(digest, signature);

        if (!authorizedReporters[signer]) revert NotAuthorizedReporter();
        if (report.nonce <= lastNonce[signer]) revert InvalidNonce();
        if (block.timestamp >= report.validUntil) revert ReportExpired();

        lastNonce[signer] = report.nonce;

        PoolId poolId = PoolId.wrap(report.poolId);

        // Dispatch to the appropriate SignalState setter
        if (report.signalType == uint8(SignalType.Sandwich)) {
            signalState.setSandwichScore(poolId, report.score);
        } else if (report.signalType == uint8(SignalType.Flashloan)) {
            signalState.setFlashloanScore(poolId, report.score);
        } else if (report.signalType == uint8(SignalType.ToxicFlow)) {
            signalState.setToxicFlowScore(poolId, report.score);
        } else if (report.signalType == uint8(SignalType.Jit)) {
            signalState.setJitScore(poolId, report.score);
        } else if (report.signalType == uint8(SignalType.Mev)) {
            signalState.setMevScore(poolId, report.score);
        } else {
            revert InvalidSignalType();
        }
    }
}

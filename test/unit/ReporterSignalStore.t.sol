// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {SignalState, SignalSnapshot} from "../../src/signals/SignalState.sol";
import {ReporterSignalStore} from "../../src/reporter/ReporterSignalStore.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

contract ReporterSignalStoreTest is Test {
    SignalState signalState;
    ReporterSignalStore reporterStore;
    PoolId poolId;

    // Test reporter key pair
    uint256 constant REPORTER_KEY = 0xA11CE;

    // Domain separator components (must match ReporterSignalStore constructor args)
    bytes32 private constant DOMAIN_NAME_HASH = keccak256("HookShieldReporter");
    bytes32 private constant DOMAIN_VERSION_HASH = keccak256("1");
    bytes32 private constant SIGNAL_REPORT_TYPEHASH =
        keccak256("SignalReport(bytes32 poolId,uint8 signalType,uint256 score,uint256 nonce,uint256 validUntil)");

    function setUp() public {
        signalState = new SignalState();
        reporterStore = new ReporterSignalStore(address(signalState), address(this));
        poolId = PoolId.wrap(bytes32(uint256(1)));

        // Authorize the reporterStore as a writer on SignalState
        signalState.setAuthorizedWriter(address(reporterStore), true);

        // Authorize the derived reporter address
        address reporter = vm.addr(REPORTER_KEY);
        reporterStore.setAuthorizedReporter(reporter, true);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                DOMAIN_NAME_HASH,
                DOMAIN_VERSION_HASH,
                block.chainid,
                address(reporterStore)
            )
        );
    }

    function _structHash(
        bytes32 poolId_,
        uint8 signalType,
        uint256 score,
        uint256 nonce,
        uint256 validUntil
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(SIGNAL_REPORT_TYPEHASH, poolId_, signalType, score, nonce, validUntil));
    }

    function _digest(
        bytes32 poolId_,
        uint8 signalType,
        uint256 score,
        uint256 nonce,
        uint256 validUntil
    ) internal view returns (bytes32) {
        bytes32 structHash = _structHash(poolId_, signalType, score, nonce, validUntil);
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _sign(
        uint256 privateKey,
        bytes32 poolId_,
        uint8 signalType,
        uint256 score,
        uint256 nonce,
        uint256 validUntil
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 digest = _digest(poolId_, signalType, score, nonce, validUntil);
        (v, r, s) = vm.sign(privateKey, digest);
    }

    function _encodeSignature(uint8 v, bytes32 r, bytes32 s) internal pure returns (bytes memory) {
        return abi.encodePacked(r, s, v);
    }

    // ── submitScore success ──────────────────────────────────────────────

    function testSubmitScoreSucceedsWhenAuthorizedAndValid() public {
        // Sign a report
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            REPORTER_KEY,
            PoolId.unwrap(poolId),
            uint8(ReporterSignalStore.SignalType.Sandwich),
            0.75e18,
            1,
            block.timestamp + 1 hours
        );

        ReporterSignalStore.SignalReport memory report = ReporterSignalStore.SignalReport({
            poolId: PoolId.unwrap(poolId),
            signalType: uint8(ReporterSignalStore.SignalType.Sandwich),
            score: 0.75e18,
            nonce: 1,
            validUntil: block.timestamp + 1 hours
        });

        reporterStore.submitScore(report, _encodeSignature(v, r, s));

        // Verify the SignalState field was updated
        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        assertEq(snap.sandwichScore, 0.75e18, "sandwichScore not updated");
    }

    function testSubmitScoreUpdatesCorrectFieldPerSignalType() public {
        // Test each signal type maps to the correct setter
        _submitAndVerify(uint8(ReporterSignalStore.SignalType.Jit), 0.1e18, 1);
        _submitAndVerify(uint8(ReporterSignalStore.SignalType.Flashloan), 0.2e18, 2);
        _submitAndVerify(uint8(ReporterSignalStore.SignalType.ToxicFlow), 0.3e18, 3);
        _submitAndVerify(uint8(ReporterSignalStore.SignalType.Mev), 0.4e18, 4);
        _submitAndVerify(uint8(ReporterSignalStore.SignalType.Sandwich), 0.5e18, 5);
    }

    function _submitAndVerify(uint8 signalType, uint256 score, uint256 nonce) internal {
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            REPORTER_KEY, PoolId.unwrap(poolId), signalType, score, nonce, block.timestamp + 1 hours
        );

        ReporterSignalStore.SignalReport memory report = ReporterSignalStore.SignalReport({
            poolId: PoolId.unwrap(poolId),
            signalType: signalType,
            score: score,
            nonce: nonce,
            validUntil: block.timestamp + 1 hours
        });

        reporterStore.submitScore(report, _encodeSignature(v, r, s));

        SignalSnapshot memory snap = signalState.getSnapshot(poolId);
        if (signalType == uint8(ReporterSignalStore.SignalType.Jit)) {
            assertEq(snap.jitScore, score, "jitScore mismatch");
        } else if (signalType == uint8(ReporterSignalStore.SignalType.Flashloan)) {
            assertEq(snap.flashloanScore, score, "flashloanScore mismatch");
        } else if (signalType == uint8(ReporterSignalStore.SignalType.ToxicFlow)) {
            assertEq(snap.toxicFlowScore, score, "toxicFlowScore mismatch");
        } else if (signalType == uint8(ReporterSignalStore.SignalType.Mev)) {
            assertEq(snap.mevScore, score, "mevScore mismatch");
        } else if (signalType == uint8(ReporterSignalStore.SignalType.Sandwich)) {
            assertEq(snap.sandwichScore, score, "sandwichScore mismatch");
        }
    }

    // ── submitScore reverts ──────────────────────────────────────────────

    function testSubmitScoreRevertsIfSignerNotAuthorized() public {
        // Use a different key that is NOT authorized
        uint256 unauthorizedKey = 0xDEAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            unauthorizedKey,
            _digest(PoolId.unwrap(poolId), uint8(ReporterSignalStore.SignalType.Sandwich), 0.5e18, 1, block.timestamp + 1 hours)
        );

        ReporterSignalStore.SignalReport memory report = ReporterSignalStore.SignalReport({
            poolId: PoolId.unwrap(poolId),
            signalType: uint8(ReporterSignalStore.SignalType.Sandwich),
            score: 0.5e18,
            nonce: 1,
            validUntil: block.timestamp + 1 hours
        });

        vm.expectRevert(ReporterSignalStore.NotAuthorizedReporter.selector);
        reporterStore.submitScore(report, _encodeSignature(v, r, s));
    }

    function testSubmitScoreRevertsIfNonceReused() public {
        ReporterSignalStore.SignalReport memory report = ReporterSignalStore.SignalReport({
            poolId: PoolId.unwrap(poolId),
            signalType: uint8(ReporterSignalStore.SignalType.Sandwich),
            score: 0.5e18,
            nonce: 1,
            validUntil: block.timestamp + 1 hours
        });

        // First submission succeeds
        (uint8 v, bytes32 r, bytes32 s) = _sign(
            REPORTER_KEY,
            PoolId.unwrap(poolId),
            uint8(ReporterSignalStore.SignalType.Sandwich),
            0.5e18,
            1,
            block.timestamp + 1 hours
        );
        reporterStore.submitScore(report, _encodeSignature(v, r, s));

        // Replay with same nonce reverts
        vm.expectRevert(ReporterSignalStore.InvalidNonce.selector);
        reporterStore.submitScore(report, _encodeSignature(v, r, s));
    }

    function testSubmitScoreRevertsIfExpired() public {
        uint256 validUntil = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = _sign(
            REPORTER_KEY,
            PoolId.unwrap(poolId),
            uint8(ReporterSignalStore.SignalType.Sandwich),
            0.5e18,
            1,
            validUntil
        );

        ReporterSignalStore.SignalReport memory report = ReporterSignalStore.SignalReport({
            poolId: PoolId.unwrap(poolId),
            signalType: uint8(ReporterSignalStore.SignalType.Sandwich),
            score: 0.5e18,
            nonce: 1,
            validUntil: validUntil
        });

        // Warp past validUntil
        vm.warp(validUntil);

        vm.expectRevert(ReporterSignalStore.ReportExpired.selector);
        reporterStore.submitScore(report, _encodeSignature(v, r, s));
    }

    // ── setAuthorizedReporter ────────────────────────────────────────────

    function testSetAuthorizedReporterOnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        reporterStore.setAuthorizedReporter(address(0xCAFE), true);
    }

    function testSetAuthorizedReporterOwnerCanAuthorize() public {
        reporterStore.setAuthorizedReporter(address(0xCAFE), true);
        assertTrue(reporterStore.authorizedReporters(address(0xCAFE)));
    }

    function testSetAuthorizedReporterOwnerCanRevoke() public {
        reporterStore.setAuthorizedReporter(address(0xCAFE), true);
        reporterStore.setAuthorizedReporter(address(0xCAFE), false);
        assertFalse(reporterStore.authorizedReporters(address(0xCAFE)));
    }
}

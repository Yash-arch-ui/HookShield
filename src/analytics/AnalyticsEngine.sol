// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title AnalyticsEngine
/// @notice Records per-swap metrics for post-hoc analysis and monitoring.
///         Only the authorized writer (the hook) may call `recordSwap()`.
///         Uses the same one-time setWriter lock pattern as the storage contracts.
contract AnalyticsEngine {
    address public writer;
    bool public writerLocked;

    uint256 public totalSwaps;
    uint256 public totalTradeSize;
    uint256 public totalRiskE18;
    uint256 public totalFeesCharged;

    struct SwapRecord {
        bytes32 poolId;
        uint256 tradeSize;
        uint256 riskE18;
        uint24 fee;
        uint256 timestamp;
        bool zeroForOne;
    }

    event SwapRecorded(
        uint256 indexed index, bytes32 indexed poolId, uint256 tradeSize, uint256 riskE18, uint24 fee, bool zeroForOne
    );
    event WriterSet(address indexed writer);

    error NotWriter();
    error WriterLocked();
    error ZeroAddress();

    modifier onlyWriter() {
        if (msg.sender != writer) revert NotWriter();
        _;
    }

    /// @notice Sets the authorized writer. Callable by anyone, but only once.
    function setWriter(address _writer) external {
        if (writerLocked) revert WriterLocked();
        if (_writer == address(0)) revert ZeroAddress();
        writer = _writer;
        writerLocked = true;
        emit WriterSet(_writer);
    }

    /// @notice Records a completed swap. Called from the hook's afterSwap.
    function recordSwap(bytes32 poolId, uint256 tradeSize, uint256 riskE18, uint24 fee, bool zeroForOne)
        external
        onlyWriter
    {
        uint256 idx = totalSwaps;

        totalSwaps++;
        totalTradeSize += tradeSize;
        totalRiskE18 += riskE18;
        totalFeesCharged += fee;

        emit SwapRecorded(idx, poolId, tradeSize, riskE18, fee, zeroForOne);
    }

    // ── View helpers ───────────────────────────────────────────────

    function avgRiskE18() external view returns (uint256) {
        return totalSwaps == 0 ? 0 : totalRiskE18 / totalSwaps;
    }

    function avgFeesCharged() external view returns (uint256) {
        return totalSwaps == 0 ? 0 : totalFeesCharged / totalSwaps;
    }
}

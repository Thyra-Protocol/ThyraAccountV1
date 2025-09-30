// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title ISafeMultiSend - Interface for Gnosis Safe MultiSend
/// @dev Interface for executing multiple transactions in a single call
interface ISafeMultiSend {
    /// @notice Send multiple transactions in a single call
    /// @param transactions Encoded transactions. Each transaction is packed as:
    /// operation (1 byte) + to (20 bytes) + value (32 bytes) + data length (32 bytes) + data
    function multiSend(bytes memory transactions) external;
}

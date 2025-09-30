// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title IExecutorTypes
/// @author ThyraWallet Team
/// @notice Type definitions for ExecutorFacet functionality with Merkle tree-based task execution
/// @custom:version 2.0.0
interface IExecutorTypes {
    /// @notice Types of calls that can be made
    enum CallType {
        CALL,
        DELEGATECALL
    }

    /// @notice Status of a task
    enum TaskStatus {
        INACTIVE, // Task is inactive (default state), operations cannot be executed
        ACTIVE, // Task is active and operations can be executed
        COMPLETED, // Task is completed, no more operations can be executed
        CANCELLED // Task is cancelled, no more operations can be executed

    }

    /**
     * @notice Data structure for a Merkle tree leaf node, representing a complete, verifiable operation
     * @param target Target contract address for this operation
     * @param value Amount of ETH to send with this call (msg.value)
     * @param callData Complete encoded function call data
     * @param callType Specifies whether this operation is CALL or DELEGATECALL
     * @param operationId Unique ID within current task (Merkle tree) to prevent replay attacks for non-repeatable operations
     * @param isRepeatable Flag indicating whether this operation can be executed multiple times
     * @param startTime Start timestamp when this operation can be executed (Unix timestamp)
     * @param endTime End timestamp when this operation can be executed (Unix timestamp)
     * @param maxGasPrice Maximum gas price the executor is willing to pay (wei)
     * @param gasLimit Maximum gas amount this operation can consume
     * @param gasToken ERC20 token address used for gas payment (address(0) means native ETH)
     */
    struct Operation {
        // Core Execution Payload
        address target;
        uint256 value;
        bytes callData;
        CallType callType;
        // Security & Validation Parameters
        uint32 operationId;
        bool isRepeatable;
        uint32 startTime;
        uint32 endTime;
        uint256 maxGasPrice;
        uint256 gasLimit;
        address gasToken;
    }

    /**
     * @notice EIP712 execution parameters structure for signing
     * @param operation Operation type as uint8 (0=CALL, 1=DELEGATECALL)
     * @param to Target contract address
     * @param account Account address performing the operation
     * @param executor Authorized executor address
     * @param value Amount of ETH to send
     * @param nonce Execution nonce for replay protection
     * @param data Call data to execute
     */
    struct ExecutionParams {
        uint8 operation;
        address to;
        address account;
        address executor;
        uint256 value;
        uint256 nonce;
        bytes data;
    }
}

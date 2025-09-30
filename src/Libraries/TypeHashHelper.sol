// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {IExecutorTypes} from "../Interfaces/IExecutorTypes.sol";

/// @title TypeHashHelper
/// @author ThyraWallet Team
/// @notice Helper library for building EIP712 struct and type hashes for ExecutorFacet
/// @custom:version 1.0.0
library TypeHashHelper {
    /// @notice EIP712 typehash for ExecutionParams struct
    /// @dev keccak256("ExecutionParams(uint8 operation,address to,address account,address executor,uint256 value,uint256 nonce,bytes data)")
    bytes32 public constant EXECUTION_PARAMS_TYPEHASH =
        0xcbcf1f852d5a617380bab8f3af98748a75511b055ee426bbd76ef7cdf634b6b1;

    /// @notice Builds EIP712 execution struct hash
    /// @param params Execution parameters struct for EIP712 signing
    /// @return Structured hash for EIP712 signing
    function buildExecutionParamsHash(IExecutorTypes.ExecutionParams memory params) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                EXECUTION_PARAMS_TYPEHASH,
                params.operation,
                params.to,
                params.account,
                params.executor,
                params.value,
                params.nonce,
                keccak256(params.data)
            )
        );
    }

    /// @notice Converts CallType enum to operation uint8
    /// @param callType The call type to convert
    /// @return operation The operation as uint8 (0=CALL, 1=DELEGATECALL)
    function parseOperationEnum(IExecutorTypes.CallType callType) internal pure returns (uint8 operation) {
        if (callType == IExecutorTypes.CallType.DELEGATECALL) {
            operation = 1;
        } else if (callType == IExecutorTypes.CallType.CALL) {
            operation = 0;
        }
        // Note: No revert for invalid CallType as enum is restricted to valid values
    }
}

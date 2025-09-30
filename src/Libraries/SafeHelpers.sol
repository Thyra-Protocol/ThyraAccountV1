// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title SafeHelpers - Library for Safe transaction encoding
/// @notice Based on Brahma.fi implementation for enhanced security
library SafeHelpers {
    enum CallType {
        CALL, // 0 - Regular call
        DELEGATECALL // 1 - Delegate call

    }

    struct Executable {
        CallType callType;
        address target;
        uint256 value;
        bytes data;
    }

    /// @notice Errors
    error InvalidMultiSendInput();
    error UnableToParseOperation();

    /// @notice Pack multiple transactions for MultiSend
    /// @param _txns Array of executable transactions
    /// @return packedTxns Packed transaction data
    /// @dev Enhanced version based on Brahma implementation with strict validation
    function packMultisendTxns(Executable[] memory _txns) internal pure returns (bytes memory packedTxns) {
        uint256 len = _txns.length;
        if (len == 0) revert InvalidMultiSendInput();

        uint256 i = 0;
        do {
            uint8 call = uint8(_parseOperationEnum(_txns[i].callType));
            uint256 calldataLength = _txns[i].data.length;

            bytes memory encodedTxn = abi.encodePacked(
                bytes1(call), bytes20(_txns[i].target), bytes32(_txns[i].value), bytes32(calldataLength), _txns[i].data
            );

            if (i != 0) {
                // If not first transaction, append to packedTxns
                packedTxns = abi.encodePacked(packedTxns, encodedTxn);
            } else {
                // If first transaction, set packedTxns to encodedTxn
                packedTxns = encodedTxn;
            }

            unchecked {
                ++i;
            }
        } while (i < len);
    }

    /// @notice Converts a CallType enum to operation code with validation
    /// @dev Reverts with UnableToParseOperation error if the CallType is not supported
    /// @param callType The CallType enum to be converted
    /// @return operation The converted operation code (0 for CALL, 1 for DELEGATECALL)
    function _parseOperationEnum(CallType callType) internal pure returns (CallType operation) {
        if (callType == CallType.DELEGATECALL) {
            operation = CallType.DELEGATECALL; // = 1
        } else if (callType == CallType.CALL) {
            operation = CallType.CALL; // = 0
        } else {
            revert UnableToParseOperation();
        }
    }
}

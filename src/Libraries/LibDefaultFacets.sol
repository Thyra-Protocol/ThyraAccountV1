// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title LibDefaultFacets
/// @author ThyraWallet Team
/// @notice Pure logic library for classifying default facet function selectors for fast-path lookup optimization
/// @dev This library contains no state, only provides function selector to facet type mapping logic
/// @custom:version 1.0.0
library LibDefaultFacets {
    /// @notice Default Facet type enumeration
    /// @dev None indicates the selector doesn't belong to any default facet, needs storage lookup
    enum DefaultFacetType {
        None, // Not a default facet, requires storage lookup
        DiamondCut, // DiamondCutFacet - Diamond upgrade functionality
        DiamondLoupe, // DiamondLoupeFacet - Diamond information query
        Executor, // ExecutorFacet - Task execution functionality
        Ownership // OwnershipFacet - Ownership management

    }

    /// @notice Get the corresponding default facet type based on function selector
    /// @dev Uses if/else if chain for efficient selector matching, avoiding loops and complex logic
    /// @param _selector Function selector to classify
    /// @return Corresponding DefaultFacetType, returns None if no match
    function getDefaultFacetType(bytes4 _selector) internal pure returns (DefaultFacetType) {
        // ExecutorFacet function selectors (HIGHEST FREQUENCY - user transactions)
        if (
            _selector == 0x66b2661e // executeTransaction(bytes32,(address,uint256,bytes,uint8,uint32,bool,uint32,uint32,uint256,uint256,address),bytes32[]) - Most common
                || _selector == 0x4ad52e02 // getTaskInfo(bytes32)
                || _selector == 0x054de23d // isOperationExecuted(bytes32,uint32)
                || _selector == 0x58497f61 // registerTask(bytes32,address,address,uint96,uint96)
                || _selector == 0x786d1f37 // updateTaskStatus(bytes32,uint8)
                || _selector == 0xfd1c0a60
        ) {
            // getThyraRegistry()
            return DefaultFacetType.Executor;
        }
        // DiamondLoupeFacet function selectors (MEDIUM FREQUENCY - tooling queries)
        else if (
            _selector == 0x7a0ed627 // facets()
                || _selector == 0xcdffacc6 // facetAddress(bytes4)
                || _selector == 0x01ffc9a7 // supportsInterface(bytes4)
                || _selector == 0x52ef6b2c // facetAddresses()
                || _selector == 0xadfca15e
        ) {
            // facetFunctionSelectors(address)
            return DefaultFacetType.DiamondLoupe;
        }
        // OwnershipFacet function selectors (LOW FREQUENCY - admin operations)
        else if (
            _selector == 0x8da5cb5b // owner() - Most common ownership query
                || _selector == 0xf2fde38b // transferOwnership(address)
                || _selector == 0x7200b829 // confirmOwnershipTransfer()
                || _selector == 0x23452b9c // cancelOwnershipTransfer()
                || _selector == 0x485cc955 // initialize(address,address)
                || _selector == 0x88cfce56 // safeWallet()
                || _selector == 0xc45a0155 // factory()
        ) {
            return DefaultFacetType.Ownership;
        }
        // DiamondCutFacet function selectors (LOWEST FREQUENCY - rare upgrades)
        else if (_selector == 0x1f931c1c) {
            // diamondCut((address,uint8,bytes4[])[],address,bytes)
            return DefaultFacetType.DiamondCut;
        }
        // If no default facet matches, return None
        else {
            return DefaultFacetType.None;
        }
    }
}

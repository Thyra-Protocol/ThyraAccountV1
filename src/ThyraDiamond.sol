// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {LibDiamond} from "./Libraries/LibDiamond.sol";
import {IDiamondCut} from "./Interfaces/IDiamondCut.sol";
import {LibDefaultFacets} from "./Libraries/LibDefaultFacets.sol";
// solhint-disable-next-line no-unused-import
import {LibUtil} from "./Libraries/LibUtil.sol";

/// @title Thyra Diamond
/// @author ThyraWallet Team
/// @notice Base EIP-2535 Diamond Proxy Contract for Thyra Account.
/// @custom:version 1.0.0
contract ThyraDiamond {
    /// @notice Safe wallet address that this Diamond is a module of
    address public safeWallet;

    /// @notice Factory address that deployed this Diamond (immutable for security)
    address public immutable FACTORY;

    /// @notice Default facet addresses using immutable for gas-optimized fast path
    address private immutable I_DIAMOND_CUT_FACET;
    address private immutable I_DIAMOND_LOUPE_FACET;
    address private immutable I_EXECUTOR_FACET;
    address private immutable I_OWNERSHIP_FACET;

    /// @notice Whether the Safe wallet address has been initialized
    bool private initialized;

    /// @notice Errors
    error OnlyFactory();
    error AlreadyInitialized();
    error InvalidSafeAddress();

    constructor(
        address _contractOwner,
        address _diamondCutFacet,
        address _diamondLoupeFacet,
        address _executorFacet,
        address _ownershipFacet
    ) payable {
        FACTORY = msg.sender;
        LibDiamond.setContractOwner(_contractOwner);

        // Initialize immutable default facet addresses for fast path optimization
        I_DIAMOND_CUT_FACET = _diamondCutFacet;
        I_DIAMOND_LOUPE_FACET = _diamondLoupeFacet;
        I_EXECUTOR_FACET = _executorFacet;
        I_OWNERSHIP_FACET = _ownershipFacet;

        // Add the diamondCut external function from the diamondCutFacet
        LibDiamond.FacetCut[] memory cut = new LibDiamond.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = LibDiamond.FacetCut({
            facetAddress: _diamondCutFacet,
            action: LibDiamond.FacetCutAction.Add,
            functionSelectors: functionSelectors
        });
        LibDiamond.diamondCut(cut, address(0), "");
    }

    // Two-tiered lookup system: fast path + slow path fallback
    // Provides gas-optimized fast path lookup for commonly used default facets
    // solhint-disable-next-line no-complex-fallback
    fallback() external payable {
        address facet;

        // Phase 1: Fast path - check if default facet (no storage access, extremely low gas cost)
        LibDefaultFacets.DefaultFacetType facetType = LibDefaultFacets.getDefaultFacetType(msg.sig);

        if (facetType == LibDefaultFacets.DefaultFacetType.DiamondCut) {
            facet = I_DIAMOND_CUT_FACET;
        } else if (facetType == LibDefaultFacets.DefaultFacetType.DiamondLoupe) {
            facet = I_DIAMOND_LOUPE_FACET;
        } else if (facetType == LibDefaultFacets.DefaultFacetType.Executor) {
            facet = I_EXECUTOR_FACET;
        } else if (facetType == LibDefaultFacets.DefaultFacetType.Ownership) {
            facet = I_OWNERSHIP_FACET;
        } else {
            // Phase 2: Slow path - fallback to Diamond storage lookup (compatibility guarantee)
            LibDiamond.DiamondStorage storage ds;
            bytes32 position = LibDiamond.DIAMOND_STORAGE_POSITION;

            // get diamond storage
            // solhint-disable-next-line no-inline-assembly
            assembly {
                ds.slot := position
            }

            // get facet from function selector
            facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        }

        // Validate facet address validity
        if (facet == address(0)) {
            revert LibDiamond.FunctionDoesNotExist();
        }

        // Execute delegatecall to target facet (final execution logic same for both paths)
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // copy function selector and any arguments
            calldatacopy(0, 0, calldatasize())
            // execute function call using the facet
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            // get any return value
            returndatacopy(0, 0, returndatasize())
            // return any return value or error back to the caller
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /**
     * @notice Set the Safe wallet address that this Diamond is a module of
     * @dev Only the factory can call this function, and only once
     *      Automatically transfers Diamond ownership to the Safe wallet
     * @param _safeWallet Address of the Safe wallet
     */
    function setSafeWallet(address _safeWallet) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        if (_safeWallet == address(0)) revert InvalidSafeAddress();

        safeWallet = _safeWallet;
        initialized = true;
        
        // Transfer ownership from Factory to Safe wallet
        // This allows Safe (and its owners through multi-sig) to manage the Diamond
        LibDiamond.setContractOwner(_safeWallet);
    }

    // Able to receive ether
    // solhint-disable-next-line no-empty-blocks
    receive() external payable {}
}

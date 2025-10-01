// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {LibDiamond} from "../Libraries/LibDiamond.sol";
import {IERC173} from "../Interfaces/IERC173.sol";
import {LibUtil} from "../Libraries/LibUtil.sol";

/// @title Ownership Facet
/// @author ThyraWallet Team (based on LI.FI)
/// @notice Manages ownership of the Thyra Diamond contract and Safe wallet initialization
/// @custom:version 1.0.0
contract OwnershipFacet is IERC173 {
    /// Storage ///
    bytes32 internal constant NAMESPACE = keccak256("com.lifi.facets.ownership");

    /// Types ///
    struct Storage {
        address newOwner;           // Pending ownership transfer address
        address factory;            // Factory address that deployed this Diamond
        address safeWallet;         // Safe wallet address that this Diamond is a module of
        bool initialized;           // Whether Safe wallet has been initialized
    }

    /// Errors ///
    error NoNullOwner();
    error NewOwnerMustNotBeSelf();
    error NoPendingOwnershipTransfer();
    error NotPendingOwner();
    error OnlyFactory();
    error AlreadyInitialized();
    error InvalidSafeAddress();

    /// Events ///
    event OwnershipTransferRequested(address indexed _from, address indexed _to);

    /// External Methods ///

    /// @notice Initiates transfer of ownership to a new address
    /// @param _newOwner the address to transfer ownership to
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = getStorage();

        if (LibUtil.isZeroAddress(_newOwner)) revert NoNullOwner();
        if (_newOwner == LibDiamond.contractOwner()) revert NewOwnerMustNotBeSelf();

        s.newOwner = _newOwner;
        emit OwnershipTransferRequested(msg.sender, s.newOwner);
    }

    /// @notice Cancel transfer of ownership
    function cancelOwnershipTransfer() external {
        LibDiamond.enforceIsContractOwner();
        Storage storage s = getStorage();

        if (LibUtil.isZeroAddress(s.newOwner)) revert NoPendingOwnershipTransfer();
        s.newOwner = address(0);
    }

    /// @notice Confirms transfer of ownership to the calling address (msg.sender)
    function confirmOwnershipTransfer() external {
        Storage storage s = getStorage();
        address _pendingOwner = s.newOwner;
        if (msg.sender != _pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(LibDiamond.contractOwner(), _pendingOwner);
        LibDiamond.setContractOwner(_pendingOwner);
        s.newOwner = address(0);
    }

    /// @notice Return the current owner address
    /// @return owner_ The current owner address
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    /// Safe Wallet Initialization Methods ///

    /// @notice Initialize Diamond with factory and Safe wallet
    /// @dev Called by Factory after deployment. Can only be called once.
    ///      Combines factory and Safe wallet setup in a single transaction for gas efficiency.
    /// @param _factory Address of the Factory that deployed this Diamond
    /// @param _safeWallet Address of the Safe wallet that this Diamond is a module of
    function initialize(address _factory, address _safeWallet) external {
        Storage storage s = getStorage();
        
        // Can only initialize once
        if (s.initialized) revert AlreadyInitialized();
        if (LibUtil.isZeroAddress(_factory)) revert InvalidSafeAddress();
        if (LibUtil.isZeroAddress(_safeWallet)) revert InvalidSafeAddress();
        
        // Set factory address
        s.factory = _factory;
        
        // Set Safe wallet
        s.safeWallet = _safeWallet;
        s.initialized = true;
        
        // Transfer ownership from Factory to Safe wallet
        // This allows Safe (and its owners through multi-sig) to manage the Diamond
        LibDiamond.setContractOwner(_safeWallet);
    }

    /// @notice Get the Safe wallet address
    /// @return Safe wallet address (zero address if not initialized)
    function safeWallet() external view returns (address) {
        return getStorage().safeWallet;
    }

    /// @notice Get the factory address
    /// @return Factory address that deployed this Diamond
    function factory() external view returns (address) {
        return getStorage().factory;
    }


    /// Private Methods ///

    /// @dev fetch local storage
    function getStorage() private pure returns (Storage storage s) {
        bytes32 namespace = NAMESPACE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := namespace
        }
    }
}

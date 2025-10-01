// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {IERC173} from "./IERC173.sol";

/// @title Interface for OwnershipFacet (Extended)
/// @author ThyraWallet Team
/// @notice Extended ownership interface including Safe wallet initialization
/// @custom:version 1.0.0
interface IOwnershipFacet is IERC173 {
    /// @notice Initialize Diamond with factory and Safe wallet
    /// @param _factory Address of the Factory that deployed this Diamond
    /// @param _safeWallet Address of the Safe wallet
    function initialize(address _factory, address _safeWallet) external;

    /// @notice Get the Safe wallet address
    /// @return Safe wallet address (zero address if not initialized)
    function safeWallet() external view returns (address);

    /// @notice Get the factory address
    /// @return Factory address that deployed this Diamond
    function factory() external view returns (address);
}


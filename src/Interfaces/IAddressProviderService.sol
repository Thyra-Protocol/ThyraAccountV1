// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title IAddressProviderService
/// @author Thyra.fi
/// @notice Interface for providing global service addresses to Diamond facets
/// @custom:version 1.0.0
interface IAddressProviderService {
    /// @notice Get the ThyraRegistry contract address
    /// @return The address of the ThyraRegistry contract
    function getThyraRegistry() external view returns (address);
}

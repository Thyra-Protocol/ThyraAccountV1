// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title ISafeProxyFactory - Interface for Gnosis Safe Proxy Factory
/// @dev Interface for creating new Safe proxies
interface ISafeProxyFactory {
    /// @notice Creates a new Safe proxy with a nonce
    /// @param _singleton The singleton address
    /// @param initializer The initializer data
    /// @param saltNonce The salt nonce for CREATE2
    /// @return proxy The address of the created proxy
    function createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);

    /// @notice Calculates the proxy address that would be created
    /// @param _singleton The singleton address
    /// @param initializer The initializer data
    /// @param saltNonce The salt nonce for CREATE2
    /// @param callback Optional callback address
    /// @return proxy The calculated proxy address
    function calculateCreateProxyWithNonceAddress(
        address _singleton,
        bytes calldata initializer,
        uint256 saltNonce,
        address callback
    ) external view returns (address proxy);
}

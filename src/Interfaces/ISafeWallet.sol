// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

/// @title ISafeWallet - Interface for Gnosis Safe Wallet
/// @dev Essential interface for Safe wallet functionality
interface ISafeWallet {
    /// @notice Setup function to initialize the Safe
    /// @param _owners List of Safe owners
    /// @param _threshold Number of required confirmations
    /// @param to Contract address for optional delegate call
    /// @param data Payload for optional delegate call
    /// @param fallbackHandler Handler for fallback calls
    /// @param paymentToken Token that should be used for payment (0 is ETH)
    /// @param payment Value that should be paid
    /// @param paymentReceiver Address that should receive the payment
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    /// @notice Enable a module on the Safe
    /// @param module Module to be whitelisted
    function enableModule(address module) external;

    /// @notice Set a guard that checks transactions before execution
    /// @param guard The address of the guard to be used
    function setGuard(address guard) external;

    /// @notice Returns the current threshold
    function getThreshold() external view returns (uint256);

    /// @notice Returns array of owners
    function getOwners() external view returns (address[] memory);

    /// @notice Returns if an owner is valid
    /// @param owner Owner address
    function isOwner(address owner) external view returns (bool);

    /// @notice Returns the current guard
    function getGuard() external view returns (address);
}

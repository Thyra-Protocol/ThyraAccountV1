// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/// @title ThyraRegistry
/// @author Thyra.fi
/// @notice Global configuration and whitelist registry for the Thyra ecosystem
/// @dev This contract serves as the single source of truth for global configurations,
///      fee token whitelists, executor whitelists, and fee configurations across
///      all Thyra Diamond contracts and future facets.
/// @custom:version 1.0.0
contract ThyraRegistry {
    /// @notice Contract owner address
    address public owner;

    /// @notice Mapping of fee tokens to their whitelist status
    /// @dev ERC20 tokens that are approved for use as payment for transaction fees
    mapping(address => bool) public isFeeTokenWhitelisted;

    /// @notice Mapping of executors to their whitelist status
    /// @dev Globally approved executor addresses that can execute operations
    mapping(address => bool) public isExecutorWhitelisted;

    /// @notice Fee configuration structure
    /// @dev Defines the minimum and maximum fees for each whitelisted fee token
    struct FeeConfig {
        uint96 minFee; // Minimum fee amount (in token's smallest unit)
        uint96 maxFee; // Maximum fee amount (in token's smallest unit)
    }

    /// @notice Mapping of fee tokens to their fee configurations
    /// @dev Stores the min/max fee bounds for each whitelisted fee token
    mapping(address => FeeConfig) public feeTokenConfigs;

    /// @notice Events
    event FeeTokenWhitelistChanged(address indexed token, bool isWhitelisted);
    event ExecutorWhitelistChanged(address indexed executor, bool isWhitelisted);
    event FeeConfigChanged(address indexed token, uint96 minFee, uint96 maxFee);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Errors
    error OnlyOwner();
    error InvalidFeeBounds();
    error TokenNotWhitelisted();
    error ZeroAddress();
    error ExecutorNotWhitelisted();
    error FeeTokenNotWhitelisted();
    error InvalidFeeRange();

    /// @notice Modifier to restrict function access to contract owner only
    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @notice Contract constructor
    /// @dev Initializes the contract with the deployer as the initial owner
    constructor() {
        owner = msg.sender;
    }

    /// @notice Set the whitelist status of a fee token
    /// @dev Only the contract owner can add or remove fee tokens from the whitelist
    /// @param _token The ERC20 token address to update
    /// @param _isWhitelisted True to add to whitelist, false to remove
    function setFeeToken(address _token, bool _isWhitelisted) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();

        isFeeTokenWhitelisted[_token] = _isWhitelisted;
        emit FeeTokenWhitelistChanged(_token, _isWhitelisted);
    }

    /// @notice Set the whitelist status of an executor
    /// @dev Only the contract owner can add or remove executors from the global whitelist
    /// @param _executor The executor address to update
    /// @param _isWhitelisted True to add to whitelist, false to remove
    function setExecutor(address _executor, bool _isWhitelisted) external onlyOwner {
        if (_executor == address(0)) revert ZeroAddress();

        isExecutorWhitelisted[_executor] = _isWhitelisted;
        emit ExecutorWhitelistChanged(_executor, _isWhitelisted);
    }

    /// @notice Set the fee configuration for a whitelisted token
    /// @dev Only the contract owner can set fee configurations, and only for whitelisted tokens
    /// @param _token The ERC20 token address to configure
    /// @param _minFee The minimum fee amount (must be <= maxFee)
    /// @param _maxFee The maximum fee amount (must be >= minFee)
    function setFeeConfig(address _token, uint96 _minFee, uint96 _maxFee) external onlyOwner {
        if (_token == address(0)) revert ZeroAddress();
        if (_minFee > _maxFee) revert InvalidFeeBounds();
        if (!isFeeTokenWhitelisted[_token]) revert TokenNotWhitelisted();

        feeTokenConfigs[_token] = FeeConfig({minFee: _minFee, maxFee: _maxFee});

        emit FeeConfigChanged(_token, _minFee, _maxFee);
    }

    /// @notice Transfer ownership of the contract to a new address
    /// @dev Only the current owner can transfer ownership
    /// @param _newOwner The address of the new owner (cannot be zero address)
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();

        address previousOwner = owner;
        owner = _newOwner;

        emit OwnershipTransferred(previousOwner, _newOwner);
    }

    /// @notice Validate task registration parameters against global configuration
    /// @dev Centralized validation logic for task registration across all Diamond contracts
    /// @param _executor Executor address to validate
    /// @param _feeToken Fee token address to validate
    /// @param _initFee Initial fee amount to validate
    /// @param _maxFee Maximum fee amount to validate
    function validateTaskRegistration(address _executor, address _feeToken, uint96 _initFee, uint96 _maxFee)
        external
        view
    {
        // Validate zero addresses
        if (_executor == address(0) || _feeToken == address(0)) {
            revert ZeroAddress();
        }

        // Check executor whitelist
        if (!isExecutorWhitelisted[_executor]) {
            revert ExecutorNotWhitelisted();
        }

        // Check fee token whitelist
        if (!isFeeTokenWhitelisted[_feeToken]) {
            revert FeeTokenNotWhitelisted();
        }

        // Validate fee range against registry config
        FeeConfig memory config = feeTokenConfigs[_feeToken];
        if (
            _initFee < config.minFee || _initFee > config.maxFee || _maxFee < config.minFee || _maxFee > config.maxFee
                || _initFee > _maxFee
        ) {
            revert InvalidFeeRange();
        }
    }
}

// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Create2} from "openzeppelin-contracts/contracts/utils/Create2.sol";
import {SafeProxyFactory, SafeProxy} from "safe-smart-account/contracts/proxies/SafeProxyFactory.sol";
import {SafeHelpers} from "./Libraries/SafeHelpers.sol";
import {ThyraDiamond} from "./ThyraDiamond.sol";
import {IOwnershipFacet} from "./Interfaces/IOwnershipFacet.sol";

/// @title ThyraFactory
/// @author ThyraWallet Team
/// @notice Factory contract for deploying Thyra Accounts (Safe + ThyraDiamond module)
/// @dev All facet implementations should be pre-deployed and shared across all Diamond instances
///      This follows the standard Diamond proxy pattern where facets are reusable implementations
/// @custom:version 1.0.0
contract ThyraFactory is ReentrancyGuard {
    /// @notice Version of the factory
    string public constant VERSION = "1.0";

    /// @notice Safe Proxy Factory address
    address public immutable SAFE_PROXY_FACTORY;

    /// @notice Safe Singleton implementation address
    address public immutable SAFE_SINGLETON;

    /// @notice Safe MultiSend contract address
    address public immutable SAFE_MULTI_SEND;

    /// @notice Safe fallback handler address
    address public immutable SAFE_FALLBACK_HANDLER;

    /// @notice Pre-deployed facet addresses shared by all Diamond instances
    address public immutable DIAMOND_CUT_FACET;
    address public immutable DIAMOND_LOUPE_FACET;
    address public immutable EXECUTOR_FACET;
    address public immutable OWNERSHIP_FACET;

    /// @notice ThyraRegistry address for ExecutorFacet instances
    address public immutable THYRA_REGISTRY;

    /// @notice Track deployment nonces for deterministic addresses
    mapping(bytes32 ownersHash => uint256 count) public ownerSafeCount;

    /// @notice Events
    event ThyraAccountDeployed(
        address indexed safeAddress, address indexed diamondAddress, address[] owners, uint256 threshold
    );
    event ThyraSubAccountDeployed(
        address indexed subAccount,
        address indexed diamond,
        address indexed parentSafe,
        address[] owners,
        uint256 threshold
    );

    /// @notice Errors
    error SafeProxyCreationFailed();
    error DiamondDeploymentFailed();
    error ModuleEnableFailed();
    error InvalidParentSafe();

    /// @notice Constructor - all facet addresses should be pre-deployed implementations
    /// @param _safeProxyFactory Address of Safe Proxy Factory
    /// @param _safeSingleton Address of Safe Singleton
    /// @param _safeMultiSend Address of Safe MultiSend
    /// @param _safeFallbackHandler Address of Safe Fallback Handler
    /// @param _diamondCutFacet Address of pre-deployed DiamondCutFacet implementation
    /// @param _diamondLoupeFacet Address of pre-deployed DiamondLoupeFacet implementation
    /// @param _executorFacet Address of pre-deployed ExecutorFacet implementation
    /// @param _ownershipFacet Address of pre-deployed OwnershipFacet implementation
    /// @param _thyraRegistry Address of ThyraRegistry for ExecutorFacet
    constructor(
        address _safeProxyFactory,
        address _safeSingleton,
        address _safeMultiSend,
        address _safeFallbackHandler,
        address _diamondCutFacet,
        address _diamondLoupeFacet,
        address _executorFacet,
        address _ownershipFacet,
        address _thyraRegistry
    ) {
        SAFE_PROXY_FACTORY = _safeProxyFactory;
        SAFE_SINGLETON = _safeSingleton;
        SAFE_MULTI_SEND = _safeMultiSend;
        SAFE_FALLBACK_HANDLER = _safeFallbackHandler;
        DIAMOND_CUT_FACET = _diamondCutFacet;
        DIAMOND_LOUPE_FACET = _diamondLoupeFacet;
        EXECUTOR_FACET = _executorFacet;
        OWNERSHIP_FACET = _ownershipFacet;
        THYRA_REGISTRY = _thyraRegistry;
    }

    /// @notice Deploy a new Thyra Account (Safe + ThyraDiamond module)
    /// @param _owners List of Safe owners
    /// @param _threshold Number of required confirmations
    /// @param _salt Salt for deterministic deployment
    /// @return _safe Address of deployed Safe wallet
    function deployThyraAccount(address[] calldata _owners, uint256 _threshold, bytes32 _salt)
        external
        nonReentrant
        returns (address _safe)
    {
        bytes32 ownersHash = keccak256(abi.encode(_owners));

        // 1. Deploy ThyraDiamond first (will be enabled as module)
        address diamond = _deployThyraDiamond(_salt, ownersHash);

        // 2. Deploy Safe proxy with inline initialization data
        _safe = _createSafe(_setupSafeWithModule(_owners, _threshold, diamond, false, address(0)), _owners, _salt);

        // 3. Initialize Diamond with factory and Safe address in one call
        IOwnershipFacet(diamond).initialize(address(this), _safe);

        // 4. Emit event
        emit ThyraAccountDeployed(_safe, diamond, _owners, _threshold);
    }

    /// @notice Deploy a new Thyra Sub Account with parent Safe as module
    /// @param _owners List of Safe owners
    /// @param _threshold Number of required confirmations
    /// @param _parentSafe Address of parent Safe that will be enabled as module
    /// @param _salt Salt for deterministic deployment
    /// @return _subAccount Address of deployed Sub Account Safe
    function deploySubAccount(address[] calldata _owners, uint256 _threshold, address _parentSafe, bytes32 _salt)
        external
        nonReentrant
        returns (address _subAccount)
    {
        // Validate parent Safe address
        if (_parentSafe == address(0)) revert InvalidParentSafe();

        // Note: We don't check if _parentSafe is valid because:
        // 1. An invalid _parentSafe brings no benefit to the sub account owner
        // 2. It's the caller's responsibility to provide a valid parent Safe
        // 3. An invalid module simply won't function, causing no harm

        bytes32 ownersHash = keccak256(abi.encode(_owners));

        // 1. Deploy ThyraDiamond first (will be enabled as module)
        address diamond = _deployThyraDiamond(_salt, ownersHash);

        // 2. Deploy Safe proxy with both modules (diamond + parent safe)
        _subAccount = _createSafe(_setupSafeWithModule(_owners, _threshold, diamond, true, _parentSafe), _owners, _salt);

        // 3. Initialize Diamond with factory and Safe address in one call
        IOwnershipFacet(diamond).initialize(address(this), _subAccount);

        // 4. Emit event
        emit ThyraSubAccountDeployed(_subAccount, diamond, _parentSafe, _owners, _threshold);
    }

    /// @notice Deploy a new ThyraDiamond contract using pre-deployed facets with nonce retry mechanism
    /// @param _salt Salt for deterministic deployment
    /// @param _ownersHash Hash of owners array for nonce generation
    /// @return diamond Address of deployed ThyraDiamond
    function _deployThyraDiamond(bytes32 _salt, bytes32 _ownersHash) private returns (address diamond) {
        // Deploy ThyraDiamond with pre-deployed shared facet addresses
        bytes memory creationCode = abi.encodePacked(
            type(ThyraDiamond).creationCode,
            abi.encode(
                address(this), // _contractOwner (temporary, will be transferred to Safe)
                DIAMOND_CUT_FACET, // _diamondCutFacet (shared implementation)
                DIAMOND_LOUPE_FACET, // _diamondLoupeFacet (shared implementation)
                EXECUTOR_FACET, // _executorFacet (shared implementation)
                OWNERSHIP_FACET // _ownershipFacet (shared implementation)
            )
        );

        // Try deployment with incremental nonce until successful (similar to Safe deployment)
        do {
            // Generate nonce using the same counter as Safe deployment
            uint256 nonce = ownerSafeCount[_ownersHash];
            
            // Generate salt for Create2 deployment with nonce
            bytes32 salt = keccak256(abi.encodePacked("ThyraDiamond", _salt, nonce, VERSION));

            // Compute the address that would be deployed
            address predictedAddress = Create2.computeAddress(salt, keccak256(creationCode), address(this));
            
            // Check if contract already exists at this address
            if (predictedAddress.code.length > 0) {
                // Address collision, increment nonce and retry
                ownerSafeCount[_ownersHash]++;
                continue;
            }
            
            // Deploy using Create2
            diamond = Create2.deploy(0, salt, creationCode);
            
            // Deployment successful, exit loop
            break;
        } while (ownerSafeCount[_ownersHash] < type(uint256).max);

        // Check deployment was successful
        if (diamond == address(0)) revert DiamondDeploymentFailed();
    }

    /// @notice Setup Safe initialization data with modules
    /// @param _owners List of Safe owners
    /// @param _threshold Number of required confirmations
    /// @param _diamond Address of ThyraDiamond to enable as module
    /// @param _isSubAccount Whether this is a sub account (needs parent Safe as module)
    /// @param _parentSafe Address of parent Safe (only used if isSubAccount is true)
    /// @return Encoded setup data for Safe proxy
    function _setupSafeWithModule(
        address[] memory _owners,
        uint256 _threshold,
        address _diamond,
        bool _isSubAccount,
        address _parentSafe
    ) private view returns (bytes memory) {
        // Determine number of transactions needed
        uint256 txnCount = _isSubAccount ? 2 : 1;
        SafeHelpers.Executable[] memory txns = new SafeHelpers.Executable[](txnCount);

        // Always enable ThyraDiamond as module
        txns[0] = SafeHelpers.Executable({
            callType: SafeHelpers.CallType.CALL,
            target: address(0), // Will be set to Safe address during setup
            value: 0,
            data: abi.encodeWithSignature("enableModule(address)", _diamond)
        });

        // If this is a sub account, also enable parent Safe as module
        if (_isSubAccount) {
            if (_parentSafe == address(0)) revert InvalidParentSafe();

            txns[1] = SafeHelpers.Executable({
                callType: SafeHelpers.CallType.CALL,
                target: address(0), // Will be set to Safe address during setup
                value: 0,
                data: abi.encodeWithSignature("enableModule(address)", _parentSafe)
            });
        }

        // Pack transactions for MultiSend
        bytes memory packedTxns = SafeHelpers.packMultisendTxns(txns);

        // Return Safe setup call
        return abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            _owners, // _owners
            _threshold, // _threshold
            SAFE_MULTI_SEND, // to (MultiSend for setup)
            abi.encodeWithSignature( // data (MultiSend call)
            "multiSend(bytes)", packedTxns),
            SAFE_FALLBACK_HANDLER, // fallbackHandler
            address(0), // paymentToken (ETH)
            0, // payment
            payable(address(0)) // paymentReceiver
        );
    }

    /// @notice Create Safe proxy with nonce retry mechanism
    /// @param _initializer Safe setup data
    /// @param _owners List of owners for nonce calculation
    /// @param _salt User provided salt
    /// @return _safe Address of created Safe
    function _createSafe(bytes memory _initializer, address[] calldata _owners, bytes32 _salt)
        private
        returns (address _safe)
    {
        bytes32 ownersHash = keccak256(abi.encode(_owners));

        // Try deployment with incremental nonce until successful
        do {
            uint256 nonce = _genNonce(ownersHash, _salt);

            try SafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, _initializer, nonce) returns (
                SafeProxy deployedProxy
            ) {
                _safe = address(deployedProxy);
            } catch {
                // Nonce collision, will retry with incremented nonce
                // ownerSafeCount was already incremented in _genNonce
            }
        } while (_safe == address(0));

        if (_safe == address(0)) revert SafeProxyCreationFailed();
    }

    /// @notice Generate deterministic nonce for Safe deployment
    /// @param _ownersHash Hash of owners array
    /// @param _salt User provided salt
    /// @return Generated nonce
    function _genNonce(bytes32 _ownersHash, bytes32 _salt) private returns (uint256) {
        return uint256(keccak256(abi.encodePacked(_ownersHash, ownerSafeCount[_ownersHash]++, _salt, VERSION)));
    }
}

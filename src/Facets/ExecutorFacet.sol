// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.24;

import {MerkleProof} from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import {LibDiamond} from "../Libraries/LibDiamond.sol";
import {IExecutorTypes} from "../Interfaces/IExecutorTypes.sol";
import {IAddressProviderService} from "../Interfaces/IAddressProviderService.sol";
import {IOwnershipFacet} from "../Interfaces/IOwnershipFacet.sol";
import {BigMathMinified} from "../Libraries/bigMathMinified.sol";
import {ThyraRegistry} from "../ThyraRegistry.sol";
import {IModuleManager} from "safe-smart-account/contracts/interfaces/IModuleManager.sol";
import {Enum} from "safe-smart-account/contracts/libraries/Enum.sol";

/// @title ExecutorFacet
/// @author Thyra.fi
/// @notice Facet for executing transactions through Merkle tree-based task system
/// @dev This Facet allows contract owners to register tasks and authorized executors to execute operations with Merkle proofs
/// @custom:version 3.0.0
contract ExecutorFacet is IExecutorTypes, IAddressProviderService {
    /// Storage ///
    bytes32 internal constant NAMESPACE = keccak256("io.thyra.facets.executor");

    /// @notice ThyraRegistry address for all ExecutorFacet instances
    /// @dev This address is set once during deployment and shared by all Diamond instances
    address public immutable THYRA_REGISTRY;

    /// @notice Constructor to set the ThyraRegistry address
    /// @param _thyraRegistry Address of the ThyraRegistry contract
    constructor(address _thyraRegistry) {
        THYRA_REGISTRY = _thyraRegistry;
    }

    /// Types ///
    /// @notice Optimized Task structure using only 2 storage slots
    /// @dev Slot 1: executor (20 bytes) + executedOperationsBitmap (11 bytes) + status (1 byte)
    ///      Slot 2: feeToken (20 bytes) + initFee (6 bytes) + maxFee (6 bytes)
    ///      Note: merkleRoot is now the mapping key, no longer stored in struct
    struct Task {
        // --- Slot 1: 32 bytes (Packed) ---
        uint256 slot1; // Contains: executor(160 bits) + executedOperationsBitmap(88 bits) + status(8 bits)
        // --- Slot 2: 32 bytes (Packed) ---
        uint256 slot2; // Contains: feeToken(160 bits) + initFee(48 bits) + maxFee(48 bits)
    }

    struct Storage {
        /// @notice Task registry mapping from Merkle root to task details
        mapping(bytes32 merkleRoot => Task) tasks;
    }

    /// Errors ///
    error TaskNotFound();
    error UnauthorizedExecutor();
    error TaskNotActive();
    error InvalidMerkleProof();
    error OperationAlreadyExecuted();
    error OperationNotRepeatable();
    error InvalidTimeWindow();
    error GasPriceTooHigh();
    error ExecutionFailed();
    error InvalidCallType();
    error InvalidTaskStatus();
    error OperationIdOutOfBounds();
    error ModuleExecutionFailed();
    error TaskAlreadyRegistered();

    /// Events ///
    event TaskRegistered(
        bytes32 indexed merkleRoot, address indexed executor, address feeToken, uint256 initFee, uint256 maxFee
    );
    event TaskStatusChanged(bytes32 indexed merkleRoot, TaskStatus oldStatus, TaskStatus newStatus);
    event ExecutionSuccess(
        bytes32 indexed merkleRoot,
        address indexed executor,
        address indexed target,
        uint256 value,
        bytes data,
        CallType callType
    );

    /// External Methods ///

    /**
     * @notice Register a new task with operations Merkle tree and activate it immediately
     * @dev Integrates with ThyraRegistry for global validation of executors and fee tokens
     * @param _merkleRoot Merkle root of the task operations tree
     * @param _executor Authorized executor address for this task
     * @param _feeToken ERC20 token address for fee payment
     * @param _initFee Initial fee amount in the token's native decimals
     * @param _maxFee Maximum fee amount in the token's native decimals
     */
    function registerTask(bytes32 _merkleRoot, address _executor, address _feeToken, uint96 _initFee, uint96 _maxFee)
        external
    {
        // Must be called by contract owner
        LibDiamond.enforceIsContractOwner();

        Storage storage s = getStorage();
        Task storage task = s.tasks[_merkleRoot];

        // Check if task already exists
        if (task.slot1 != 0) {
            revert TaskAlreadyRegistered();
        }

        // Validate with hardcoded ThyraRegistry using centralized validation
        ThyraRegistry registry = ThyraRegistry(THYRA_REGISTRY);

        // Single call to validate all task registration parameters
        registry.validateTaskRegistration(_executor, _feeToken, _initFee, _maxFee);

        // Convert fees to BigNumber format (48-bit each)
        uint256 initFeeBigNum = BigMathMinified.toBigNumber(_initFee, 40, 8, false);
        uint256 maxFeeBigNum = BigMathMinified.toBigNumber(_maxFee, 40, 8, false);

        // Slot1 layout: executor(160 bits) | bitmap(88 bits) | status(8 bits)
        task.slot1 = uint256(uint8(TaskStatus.ACTIVE)) | (0 << 8) // bitmap starts empty (88 bits)
            | (uint256(uint160(_executor)) << 96);

        // Slot2 layout: feeToken(160 bits) | initFee(48 bits) | maxFee(48 bits)
        task.slot2 = maxFeeBigNum | (initFeeBigNum << 48) | (uint256(uint160(_feeToken)) << 96);

        emit TaskRegistered(_merkleRoot, _executor, _feeToken, _initFee, _maxFee);
    }

    /**
     * @notice Update task status with role-based permissions
     * @dev Owner: can set non-completed tasks to CANCELLED
     *      Executor: can set ACTIVE tasks to COMPLETED or CANCELLED
     * @param _merkleRoot Merkle root identifying the task
     * @param _newStatus New status for the task
     */
    function updateTaskStatus(bytes32 _merkleRoot, TaskStatus _newStatus) external {
        Storage storage s = getStorage();
        Task storage task = s.tasks[_merkleRoot];

        // Check if task exists
        if (task.slot1 == 0) {
            revert TaskNotFound();
        }

        // Unpack required data for validation and events
        uint256 slot1 = task.slot1;
        address executor = address(uint160(slot1 >> 96));
        TaskStatus oldStatus = TaskStatus(uint8(slot1 & 0xFF));

        // Role-based permission checks
        bool isOwner = (msg.sender == LibDiamond.contractOwner());
        bool isExecutor = (msg.sender == executor);

        if (
            !(
                (isOwner && _newStatus == TaskStatus.CANCELLED && oldStatus != TaskStatus.COMPLETED)
                    || (
                        isExecutor && oldStatus == TaskStatus.ACTIVE
                            && (_newStatus == TaskStatus.COMPLETED || _newStatus == TaskStatus.CANCELLED)
                    )
            )
        ) {
            if (isOwner || isExecutor) {
                revert InvalidTaskStatus();
            } else {
                revert UnauthorizedExecutor();
            }
        }

        // Update only the status bits (lowest 8 bits), keep other bits unchanged
        task.slot1 = (slot1 & ~uint256(0xFF)) | uint256(uint8(_newStatus));

        emit TaskStatusChanged(_merkleRoot, oldStatus, _newStatus);
    }

    /**
     * @notice Execute a registered task operation through Merkle proof
     * @dev Implements a clear 4-phase validation process before execution using memory snapshots
     * @param _merkleRoot Merkle root identifying the task and validating the operation
     * @param _operation Operation to execute (Merkle leaf)
     * @param _merkleProof Merkle proof to validate the operation
     * @return returnData Data returned by the executed transaction
     */
    function executeTransaction(bytes32 _merkleRoot, Operation calldata _operation, bytes32[] calldata _merkleProof)
        external
        returns (bytes memory returnData)
    {
        Storage storage s = getStorage();

        // Load task slot1 into memory for efficient access
        uint256 slot1 = s.tasks[_merkleRoot].slot1;

        // Phase 1: Task basic state validation
        _validateTaskState(slot1);

        // Phase 2: Cryptographic validation
        _validateMerkleProof(_merkleRoot, _operation, _merkleProof);

        // Phase 3: Operation internal constraints validation
        _validateOperationConstraints(slot1, _operation);

        // Validation passed, execute transaction

        // Step 4: Execute operation
        returnData = _executeOperation(_operation);

        // Step 5: Update execution state (if needed)
        _updateExecutionState(_merkleRoot, slot1, _operation.operationId, _operation.isRepeatable);

        emit ExecutionSuccess(
            _merkleRoot, msg.sender, _operation.target, _operation.value, _operation.callData, _operation.callType
        );

        return returnData;
    }

    /**
     * @notice Get task information
     * @param _merkleRoot Merkle root identifying the task
     * @return executor Authorized executor address
     * @return status Current task status
     * @return feeToken Fee token address
     * @return initFee Initial fee amount (in original decimals)
     * @return maxFee Maximum fee amount (in original decimals)
     */
    function getTaskInfo(bytes32 _merkleRoot)
        external
        view
        returns (address executor, TaskStatus status, address feeToken, uint256 initFee, uint256 maxFee)
    {
        Storage storage s = getStorage();
        Task storage task = s.tasks[_merkleRoot];

        // Check if task exists
        if (task.slot1 == 0) {
            revert TaskNotFound();
        }

        // Unpack data from slots using direct bit operations
        uint256 slot1 = task.slot1;
        uint256 slot2 = task.slot2;

        executor = address(uint160(slot1 >> 96));
        status = TaskStatus(uint8(slot1 & 0xFF));

        feeToken = address(uint160(slot2 >> 96));
        initFee = (slot2 >> 48) & ((1 << 48) - 1);
        maxFee = slot2 & ((1 << 48) - 1);

        // Convert BigNumber fees back to normal numbers
        if (initFee > 0) {
            initFee = BigMathMinified.fromBigNumber(initFee, 8, 0xFF);
        }
        if (maxFee > 0) {
            maxFee = BigMathMinified.fromBigNumber(maxFee, 8, 0xFF);
        }

        return (executor, status, feeToken, initFee, maxFee);
    }

    /**
     * @notice Get the ThyraRegistry contract address
     * @return The address of the ThyraRegistry contract
     */
    function getThyraRegistry() external view returns (address) {
        return THYRA_REGISTRY;
    }

    /**
     * @notice Check if a specific operation has been executed
     * @param _merkleRoot Merkle root identifying the task
     * @param _operationId Operation ID to check (must be < 88 due to bitmap size constraint)
     * @return executed Whether the operation has been executed
     */
    function isOperationExecuted(bytes32 _merkleRoot, uint32 _operationId) external view returns (bool executed) {
        if (_operationId >= 88) {
            revert OperationIdOutOfBounds();
        }

        Storage storage s = getStorage();
        Task storage task = s.tasks[_merkleRoot];

        // Check if task exists
        if (task.slot1 == 0) {
            revert TaskNotFound();
        }

        uint256 bitmap = (task.slot1 >> 8) & ((1 << 88) - 1);
        executed = (bitmap & (1 << _operationId)) != 0;
    }

    /// Internal Methods ///

    /**
     * @notice Phase 1: Validate task state and caller permissions
     * @dev Checks task existence, executor authorization, and task active status
     * @param _slot1 Task slot1 memory snapshot
     */
    function _validateTaskState(uint256 _slot1) internal view {
        // Check if task exists - fail fast
        if (_slot1 == 0) {
            revert TaskNotFound();
        }

        // Only the designated executor can execute operations
        if (msg.sender != address(uint160(_slot1 >> 96))) {
            revert UnauthorizedExecutor();
        }

        // Check if task is active
        if (TaskStatus(uint8(_slot1 & 0xFF)) != TaskStatus.ACTIVE) {
            revert TaskNotActive();
        }
    }

    /**
     * @notice Phase 2: Validate Merkle proof cryptographically
     * @dev Ensures the operation is part of the merkle tree
     * @param _merkleRoot Root of the merkle tree
     * @param _operation Operation to validate
     * @param _merkleProof Merkle proof for the operation
     */
    function _validateMerkleProof(bytes32 _merkleRoot, Operation calldata _operation, bytes32[] calldata _merkleProof)
        internal
        pure
    {
        bytes32 leafHash = keccak256(abi.encode(_operation));
        if (!MerkleProof.verify(_merkleProof, _merkleRoot, leafHash)) {
            revert InvalidMerkleProof();
        }
    }

    /**
     * @notice Phase 3: Validate operation constraints and execution eligibility
     * @dev Checks call type, operation ID bounds, time window, gas price, and repeatability
     * @param _slot1 Task slot1 memory snapshot containing execution state
     * @param _operation Operation to validate
     */
    function _validateOperationConstraints(uint256 _slot1, Operation calldata _operation) internal view {
        // Check operation ID bounds for our 88-bit bitmap - fail fast
        if (_operation.operationId >= 88) {
            revert OperationIdOutOfBounds();
        }

        // Check call type - we only support CALL, not DELEGATECALL
        if (_operation.callType != CallType.CALL) {
            revert InvalidCallType();
        }

        // Check time window
        if (block.timestamp < _operation.startTime || block.timestamp > _operation.endTime) {
            revert InvalidTimeWindow();
        }

        // Check gas price
        if (tx.gasprice > _operation.maxGasPrice) {
            revert GasPriceTooHigh();
        }

        // If operation is not repeatable, check execution history
        if (!_operation.isRepeatable) {
            uint256 bitmap = (_slot1 >> 8) & ((1 << 88) - 1);
            if ((bitmap & (1 << _operation.operationId)) != 0) {
                revert OperationAlreadyExecuted();
            }
        }
    }

    /**
     * @notice Update memory snapshot with executed operation and write back to storage
     * @dev Only updates for non-repeatable operations
     * @param _merkleRoot Merkle root identifying the task
     * @param _slot1 Current slot1 memory snapshot
     * @param _operationId Operation ID to mark as executed
     * @param _isRepeatable Whether the operation can be executed multiple times
     */
    function _updateExecutionState(bytes32 _merkleRoot, uint256 _slot1, uint32 _operationId, bool _isRepeatable)
        internal
    {
        if (!_isRepeatable) {
            // Single OR operation to set the operation bit in the bitmap
            Storage storage s = getStorage();
            s.tasks[_merkleRoot].slot1 = _slot1 | (1 << (_operationId + 8));
        }
    }

    /**
     * @notice Execute operation through Safe wallet as module
     * @param _operation Operation to execute
     * @return returnData Data returned by execution
     */
    function _executeOperation(Operation memory _operation) internal returns (bytes memory returnData) {
        // Get Safe wallet address via OwnershipFacet interface
        // CRITICAL: We cannot use assembly sload(0) because ReentrancyGuard's _status 
        // variable also uses slot 0, which would conflict in delegatecall context
        address safeWallet = IOwnershipFacet(address(this)).safeWallet();

        // Execute transaction through Safe as module
        // CallType already validated in _validateOperationConstraints, we only support CALL
        (bool success, bytes memory txnResult) = IModuleManager(safeWallet).execTransactionFromModuleReturnData(
            _operation.target, _operation.value, _operation.callData, Enum.Operation.Call
        );

        if (!success) {
            // Forward revert reason if available
            if (txnResult.length > 0) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(32, txnResult), mload(txnResult))
                }
            } else {
                revert ModuleExecutionFailed();
            }
        }

        return txnResult;
    }

    /// @dev Fetch local storage using Diamond storage pattern
    function getStorage() private pure returns (Storage storage s) {
        bytes32 namespace = NAMESPACE;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            s.slot := namespace
        }
    }
}

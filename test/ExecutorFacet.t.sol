// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {Test, console2} from "forge-std/Test.sol";
import {ThyraDiamond} from "../src/ThyraDiamond.sol";
import {DiamondCutFacet} from "../src/Facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/Facets/DiamondLoupeFacet.sol";
import {ExecutorFacet} from "../src/Facets/ExecutorFacet.sol";
import {OwnershipFacet} from "../src/Facets/OwnershipFacet.sol";
import {IExecutorTypes} from "../src/Interfaces/IExecutorTypes.sol";

// Safe contracts (simplified imports for testing)
import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {SafeProxyFactory} from "safe-smart-account/contracts/proxies/SafeProxyFactory.sol";

/// @title ExecutorFacetTest
/// @notice Comprehensive tests for ExecutorFacet with Merkle tree-based task execution
contract ExecutorFacetTest is Test, IExecutorTypes {
    // Core contracts
    ThyraDiamond public diamond;
    DiamondCutFacet public diamondCutFacet;
    DiamondLoupeFacet public diamondLoupeFacet;
    ExecutorFacet public executorFacet;
    OwnershipFacet public ownershipFacet;

    // Mock contracts
    MockThyraRegistry public thyraRegistry;
    MockTarget public mockTarget;
    Safe public safeWallet;

    // Test accounts
    address public diamondOwner;
    address public taskExecutor;
    address public user1;
    address public feeToken;

    // Test constants
    bytes32 public constant TEST_MERKLE_ROOT = keccak256("test-merkle-root");
    uint96 public constant INIT_FEE = 1000;
    uint96 public constant MAX_FEE = 2000;

    // Events
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

    function setUp() public {
        // Set up test accounts
        diamondOwner = makeAddr("diamondOwner");
        taskExecutor = makeAddr("taskExecutor");
        user1 = makeAddr("user1");
        feeToken = makeAddr("feeToken");

        // Deploy mock contracts
        thyraRegistry = new MockThyraRegistry();
        mockTarget = new MockTarget();

        // Deploy all facet implementations
        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        executorFacet = new ExecutorFacet(address(thyraRegistry));
        ownershipFacet = new OwnershipFacet();

        console2.log("ExecutorFacet deployed at:", address(executorFacet));
        console2.log("ThyraRegistry deployed at:", address(thyraRegistry));

        // Deploy diamond with all default facets
        diamond = new ThyraDiamond(
            diamondOwner,
            address(diamondCutFacet),
            address(diamondLoupeFacet),
            address(executorFacet),
            address(ownershipFacet)
        );

        console2.log("ThyraDiamond deployed at:", address(diamond));

        // Deploy and link Safe wallet
        _deploySafeWallet();

        // Set up registry permissions
        thyraRegistry.setExecutorAllowed(taskExecutor, true);
        thyraRegistry.setFeeTokenAllowed(feeToken, true);
    }

    /// @notice Deploy and link Safe wallet to Diamond
    function _deploySafeWallet() internal {
        // Deploy Safe singleton and factory (simplified setup)
        Safe safeSingleton = new Safe();
        SafeProxyFactory safeFactory = new SafeProxyFactory();

        // Create Safe wallet with diamond as owner
        address[] memory owners = new address[](1);
        owners[0] = diamondOwner;

        bytes memory safeInitData = abi.encodeWithSelector(
            Safe.setup.selector, owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))
        );

        safeWallet =
            Safe(payable(safeFactory.createProxyWithNonce(address(safeSingleton), safeInitData, block.timestamp)));

        // Link Safe to Diamond
        vm.startPrank(diamondOwner);
        ThyraDiamond(payable(address(diamond))).setSafeWallet(address(safeWallet));
        vm.stopPrank();

        console2.log("Safe wallet deployed at:", address(safeWallet));
    }

    /*//////////////////////////////////////////////////////////////
                            BASIC FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DeploymentSuccess() public view {
        assertTrue(address(diamond) != address(0));
        assertTrue(address(executorFacet) != address(0));
        assertTrue(address(thyraRegistry) != address(0));
    }

    function test_SafeIntegration() public view {
        // Verify Diamond is linked to Safe
        assertEq(ThyraDiamond(payable(address(diamond))).safeWallet(), address(safeWallet));

        // Verify Diamond is enabled as Safe module
        assertTrue(safeWallet.isModuleEnabled(address(diamond)));
    }

    /*//////////////////////////////////////////////////////////////
                            TASK REGISTRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RegisterTask_Success() public {
        vm.startPrank(diamondOwner);

        // Expect event emission
        vm.expectEmit(true, true, false, true);
        emit TaskRegistered(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        // Register task
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        // Verify task registration
        (address executor, TaskStatus status, address token, uint256 initFee, uint256 maxFee) =
            ExecutorFacet(address(diamond)).getTaskInfo(TEST_MERKLE_ROOT);

        assertEq(executor, taskExecutor);
        assertEq(uint8(status), uint8(TaskStatus.ACTIVE));
        assertEq(token, feeToken);
        assertEq(initFee, INIT_FEE);
        assertEq(maxFee, MAX_FEE);

        vm.stopPrank();
    }

    function test_RegisterTask_OnlyOwner() public {
        vm.startPrank(user1);

        vm.expectRevert(); // Should revert with owner check
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        vm.stopPrank();
    }

    function test_RegisterTask_DuplicateRoot() public {
        vm.startPrank(diamondOwner);

        // Register first task
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        // Try to register again with same root
        vm.expectRevert("Task already registered");
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            TASK STATUS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UpdateTaskStatus_OwnerCanCancel() public {
        // First register a task
        vm.startPrank(diamondOwner);
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        // Owner should be able to cancel task
        vm.expectEmit(true, false, false, true);
        emit TaskStatusChanged(TEST_MERKLE_ROOT, TaskStatus.ACTIVE, TaskStatus.CANCELLED);

        ExecutorFacet(address(diamond)).updateTaskStatus(TEST_MERKLE_ROOT, TaskStatus.CANCELLED);

        // Verify status change
        (, TaskStatus status,,,) = ExecutorFacet(address(diamond)).getTaskInfo(TEST_MERKLE_ROOT);
        assertEq(uint8(status), uint8(TaskStatus.CANCELLED));

        vm.stopPrank();
    }

    function test_UpdateTaskStatus_ExecutorCanComplete() public {
        // First register a task
        vm.startPrank(diamondOwner);
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);
        vm.stopPrank();

        // Executor should be able to complete task
        vm.startPrank(taskExecutor);

        vm.expectEmit(true, false, false, true);
        emit TaskStatusChanged(TEST_MERKLE_ROOT, TaskStatus.ACTIVE, TaskStatus.COMPLETED);

        ExecutorFacet(address(diamond)).updateTaskStatus(TEST_MERKLE_ROOT, TaskStatus.COMPLETED);

        // Verify status change
        (, TaskStatus status,,,) = ExecutorFacet(address(diamond)).getTaskInfo(TEST_MERKLE_ROOT);
        assertEq(uint8(status), uint8(TaskStatus.COMPLETED));

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExecuteTransaction_SimpleCall() public {
        // Register task first
        vm.startPrank(diamondOwner);
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);
        vm.stopPrank();

        // Create operation
        Operation memory operation = Operation({
            target: address(mockTarget),
            value: 0,
            callData: abi.encodeWithSelector(MockTarget.setValue.selector, 42),
            callType: CallType.CALL,
            operationId: 0,
            isRepeatable: false,
            startTime: uint32(block.timestamp - 100),
            endTime: uint32(block.timestamp + 100),
            maxGasPrice: 1000000000, // 1 gwei
            gasLimit: 100000,
            gasToken: address(0)
        });

        // Create simple Merkle proof (single operation tree)
        bytes32[] memory proof = new bytes32[](0);
        bytes32 operationHash = keccak256(abi.encode(operation));

        // For this simple test, we'll use the operation hash as merkle root
        bytes32 simpleMerkleRoot = operationHash;

        // Register task with the correct merkle root
        vm.startPrank(diamondOwner);
        ExecutorFacet(address(diamond)).registerTask(simpleMerkleRoot, taskExecutor, feeToken, INIT_FEE, MAX_FEE);
        vm.stopPrank();

        // Execute transaction
        vm.startPrank(taskExecutor);

        vm.expectEmit(true, true, true, true);
        emit ExecutionSuccess(simpleMerkleRoot, taskExecutor, address(mockTarget), 0, operation.callData, CallType.CALL);

        ExecutorFacet(address(diamond)).executeTransaction(simpleMerkleRoot, operation, proof);

        // Verify execution result
        assertEq(mockTarget.value(), 42);

        // Verify operation is marked as executed (non-repeatable)
        assertTrue(ExecutorFacet(address(diamond)).isOperationExecuted(simpleMerkleRoot, 0));

        vm.stopPrank();
    }

    function test_ExecuteTransaction_UnauthorizedExecutor() public {
        // Register task
        vm.startPrank(diamondOwner);
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);
        vm.stopPrank();

        // Create operation
        Operation memory operation = Operation({
            target: address(mockTarget),
            value: 0,
            callData: abi.encodeWithSelector(MockTarget.setValue.selector, 42),
            callType: CallType.CALL,
            operationId: 0,
            isRepeatable: false,
            startTime: uint32(block.timestamp - 100),
            endTime: uint32(block.timestamp + 100),
            maxGasPrice: 1000000000,
            gasLimit: 100000,
            gasToken: address(0)
        });

        bytes32[] memory proof = new bytes32[](0);

        // Try to execute from unauthorized user
        vm.startPrank(user1);
        vm.expectRevert(); // Should revert with UnauthorizedExecutor
        ExecutorFacet(address(diamond)).executeTransaction(TEST_MERKLE_ROOT, operation, proof);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            QUERY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetTaskInfo_NonExistentTask() public {
        vm.expectRevert(); // Should revert with TaskNotFound
        ExecutorFacet(address(diamond)).getTaskInfo(keccak256("non-existent"));
    }

    function test_IsOperationExecuted_NonExistentTask() public {
        vm.expectRevert(); // Should revert with TaskNotFound
        ExecutorFacet(address(diamond)).isOperationExecuted(keccak256("non-existent"), 0);
    }

    function test_IsOperationExecuted_InvalidOperationId() public {
        // Register task first
        vm.startPrank(diamondOwner);
        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);
        vm.stopPrank();

        // Test operation ID >= 88 (out of bitmap bounds)
        vm.expectRevert(); // Should revert with OperationIdOutOfBounds
        ExecutorFacet(address(diamond)).isOperationExecuted(TEST_MERKLE_ROOT, 88);
    }

    /*//////////////////////////////////////////////////////////////
                            GAS OPTIMIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ExecutorFacetFastPath() public {
        // Test that ExecutorFacet functions use fast path (default facet lookup)

        // Register task - this should use fast path
        vm.startPrank(diamondOwner);
        uint256 gasBefore = gasleft();

        ExecutorFacet(address(diamond)).registerTask(TEST_MERKLE_ROOT, taskExecutor, feeToken, INIT_FEE, MAX_FEE);

        uint256 gasUsed = gasBefore - gasleft();
        console2.log("Gas used for registerTask (fast path):", gasUsed);

        // Verify task was registered
        (address executor,,,,) = ExecutorFacet(address(diamond)).getTaskInfo(TEST_MERKLE_ROOT);
        assertEq(executor, taskExecutor);

        vm.stopPrank();
    }
}

/// @notice Mock ThyraRegistry for testing
contract MockThyraRegistry {
    mapping(address => bool) public executorAllowed;
    mapping(address => bool) public feeTokenAllowed;

    // Custom errors
    error ExecutorNotAllowed();
    error FeeTokenNotAllowed();
    error InvalidFeeRange();

    function setExecutorAllowed(address executor, bool allowed) external {
        executorAllowed[executor] = allowed;
    }

    function setFeeTokenAllowed(address token, bool allowed) external {
        feeTokenAllowed[token] = allowed;
    }

    function validateTaskRegistration(address executor, address feeToken, uint256 initFee, uint256 maxFee)
        external
        view
    {
        if (!executorAllowed[executor]) revert ExecutorNotAllowed();
        if (!feeTokenAllowed[feeToken]) revert FeeTokenNotAllowed();
        if (initFee > maxFee) revert InvalidFeeRange();
        // Additional validation logic would go here
    }
}

/// @notice Mock target contract for testing
contract MockTarget {
    uint256 public value;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    receive() external payable {}
}

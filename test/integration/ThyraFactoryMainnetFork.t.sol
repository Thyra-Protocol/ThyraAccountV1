// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {console2} from "forge-std/Test.sol";

import {BaseTest} from "./BaseTest.sol";
import {ThyraFactory} from "../../src/ThyraFactory.sol";

// Interfaces
import {IOwnershipFacet} from "../../src/Interfaces/IOwnershipFacet.sol";
import {IExecutorTypes} from "../../src/Interfaces/IExecutorTypes.sol";

// Facets
import {ExecutorFacet} from "../../src/Facets/ExecutorFacet.sol";

// Safe interfaces (v1.5 compatible)
import {Safe} from "safe-smart-account/contracts/Safe.sol";

/// @title ThyraFactoryMainnetForkTest
/// @notice Integration tests for ThyraFactory with Safe 1.5 factory on Ethereum mainnet fork
/// @dev Comprehensive test suite covering deployment, executor operations, and DeFi protocol integrations
contract ThyraFactoryMainnetForkTest is BaseTest {
    /// @notice Test initialization (inherits from BaseTest)
    function setUp() public override {
        super.setUp();
    }

    /* ============================================ */
    /*           DEPLOYMENT TESTS                   */
    /* ============================================ */

    /// @notice Test main account deployment via mainnet Safe factory
    function testDeployThyraAccount_MainnetSafe() external {
        bytes32 salt = keccak256("thyra-mainnet-integration");

        address[] memory owners = new address[](2);
        owners[0] = owner1;
        owners[1] = owner2;

        vm.recordLogs();
        address safeAddress = factory.deployThyraAccount(owners, 2, salt);

        assertTrue(safeAddress != address(0), "Safe address should be non-zero");
        assertGt(safeAddress.code.length, 0, "Safe proxy must contain runtime code");

        address diamondAddress = _readDeployedDiamondFromLogs();

        assertTrue(diamondAddress != address(0), "Diamond address should be parsed");
        assertGt(diamondAddress.code.length, 0, "Diamond contract must contain runtime code");

        // Verify Safe state
        Safe safe = Safe(payable(safeAddress));
        assertEq(safe.getThreshold(), 2, "Safe threshold mismatch");
        assertTrue(safe.isOwner(owner1), "Owner1 should be Safe owner");
        assertTrue(safe.isOwner(owner2), "Owner2 should be Safe owner");
        assertTrue(safe.isModuleEnabled(diamondAddress), "Diamond must be Safe module");

        // Verify Diamond is bound to Safe
        assertEq(IOwnershipFacet(diamondAddress).safeWallet(), safeAddress, "Diamond safeWallet mismatch");
        console2.log("[OK] Safe deployed via mainnet factory:", safeAddress);
        console2.log("[OK] ThyraDiamond deployed via Create2:", diamondAddress);
    }

    /// @notice Test sub-account deployment with hierarchical Safe structure
    function testDeploySubAccount_MainnetSafeHierarchy() external {
        (address mainSafe, address mainDiamond) = _deployMainAccount(owner1, owner2, 2, "main-hierarchy");

        address[] memory subOwners = new address[](1);
        subOwners[0] = owner3;
        bytes32 subSalt = keccak256("sub-hierarchy");

        vm.recordLogs();
        address subSafe = factory.deploySubAccount(subOwners, 1, mainSafe, subSalt);
        address subDiamond = _readDeployedDiamondFromLogs();

        assertTrue(subSafe != address(0), "Sub safe should not be zero");
        assertTrue(subDiamond != address(0), "Sub diamond should not be zero");
        assertGt(subSafe.code.length, 0, "Sub safe code should exist");
        assertGt(subDiamond.code.length, 0, "Sub diamond code should exist");

        Safe subSafeContract = Safe(payable(subSafe));
        assertTrue(subSafeContract.isOwner(owner3), "Sub owner must be set");
        assertEq(subSafeContract.getThreshold(), 1, "Sub threshold mismatch");
        assertTrue(subSafeContract.isModuleEnabled(mainSafe), "Parent safe must be enabled as module");
        assertTrue(subSafeContract.isModuleEnabled(subDiamond), "Sub diamond must be module");

        assertEq(IOwnershipFacet(subDiamond).safeWallet(), subSafe, "Sub diamond safe wallet mismatch");
        console2.log("[OK] Sub Safe deployed:", subSafe);
        console2.log("[OK] Sub Diamond deployed:", subDiamond);
        console2.log("[OK] Main diamond binding persists:", mainDiamond);
    }

    /// @notice Test sub-account deployment reverts with invalid parent
    function testDeploySubAccount_InvalidParent() external {
        address[] memory subOwners = new address[](1);
        subOwners[0] = owner3;
        bytes32 salt = keccak256("invalid-parent");

        vm.expectRevert(ThyraFactory.InvalidParentSafe.selector);
        factory.deploySubAccount(subOwners, 1, address(0), salt);
    }

    /// @notice Test salt collision handling with nonce retry mechanism
    function testDeployThyraAccount_RevertWithBadSalt() external {
        address[] memory owners = new address[](1);
        owners[0] = owner1;

        bytes32 salt = keccak256("collision-salt");

        address firstSafe = factory.deployThyraAccount(owners, 1, salt);
        assertTrue(firstSafe != address(0), "First safe deploy should succeed");

        address secondSafe = factory.deployThyraAccount(owners, 1, salt);
        assertTrue(secondSafe != address(0), "Second safe should retry nonce and succeed");
        assertTrue(firstSafe != secondSafe, "Nonce collision should result in different addresses");
    }

    /* ============================================ */
    /*           EXECUTOR FACET TESTS               */
    /* ============================================ */

    /// @notice Test single operation registration and execution (simple ETH transfer)
    function testSimpleOperation_ETHTransfer() external {
        // 1. Deploy Safe + Diamond
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "simple-eth");

        // 2. Configure Registry
        _configureRegistry(executor, USDC);

        // 3. Fund Safe with ETH
        vm.deal(safeAddress, 1 ether);

        // 4. Build single operation: transfer 0.1 ETH
        address recipient = makeAddr("recipient");
        IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);

        // 5. Build Merkle tree (single leaf)
        bytes32 merkleRoot = keccak256(abi.encode(operation));

        // 6. Register Task
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        // 7. Execute operation
        bytes32[] memory proof = new bytes32[](0); // Single leaf requires no proof
        uint256 balanceBefore = recipient.balance;

        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);

        uint256 balanceAfter = recipient.balance;
        assertEq(balanceAfter - balanceBefore, 0.1 ether, "ETH transfer failed");
        console2.log("[OK] Simple ETH transfer executed successfully");
    }

    /// @notice Test multiple operations with Merkle tree validation (3 operations)
    function testMultipleOperations_MerkleProof() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "multi-ops");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 1 ether);

        // Build 3 operations
        address[] memory recipients = new address[](3);
        recipients[0] = makeAddr("recipient1");
        recipients[1] = makeAddr("recipient2");
        recipients[2] = makeAddr("recipient3");

        IExecutorTypes.Operation[] memory operations = new IExecutorTypes.Operation[](3);
        operations[0] = _createETHTransferOperation(recipients[0], 0.1 ether, 0);
        operations[1] = _createETHTransferOperation(recipients[1], 0.2 ether, 1);
        operations[2] = _createETHTransferOperation(recipients[2], 0.3 ether, 2);

        // Build Merkle tree
        (bytes32 merkleRoot, bytes32[] memory leaves) = _buildMerkleTree(operations);

        // Register Task
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        // Execute each operation
        for (uint256 i = 0; i < 3; i++) {
            bytes32[] memory proof = _getMerkleProof(leaves, i);
            uint256 balanceBefore = recipients[i].balance;

            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[i], proof);

            uint256 balanceAfter = recipients[i].balance;
            assertEq(balanceAfter - balanceBefore, operations[i].value, "Transfer amount mismatch");
            console2.log("[OK] Operation executed:", i);
        }

        console2.log("[OK] All 3 operations executed with valid Merkle proofs");
    }

    /// @notice Test operation repeatability constraint
    function testOperation_NonRepeatableConstraint() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "non-repeatable");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 1 ether);

        address recipient = makeAddr("recipient");
        IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
        operation.isRepeatable = false; // Explicitly set to non-repeatable

        bytes32 merkleRoot = keccak256(abi.encode(operation));
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        bytes32[] memory proof = new bytes32[](0);

        // First execution should succeed
        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        console2.log("[OK] First execution succeeded");

        // Second execution should fail
        vm.prank(executor);
        vm.expectRevert(ExecutorFacet.OperationAlreadyExecuted.selector);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        console2.log("[OK] Second execution correctly reverted");
    }

    /// @notice Test repeatable operation execution
    function testOperation_RepeatableExecution() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "repeatable");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 1 ether);
        
        address recipient = makeAddr("recipient");
        IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.05 ether, 0);
        operation.isRepeatable = true; // Set to repeatable

        bytes32 merkleRoot = keccak256(abi.encode(operation));
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        bytes32[] memory proof = new bytes32[](0);
        uint256 balanceBefore = recipient.balance;
        
        // Execute 3 times
        for (uint256 i = 0; i < 3; i++) {
        vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        }
        
        uint256 balanceAfter = recipient.balance;
        assertEq(balanceAfter - balanceBefore, 0.15 ether, "Should receive 0.05 * 3");
        console2.log("[OK] Repeatable operation executed 3 times successfully");
    }

    /// @notice Test time window constraint enforcement
    function testOperation_TimeWindowConstraint() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "time-window");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 1 ether);

        address recipient = makeAddr("recipient");
        IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
        
        // Set future time window
        operation.startTime = uint32(block.timestamp + 1 hours);
        operation.endTime = uint32(block.timestamp + 2 hours);

        bytes32 merkleRoot = keccak256(abi.encode(operation));
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        bytes32[] memory proof = new bytes32[](0);

        // Execution before startTime should fail
        vm.prank(executor);
        vm.expectRevert(ExecutorFacet.InvalidTimeWindow.selector);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        console2.log("[OK] Execution before startTime correctly reverted");

        // Fast forward to within time window
        vm.warp(block.timestamp + 1.5 hours);

        // Should now succeed
        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        console2.log("[OK] Execution within time window succeeded");

        // Fast forward past time window
        vm.warp(block.timestamp + 2 hours);
        
        // Modify operation to repeatable to test time window end
        operation.isRepeatable = true;
        bytes32 newMerkleRoot = keccak256(abi.encode(operation));
        _registerTask(safeAddress, diamondAddress, newMerkleRoot, executor, USDC);

        vm.prank(executor);
        vm.expectRevert(ExecutorFacet.InvalidTimeWindow.selector);
        ExecutorFacet(diamondAddress).executeTransaction(newMerkleRoot, operation, proof);
        console2.log("[OK] Execution after endTime correctly reverted");
    }

    /// @notice Test unauthorized executor rejection
    function testOperation_UnauthorizedExecutor() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "unauthorized");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 1 ether);

        address recipient = makeAddr("recipient");
        IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);

        bytes32 merkleRoot = keccak256(abi.encode(operation));
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        bytes32[] memory proof = new bytes32[](0);

        // Attempt execution with unauthorized address
        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(ExecutorFacet.UnauthorizedExecutor.selector);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        console2.log("[OK] Unauthorized executor correctly reverted");
    }

    /// @notice Test invalid Merkle proof rejection
    function testOperation_InvalidMerkleProof() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "invalid-proof");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 1 ether);

        // Create two different operations
        IExecutorTypes.Operation memory operation1 = _createETHTransferOperation(makeAddr("recipient1"), 0.1 ether, 0);
        IExecutorTypes.Operation memory operation2 = _createETHTransferOperation(makeAddr("recipient2"), 0.2 ether, 1);

        // Register task with operation1
        bytes32 merkleRoot = keccak256(abi.encode(operation1));
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        bytes32[] memory proof = new bytes32[](0);

        // Attempt to execute operation2 (not in tree)
        vm.prank(executor);
        vm.expectRevert(ExecutorFacet.InvalidMerkleProof.selector);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation2, proof);
        console2.log("[OK] Invalid Merkle proof correctly reverted");
    }

    /// @notice Test task status management
    function testTask_StatusManagement() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "status");

        _configureRegistry(executor, USDC);

        address recipient = makeAddr("recipient");
        IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
        bytes32 merkleRoot = keccak256(abi.encode(operation));

        // Register task
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        // Verify task status is ACTIVE
        (, IExecutorTypes.TaskStatus status,,,) = ExecutorFacet(diamondAddress).getTaskInfo(merkleRoot);
        assertEq(uint8(status), uint8(IExecutorTypes.TaskStatus.ACTIVE), "Task should be ACTIVE");

        // Owner can cancel task
        vm.prank(safeAddress);
        ExecutorFacet(diamondAddress).updateTaskStatus(merkleRoot, IExecutorTypes.TaskStatus.CANCELLED);

        (, status,,,) = ExecutorFacet(diamondAddress).getTaskInfo(merkleRoot);
        assertEq(uint8(status), uint8(IExecutorTypes.TaskStatus.CANCELLED), "Task should be CANCELLED");
        console2.log("[OK] Owner cancelled task successfully");

        // Cannot execute after cancellation
        vm.deal(safeAddress, 1 ether);
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(executor);
        vm.expectRevert(ExecutorFacet.TaskNotActive.selector);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
        console2.log("[OK] Execution on cancelled task correctly reverted");
    }

    /// @notice Comprehensive E2E test for operation repeatability protection mechanism
    /// @dev Tests mixed repeatable/non-repeatable operations in same Merkle tree with bitmap state verification
    function testE2E_RepeatabilityProtection() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "e2e-repeat");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 10 ether);

        // Create 5 recipients for different operations
        address[] memory recipients = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            recipients[i] = makeAddr(string(abi.encodePacked("recipient", i)));
        }

        // Build 5 operations with mixed repeatability settings
        IExecutorTypes.Operation[] memory operations = new IExecutorTypes.Operation[](5);
        
        // Operation 0: Non-repeatable (ID: 0)
        operations[0] = _createETHTransferOperation(recipients[0], 0.1 ether, 0);
        operations[0].isRepeatable = false;
        
        // Operation 1: Repeatable (ID: 1)
        operations[1] = _createETHTransferOperation(recipients[1], 0.2 ether, 1);
        operations[1].isRepeatable = true;
        
        // Operation 2: Non-repeatable (ID: 2)
        operations[2] = _createETHTransferOperation(recipients[2], 0.3 ether, 2);
        operations[2].isRepeatable = false;
        
        // Operation 3: Repeatable (ID: 3)
        operations[3] = _createETHTransferOperation(recipients[3], 0.15 ether, 3);
        operations[3].isRepeatable = true;
        
        // Operation 4: Non-repeatable (ID: 4)
        operations[4] = _createETHTransferOperation(recipients[4], 0.25 ether, 4);
        operations[4].isRepeatable = false;

        // Build Merkle tree
        (bytes32 merkleRoot, bytes32[] memory leaves) = _buildMerkleTree(operations);

        // Register task
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

        console2.log("\n[Phase 1] First execution of all operations");
        
        // Execute all operations once
        for (uint256 i = 0; i < 5; i++) {
            bytes32[] memory proof = _getMerkleProof(leaves, i);
            uint256 balanceBefore = recipients[i].balance;

            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[i], proof);

            uint256 balanceAfter = recipients[i].balance;
            assertEq(balanceAfter - balanceBefore, operations[i].value, "First execution failed");
            
            if (operations[i].isRepeatable) {
                console2.log("[OK] Operation", i, "executed (repeatable: true)");
            } else {
                console2.log("[OK] Operation", i, "executed (repeatable: false)");
            }
        }

        console2.log("\n[Phase 2] Verify bitmap state for non-repeatable operations");
        
        // Verify non-repeatable operations are marked as executed
        assertTrue(
            ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, 0),
            "Operation 0 should be marked executed"
        );
        assertTrue(
            ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, 2),
            "Operation 2 should be marked executed"
        );
        assertTrue(
            ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, 4),
            "Operation 4 should be marked executed"
        );
        
        // Verify repeatable operations are NOT marked as executed
        assertFalse(
            ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, 1),
            "Operation 1 should NOT be marked executed"
        );
        assertFalse(
            ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, 3),
            "Operation 3 should NOT be marked executed"
        );
        console2.log("[OK] Bitmap state correctly reflects operation execution");

        console2.log("\n[Phase 3] Attempt to re-execute non-repeatable operations (should fail)");
        
        // Try to execute non-repeatable operations again - should fail
        uint256[] memory nonRepeatableOps = new uint256[](3);
        nonRepeatableOps[0] = 0;
        nonRepeatableOps[1] = 2;
        nonRepeatableOps[2] = 4;

        for (uint256 i = 0; i < nonRepeatableOps.length; i++) {
            uint256 opIndex = nonRepeatableOps[i];
            bytes32[] memory proof = _getMerkleProof(leaves, opIndex);

            vm.prank(executor);
            vm.expectRevert(ExecutorFacet.OperationAlreadyExecuted.selector);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[opIndex], proof);
            console2.log("[OK] Operation", opIndex, "correctly rejected on second attempt");
        }

        console2.log("\n[Phase 4] Re-execute repeatable operations multiple times (should succeed)");
        
        // Execute repeatable operations multiple times
        uint256[] memory repeatableOps = new uint256[](2);
        repeatableOps[0] = 1;
        repeatableOps[1] = 3;

        for (uint256 round = 0; round < 3; round++) {
            console2.log("  Round", round + 2, "execution:");
            
            for (uint256 i = 0; i < repeatableOps.length; i++) {
                uint256 opIndex = repeatableOps[i];
                bytes32[] memory proof = _getMerkleProof(leaves, opIndex);
                uint256 balanceBefore = recipients[opIndex].balance;

                vm.prank(executor);
                ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[opIndex], proof);

                uint256 balanceAfter = recipients[opIndex].balance;
                assertEq(balanceAfter - balanceBefore, operations[opIndex].value, "Repeated execution failed");
                console2.log("  [OK] Operation", opIndex, "executed successfully");
            }
        }

        console2.log("\n[Phase 5] Final balance verification");
        
        // Verify final balances
        // Operation 0: executed 1 time (non-repeatable)
        assertEq(recipients[0].balance, 0.1 ether, "Recipient 0 balance incorrect");
        
        // Operation 1: executed 4 times (repeatable: 1 initial + 3 rounds)
        assertEq(recipients[1].balance, 0.2 ether * 4, "Recipient 1 balance incorrect");
        
        // Operation 2: executed 1 time (non-repeatable)
        assertEq(recipients[2].balance, 0.3 ether, "Recipient 2 balance incorrect");
        
        // Operation 3: executed 4 times (repeatable: 1 initial + 3 rounds)
        assertEq(recipients[3].balance, 0.15 ether * 4, "Recipient 3 balance incorrect");
        
        // Operation 4: executed 1 time (non-repeatable)
        assertEq(recipients[4].balance, 0.25 ether, "Recipient 4 balance incorrect");

        console2.log("[OK] All final balances verified correctly");
        console2.log("\n[SUCCESS] E2E Repeatability Protection Test Completed!");
        console2.log("  - Non-repeatable ops (0,2,4): executed 1x each");
        console2.log("  - Repeatable ops (1,3): executed 4x each");
        console2.log("  - Bitmap protection: VERIFIED");
    }

    /// @notice Test edge case: Operation ID boundary for bitmap (88-bit limit)
    function testE2E_RepeatabilityBitmapBoundary() external {
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "bitmap-boundary");

        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 10 ether);

        // Test operations at bitmap boundaries
        address recipient = makeAddr("recipient");
        
        // Valid operation IDs: 0, 1, 86, 87 (max valid is 87, since bitmap is 88 bits: 0-87)
        uint32[] memory validIds = new uint32[](4);
        validIds[0] = 0;      // Min boundary
        validIds[1] = 1;      // Min + 1
        validIds[2] = 86;     // Max - 1
        validIds[3] = 87;     // Max boundary

        console2.log("\n[Test] Valid operation IDs at bitmap boundaries");
        
        for (uint256 i = 0; i < validIds.length; i++) {
            IExecutorTypes.Operation memory op = _createETHTransferOperation(recipient, 0.01 ether, validIds[i]);
            op.isRepeatable = false;
            
            bytes32 merkleRoot = keccak256(abi.encode(op));
            _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

            bytes32[] memory proof = new bytes32[](0);
            
            // First execution should succeed
            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, op, proof);
            
            // Verify marked as executed
            assertTrue(
                ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, validIds[i]),
                string(abi.encodePacked("Operation ID ", validIds[i], " should be marked executed"))
            );
            
            // Second execution should fail
            vm.prank(executor);
            vm.expectRevert(ExecutorFacet.OperationAlreadyExecuted.selector);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, op, proof);
            
            console2.log("[OK] Operation ID", validIds[i], "protected correctly");
        }

        console2.log("\n[Test] Invalid operation ID (>= 88) should revert");
        
        // Test invalid operation ID (>= 88)
        IExecutorTypes.Operation memory invalidOp = _createETHTransferOperation(recipient, 0.01 ether, 88);
        invalidOp.isRepeatable = false;
        
        bytes32 invalidMerkleRoot = keccak256(abi.encode(invalidOp));
        _registerTask(safeAddress, diamondAddress, invalidMerkleRoot, executor, USDC);

        bytes32[] memory emptyProof = new bytes32[](0);
        
        // Should revert due to operation ID out of bounds
        vm.prank(executor);
        vm.expectRevert(ExecutorFacet.OperationIdOutOfBounds.selector);
        ExecutorFacet(diamondAddress).executeTransaction(invalidMerkleRoot, invalidOp, emptyProof);
        
        console2.log("[OK] Operation ID 88 correctly rejected (out of bounds)");
        console2.log("\n[SUCCESS] Bitmap Boundary Test Completed!");
    }

    /* ============================================ */
    /*         GAS CONSUMPTION BENCHMARKS           */
    /* ============================================ */

    /// @notice Comprehensive gas consumption benchmark for account deployment
    /// @dev Tests deployment costs for main accounts, sub-accounts, and various configurations
    function testE2E_GasConsumption_Deployment() external {
        console2.log("\n========================================");
        console2.log("  GAS CONSUMPTION BENCHMARK - DEPLOYMENT");
        console2.log("========================================\n");

        // Test 1: Main Account Deployment (2-of-2 multisig)
        console2.log("[Test 1] Main Account Deployment (2-of-2 multisig)");
        {
            address[] memory owners = new address[](2);
            owners[0] = owner1;
            owners[1] = owner2;
            bytes32 salt = keccak256("gas-test-main-2of2");

            uint256 gasStart = gasleft();
            vm.recordLogs();
            address safeAddress = factory.deployThyraAccount(owners, 2, salt);
            uint256 gasUsed = gasStart - gasleft();

            address diamondAddress = _readDeployedDiamondFromLogs();

            assertTrue(safeAddress != address(0), "Safe deployment failed");
            assertTrue(diamondAddress != address(0), "Diamond deployment failed");

            console2.log("  Gas Used:", gasUsed);
            console2.log("  Safe Address:", safeAddress);
            console2.log("  Diamond Address:", diamondAddress);
            console2.log("");
        }

        // Test 2: Main Account Deployment (1-of-1 single owner)
        console2.log("[Test 2] Main Account Deployment (1-of-1 single owner)");
        {
            address[] memory owners = new address[](1);
            owners[0] = owner1;
            bytes32 salt = keccak256("gas-test-main-1of1");

            uint256 gasStart = gasleft();
            vm.recordLogs();
            address safeAddress = factory.deployThyraAccount(owners, 1, salt);
            uint256 gasUsed = gasStart - gasleft();

            address diamondAddress = _readDeployedDiamondFromLogs();

            assertTrue(safeAddress != address(0), "Safe deployment failed");
            assertTrue(diamondAddress != address(0), "Diamond deployment failed");

            console2.log("  Gas Used:", gasUsed);
            console2.log("  Safe Address:", safeAddress);
            console2.log("  Diamond Address:", diamondAddress);
            console2.log("");
        }

        // Test 3: Main Account Deployment (3-of-5 multisig)
        console2.log("[Test 3] Main Account Deployment (3-of-5 multisig)");
        {
            address[] memory owners = new address[](5);
            owners[0] = owner1;
            owners[1] = owner2;
            owners[2] = owner3;
            owners[3] = makeAddr("owner4");
            owners[4] = makeAddr("owner5");
            bytes32 salt = keccak256("gas-test-main-3of5");

            uint256 gasStart = gasleft();
            vm.recordLogs();
            address safeAddress = factory.deployThyraAccount(owners, 3, salt);
            uint256 gasUsed = gasStart - gasleft();

            address diamondAddress = _readDeployedDiamondFromLogs();

            assertTrue(safeAddress != address(0), "Safe deployment failed");
            assertTrue(diamondAddress != address(0), "Diamond deployment failed");

            console2.log("  Gas Used:", gasUsed);
            console2.log("  Safe Address:", safeAddress);
            console2.log("  Diamond Address:", diamondAddress);
            console2.log("");
        }

        // Test 4: Sub Account Deployment (1-of-1 with parent)
        console2.log("[Test 4] Sub Account Deployment (1-of-1 with parent)");
        {
            // First deploy a parent account
            (address parentSafe, address parentDiamond) = _deployMainAccount(owner1, owner2, 2, "gas-parent");
            
            address[] memory subOwners = new address[](1);
            subOwners[0] = owner3;
            bytes32 subSalt = keccak256("gas-test-sub-1of1");

            uint256 gasStart = gasleft();
            vm.recordLogs();
            address subSafe = factory.deploySubAccount(subOwners, 1, parentSafe, subSalt);
            uint256 gasUsed = gasStart - gasleft();

            address subDiamond = _readDeployedDiamondFromLogs();

            assertTrue(subSafe != address(0), "Sub safe deployment failed");
            assertTrue(subDiamond != address(0), "Sub diamond deployment failed");

            console2.log("  Gas Used:", gasUsed);
            console2.log("  Parent Safe:", parentSafe);
            console2.log("  Parent Diamond:", parentDiamond);
            console2.log("  Sub Safe:", subSafe);
            console2.log("  Sub Diamond:", subDiamond);
            console2.log("");
        }

        // Test 5: Sub Account Deployment (2-of-3 with parent)
        console2.log("[Test 5] Sub Account Deployment (2-of-3 with parent)");
        {
            // Reuse parent from previous test or deploy new one
            (address parentSafe, address parentDiamond) = _deployMainAccount(owner1, owner2, 2, "gas-parent-2");
            
            address[] memory subOwners = new address[](3);
            subOwners[0] = owner3;
            subOwners[1] = makeAddr("subOwner2");
            subOwners[2] = makeAddr("subOwner3");
            bytes32 subSalt = keccak256("gas-test-sub-2of3");

            uint256 gasStart = gasleft();
            vm.recordLogs();
            address subSafe = factory.deploySubAccount(subOwners, 2, parentSafe, subSalt);
            uint256 gasUsed = gasStart - gasleft();

            address subDiamond = _readDeployedDiamondFromLogs();

            assertTrue(subSafe != address(0), "Sub safe deployment failed");
            assertTrue(subDiamond != address(0), "Sub diamond deployment failed");

            console2.log("  Gas Used:", gasUsed);
            console2.log("  Parent Safe:", parentSafe);
            console2.log("  Parent Diamond:", parentDiamond);
            console2.log("  Sub Safe:", subSafe);
            console2.log("  Sub Diamond:", subDiamond);
            console2.log("");
        }

        console2.log("========================================");
        console2.log("  BENCHMARK COMPLETED");
        console2.log("========================================\n");
    }

    /// @notice Gas consumption benchmark for executor operations
    /// @dev Tests gas costs for task registration, operation execution, and various scenarios
    function testE2E_GasConsumption_Execution() external {
        console2.log("\n========================================");
        console2.log("  GAS CONSUMPTION BENCHMARK - EXECUTION");
        console2.log("========================================\n");

        // Deploy account for testing
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "gas-exec-test");
        _configureRegistry(executor, USDC);
        vm.deal(safeAddress, 10 ether);

        // Test 1: Task Registration
        console2.log("[Test 1] Task Registration");
        {
            address recipient = makeAddr("recipient");
            IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
            bytes32 merkleRoot = keccak256(abi.encode(operation));

            uint256 gasStart = gasleft();
            vm.prank(safeAddress);
            (bool success,) = diamondAddress.call(
                abi.encodeWithSelector(ExecutorFacet.registerTask.selector, merkleRoot, executor, USDC, 0, 100)
            );
            uint256 gasUsed = gasStart - gasleft();

            assertTrue(success, "Task registration failed");
            console2.log("  Gas Used:", gasUsed);
            console2.log("");
        }

        // Test 2: Single Operation Execution (ETH transfer)
        console2.log("[Test 2] Single Operation Execution (ETH transfer)");
        {
            address recipient = makeAddr("recipient2");
            IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
            bytes32 merkleRoot = keccak256(abi.encode(operation));
            
            _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);
            bytes32[] memory proof = new bytes32[](0);

            uint256 gasStart = gasleft();
            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
            uint256 gasUsed = gasStart - gasleft();

            console2.log("  Gas Used:", gasUsed);
            assertEq(recipient.balance, 0.1 ether, "Transfer failed");
            console2.log("");
        }

        // Test 3: Operation Execution with Merkle Proof (3 operations, execute middle one)
        console2.log("[Test 3] Operation Execution with Merkle Proof (from 3-operation tree)");
        {
            address[] memory recipients = new address[](3);
            recipients[0] = makeAddr("recipient3a");
            recipients[1] = makeAddr("recipient3b");
            recipients[2] = makeAddr("recipient3c");

            IExecutorTypes.Operation[] memory operations = new IExecutorTypes.Operation[](3);
            operations[0] = _createETHTransferOperation(recipients[0], 0.1 ether, 0);
            operations[1] = _createETHTransferOperation(recipients[1], 0.2 ether, 1);
            operations[2] = _createETHTransferOperation(recipients[2], 0.3 ether, 2);

            (bytes32 merkleRoot, bytes32[] memory leaves) = _buildMerkleTree(operations);
            _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

            // Execute middle operation (index 1) which requires proof
            bytes32[] memory proof = _getMerkleProof(leaves, 1);

            uint256 gasStart = gasleft();
            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[1], proof);
            uint256 gasUsed = gasStart - gasleft();

            console2.log("  Gas Used:", gasUsed);
            console2.log("  Proof Length:", proof.length);
            assertEq(recipients[1].balance, 0.2 ether, "Transfer failed");
            console2.log("");
        }

        // Test 4: Repeatable Operation Execution (first execution)
        console2.log("[Test 4] Repeatable Operation (first execution)");
        {
            address recipient = makeAddr("recipient4");
            IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.05 ether, 0);
            operation.isRepeatable = true;
            
            bytes32 merkleRoot = keccak256(abi.encode(operation));
            _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);
            bytes32[] memory proof = new bytes32[](0);

            uint256 gasStart = gasleft();
            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
            uint256 gasUsed = gasStart - gasleft();

            console2.log("  Gas Used (First):", gasUsed);

            // Second execution
            gasStart = gasleft();
            vm.prank(executor);
            ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operation, proof);
            gasUsed = gasStart - gasleft();

            console2.log("  Gas Used (Second):", gasUsed);
            assertEq(recipient.balance, 0.1 ether, "Repeatable execution failed");
            console2.log("");
        }

        // Test 5: Task Status Update
        console2.log("[Test 5] Task Status Update (ACTIVE -> CANCELLED)");
        {
            address recipient = makeAddr("recipient5");
            IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
            bytes32 merkleRoot = keccak256(abi.encode(operation));
            
            _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

            uint256 gasStart = gasleft();
            vm.prank(safeAddress);
            ExecutorFacet(diamondAddress).updateTaskStatus(merkleRoot, IExecutorTypes.TaskStatus.CANCELLED);
            uint256 gasUsed = gasStart - gasleft();

            console2.log("  Gas Used:", gasUsed);
            console2.log("");
        }

        // Test 6: Query Operations (view functions)
        console2.log("[Test 6] Query Operations (view functions)");
        {
            address recipient = makeAddr("recipient6");
            IExecutorTypes.Operation memory operation = _createETHTransferOperation(recipient, 0.1 ether, 0);
            bytes32 merkleRoot = keccak256(abi.encode(operation));
            
            _registerTask(safeAddress, diamondAddress, merkleRoot, executor, USDC);

            // getTaskInfo
            uint256 gasStart = gasleft();
            ExecutorFacet(diamondAddress).getTaskInfo(merkleRoot);
            uint256 gasUsed = gasStart - gasleft();
            console2.log("  getTaskInfo Gas:", gasUsed);

            // isOperationExecuted
            gasStart = gasleft();
            ExecutorFacet(diamondAddress).isOperationExecuted(merkleRoot, 0);
            gasUsed = gasStart - gasleft();
            console2.log("  isOperationExecuted Gas:", gasUsed);

            // getThyraRegistry
            gasStart = gasleft();
            ExecutorFacet(diamondAddress).getThyraRegistry();
            gasUsed = gasStart - gasleft();
            console2.log("  getThyraRegistry Gas:", gasUsed);
            console2.log("");
        }

        console2.log("========================================");
        console2.log("  BENCHMARK COMPLETED");
        console2.log("========================================\n");
    }

    /* ============================================ */
    /*           AAVE V3 INTEGRATION TEST           */
    /* ============================================ */

    /// @notice Test real Aave V3 workflow: deposit, set EMode, withdraw
    function testAaveV3RealWorkflow() external {
        uint256 depositAmount = 0.1 ether;
        uint8 eModeCategory = 1; // ETH category
        
        // 1. Deploy Safe + Diamond account
        (address safeAddress, address diamondAddress) = _deployMainAccount(owner1, owner2, 1, "aave-test");

        // 2. Configure Registry
        _configureRegistry(executor, WETH);

        // 3. Fund Safe with ETH and wrap to WETH
        vm.deal(safeAddress, 1 ether);
        _wrapETHToWETH(safeAddress, depositAmount);
        _approveToken(safeAddress, WETH, AAVE_POOL, type(uint256).max);

        // 4. Build Merkle tree with three operations
        IExecutorTypes.Operation[] memory operations = new IExecutorTypes.Operation[](3);
        
        // Operation 0: Aave deposit
        operations[0] = IExecutorTypes.Operation({
            target: AAVE_POOL,
            value: 0,
            callData: abi.encodeWithSignature(
                "supply(address,uint256,address,uint16)", WETH, depositAmount, safeAddress, uint16(0)
            ),
            callType: IExecutorTypes.CallType.CALL,
            operationId: 0,
            isRepeatable: false,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            maxGasPrice: uint128(1000 gwei),
            gasLimit: 500000,
            gasToken: address(0)
        });
        
        // Operation 1: Set EMode
        operations[1] = IExecutorTypes.Operation({
            target: AAVE_POOL,
            value: 0,
            callData: abi.encodeWithSignature("setUserEMode(uint8)", eModeCategory),
            callType: IExecutorTypes.CallType.CALL,
            operationId: 1,
            isRepeatable: false,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            maxGasPrice: uint128(1000 gwei),
            gasLimit: 300000,
            gasToken: address(0)
        });
        
        // Operation 2: Aave withdraw
        operations[2] = IExecutorTypes.Operation({
            target: AAVE_POOL,
            value: 0,
            callData: abi.encodeWithSignature(
                "withdraw(address,uint256,address)", WETH, type(uint256).max, safeAddress
            ),
            callType: IExecutorTypes.CallType.CALL,
            operationId: 2,
            isRepeatable: false,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            maxGasPrice: uint128(1000 gwei),
            gasLimit: 300000,
            gasToken: address(0)
        });
        
        // 5. Build Merkle tree
        (bytes32 merkleRoot, bytes32[] memory leaves) = _buildMerkleTree(operations);

        // 6. Register Task
        _registerTask(safeAddress, diamondAddress, merkleRoot, executor, WETH);

        // 7. Execute Operation 0: Deposit
        uint256 aWETHBalanceBefore = _getBalance(AWETH, safeAddress);
        bytes32[] memory proof0 = _getMerkleProof(leaves, 0);
        
        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[0], proof0);
        
        uint256 aWETHBalanceAfter = _getBalance(AWETH, safeAddress);
        assertGt(aWETHBalanceAfter, aWETHBalanceBefore, "aWETH balance should increase after deposit");
        console2.log("[OK] Deposited successfully, aWETH balance:", aWETHBalanceAfter);

        // 8. Execute Operation 1: Set EMode
        bytes32[] memory proof1 = _getMerkleProof(leaves, 1);
        
        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[1], proof1);
        console2.log("[OK] EMode set successfully");

        // 9. Execute Operation 2: Withdraw
        bytes32[] memory proof2 = _getMerkleProof(leaves, 2);
        uint256 wethBalanceBefore = _getBalance(WETH, safeAddress);
        
        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[2], proof2);
        
        uint256 wethBalanceAfter = _getBalance(WETH, safeAddress);
        uint256 aWETHBalanceFinal = _getBalance(AWETH, safeAddress);
        
        assertGt(wethBalanceAfter, wethBalanceBefore, "WETH balance should increase after withdrawal");
        assertEq(aWETHBalanceFinal, 0, "aWETH should be fully withdrawn");
        console2.log("[OK] Withdrawn successfully, WETH balance:", wethBalanceAfter);
        console2.log("[OK] Aave V3 workflow completed successfully!");
    }

}
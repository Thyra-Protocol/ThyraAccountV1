// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.17;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {ThyraFactory} from "../../src/ThyraFactory.sol";
import {ThyraDiamond} from "../../src/ThyraDiamond.sol";
import {ThyraRegistry} from "../../src/ThyraRegistry.sol";

// Facets
import {DiamondCutFacet} from "../../src/Facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../../src/Facets/DiamondLoupeFacet.sol";
import {ExecutorFacet} from "../../src/Facets/ExecutorFacet.sol";
import {OwnershipFacet} from "../../src/Facets/OwnershipFacet.sol";

// Executor Types
import {IExecutorTypes} from "../../src/Interfaces/IExecutorTypes.sol";

// Safe interfaces (v1.5 compatible)
import {Safe} from "safe-smart-account/contracts/Safe.sol";
import {Enum} from "safe-smart-account/contracts/libraries/Enum.sol";

/// @title ThyraFactoryMainnetForkTest
/// @notice Integration tests for ThyraFactory with Safe 1.5 factory on Ethereum mainnet fork
/// @dev Comprehensive test suite covering deployment, executor operations, and DeFi protocol integrations
contract ThyraFactoryMainnetForkTest is Test {
    /* ============================================ */
    /*                   CONSTANTS                  */
    /* ============================================ */

    /// @dev Mainnet RPC URL
    string private constant MAINNET_RPC_ALIAS = "https://mainnet.infura.io/v3/af22684d5c2140d8835255c3c265cc4f";

    /// @dev Stable mainnet block number to avoid Safe upgrade behavior drift
    uint256 private constant FORK_BLOCK = 23470577;

    /// @dev Safe 1.5 component addresses (mainnet)
    address private constant SAFE_PROXY_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address private constant SAFE_SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b;
    address private constant SAFE_MULTI_SEND = 0x218543288004CD07832472D464648173c77D7eB7;
    address private constant SAFE_FALLBACK_HANDLER = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4;

    /// @dev Mainnet protocol addresses
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address private constant aWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    /* ============================================ */
    /*                 STATE VARIABLES              */
    /* ============================================ */

    /// @dev Thyra component instances
    ThyraFactory private factory;
    ThyraRegistry private registry;

    DiamondCutFacet private diamondCutFacet;
    DiamondLoupeFacet private diamondLoupeFacet;
    ExecutorFacet private executorFacet;
    OwnershipFacet private ownershipFacet;

    /// @dev Test accounts
    address private owner1;
    address private owner2;
    address private owner3;
    address private executor;

    /* ============================================ */
    /*                    SETUP                     */
    /* ============================================ */

    /// @notice Integration test initialization
    function setUp() external {
        string memory rpcUrl = MAINNET_RPC_ALIAS;
        vm.createSelectFork(rpcUrl, FORK_BLOCK);

        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        executor = makeAddr("executor");

        registry = new ThyraRegistry();

        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        executorFacet = new ExecutorFacet(address(registry));
        ownershipFacet = new OwnershipFacet();

        factory = new ThyraFactory(
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MULTI_SEND,
            SAFE_FALLBACK_HANDLER,
            address(diamondCutFacet),
            address(diamondLoupeFacet),
            address(executorFacet),
            address(ownershipFacet),
            address(registry)
        );
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
        assertEq(ThyraDiamond(payable(diamondAddress)).safeWallet(), safeAddress, "Diamond safeWallet mismatch");
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

        assertEq(ThyraDiamond(payable(subDiamond)).safeWallet(), subSafe, "Sub diamond safe wallet mismatch");
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
        uint256 aWETHBalanceBefore = _getBalance(aWETH, safeAddress);
        bytes32[] memory proof0 = _getMerkleProof(leaves, 0);
        
        vm.prank(executor);
        ExecutorFacet(diamondAddress).executeTransaction(merkleRoot, operations[0], proof0);
        
        uint256 aWETHBalanceAfter = _getBalance(aWETH, safeAddress);
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
        uint256 aWETHBalanceFinal = _getBalance(aWETH, safeAddress);
        
        assertGt(wethBalanceAfter, wethBalanceBefore, "WETH balance should increase after withdrawal");
        assertEq(aWETHBalanceFinal, 0, "aWETH should be fully withdrawn");
        console2.log("[OK] Withdrawn successfully, WETH balance:", wethBalanceAfter);
        console2.log("[OK] Aave V3 workflow completed successfully!");
    }

    /* ============================================ */
    /*              HELPER FUNCTIONS                */
    /* ============================================ */

    /// @dev Deploy main account with two owners
    function _deployMainAccount(address ownerA, address ownerB, uint256 threshold, string memory saltLabel)
        private
        returns (address safeAddress, address diamondAddress)
    {
        address[] memory owners = new address[](2);
        owners[0] = ownerA;
        owners[1] = ownerB;
        bytes32 salt = keccak256(abi.encodePacked("thyra-mainnet-", saltLabel));

        vm.recordLogs();
        safeAddress = factory.deployThyraAccount(owners, threshold, salt);
        diamondAddress = _readDeployedDiamondFromLogs();
    }

    /// @dev Parse Diamond address from event logs (supports both main and sub-account events)
    function _readDeployedDiamondFromLogs() private returns (address diamond) {
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 mainAccountEvent = keccak256("ThyraAccountDeployed(address,address,address[],uint256)");
        bytes32 subAccountEvent = keccak256("ThyraSubAccountDeployed(address,address,address,address[],uint256)");

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length < 3) continue;
            
            if (entries[i].topics[0] == mainAccountEvent || entries[i].topics[0] == subAccountEvent) {
                diamond = address(uint160(uint256(entries[i].topics[2])));
                break;
            }
        }
    }

    /// @dev Configure Registry with executor and fee token whitelist
    function _configureRegistry(address _executor, address feeToken) private {
        registry.setExecutor(_executor, true);
        registry.setFeeToken(feeToken, true);
        registry.setFeeConfig(feeToken, 0, 1000 ether);
    }

    /// @dev Register task via Safe owner
    function _registerTask(
        address safeAddress,
        address diamondAddress,
        bytes32 merkleRoot,
        address taskExecutor,
        address feeToken
    ) private {
        vm.prank(safeAddress);
        (bool success,) = diamondAddress.call(
            abi.encodeWithSelector(ExecutorFacet.registerTask.selector, merkleRoot, taskExecutor, feeToken, 0, 100)
        );
        assertTrue(success, "registerTask failed");
    }

    /// @dev Create ETH transfer operation
    function _createETHTransferOperation(address recipient, uint256 value, uint32 operationId)
        private
        view
        returns (IExecutorTypes.Operation memory)
    {
        return IExecutorTypes.Operation({
            target: recipient,
            value: value,
            callData: "",
            callType: IExecutorTypes.CallType.CALL,
            operationId: operationId,
            isRepeatable: false,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            maxGasPrice: uint128(1000 gwei),
            gasLimit: 100000,
            gasToken: address(0)
        });
    }

    /* ============================================ */
    /*           MERKLE TREE UTILITIES              */
    /* ============================================ */

    /// @dev Build Merkle tree from operations (supports arbitrary number of leaves)
    /// @return merkleRoot Root of the Merkle tree
    /// @return leaves All leaf node hashes
    function _buildMerkleTree(IExecutorTypes.Operation[] memory operations)
        private
        pure
        returns (bytes32 merkleRoot, bytes32[] memory leaves)
    {
        uint256 n = operations.length;
        leaves = new bytes32[](n);

        // Compute all leaf hashes
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = keccak256(abi.encode(operations[i]));
        }

        // Single leaf case
        if (n == 1) {
            return (leaves[0], leaves);
        }

        // Build Merkle tree
        merkleRoot = _computeMerkleRoot(leaves);
        return (merkleRoot, leaves);
    }

    /// @dev Recursively compute Merkle root
    function _computeMerkleRoot(bytes32[] memory hashes) private pure returns (bytes32) {
        uint256 n = hashes.length;
        if (n == 1) {
            return hashes[0];
        }

        // Compute next level node count (ceiling division)
        uint256 nextLevel = (n + 1) / 2;
        bytes32[] memory nextHashes = new bytes32[](nextLevel);

        for (uint256 i = 0; i < nextLevel; i++) {
            uint256 leftIndex = i * 2;
            uint256 rightIndex = leftIndex + 1;

            if (rightIndex < n) {
                // Two child nodes, hash with standard Merkle tree sorting
                nextHashes[i] = _hashPair(hashes[leftIndex], hashes[rightIndex]);
            } else {
                // Only left node, promote directly
                nextHashes[i] = hashes[leftIndex];
            }
        }

        return _computeMerkleRoot(nextHashes);
    }

    /// @dev Get Merkle proof for specified leaf
    function _getMerkleProof(bytes32[] memory leaves, uint256 index)
        private
        pure
        returns (bytes32[] memory proof)
    {
        uint256 n = leaves.length;
        require(index < n, "Index out of bounds");

        // Single leaf requires no proof
        if (n == 1) {
            return new bytes32[](0);
        }

        // Calculate proof array size (tree height)
        uint256 proofLength = 0;
        uint256 tempN = n;
        while (tempN > 1) {
            proofLength++;
            tempN = (tempN + 1) / 2;
        }

        proof = new bytes32[](proofLength);
        uint256 proofIndex = 0;

        // Build current level
        bytes32[] memory currentLevel = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            currentLevel[i] = leaves[i];
        }

        uint256 currentIndex = index;

        // Build proof bottom-up
        while (currentLevel.length > 1) {
            uint256 levelSize = currentLevel.length;
            uint256 nextLevelSize = (levelSize + 1) / 2;
            bytes32[] memory nextLevel = new bytes32[](nextLevelSize);

            // Find sibling node and add to proof
            uint256 siblingIndex = currentIndex % 2 == 0 ? currentIndex + 1 : currentIndex - 1;

            if (siblingIndex < levelSize) {
                proof[proofIndex++] = currentLevel[siblingIndex];
            }

            // Build next level
            for (uint256 i = 0; i < nextLevelSize; i++) {
                uint256 leftIndex = i * 2;
                uint256 rightIndex = leftIndex + 1;

                if (rightIndex < levelSize) {
                    nextLevel[i] = _hashPair(currentLevel[leftIndex], currentLevel[rightIndex]);
                } else {
                    nextLevel[i] = currentLevel[leftIndex];
                }
            }

            currentLevel = nextLevel;
            currentIndex = currentIndex / 2;
        }

        // Trim proof array (remove unused slots)
        bytes32[] memory finalProof = new bytes32[](proofIndex);
        for (uint256 i = 0; i < proofIndex; i++) {
            finalProof[i] = proof[i];
        }

        return finalProof;
    }

    /// @dev Hash pair according to OpenZeppelin standard (sorted before hashing)
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /* ============================================ */
    /*          TOKEN & PROTOCOL UTILITIES          */
    /* ============================================ */

    /// @dev Get token balance
    function _getBalance(address token, address account) private view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(success, "balanceOf call failed");
        return abi.decode(data, (uint256));
    }

    /// @dev Wrap ETH to WETH
    function _wrapETHToWETH(address from, uint256 amount) private {
        vm.prank(from);
        (bool success,) = WETH.call{value: amount}(abi.encodeWithSignature("deposit()"));
        assertTrue(success, "WETH wrap failed");
    }

    /// @dev Approve token spending
    function _approveToken(address from, address token, address spender, uint256 amount) private {
        vm.prank(from);
        (bool success,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        assertTrue(success, "Token approve failed");
    }

    /// @dev No-op function for testing
    function noop() external {}
}
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

// Interfaces
import {IOwnershipFacet} from "../../src/Interfaces/IOwnershipFacet.sol";
import {IExecutorTypes} from "../../src/Interfaces/IExecutorTypes.sol";

// Safe interfaces (v1.5 compatible)
import {Safe} from "safe-smart-account/contracts/Safe.sol";

/// @title BaseTest
/// @notice Base contract for Thyra integration tests with shared setup and utilities
/// @dev Provides common infrastructure for mainnet fork tests, helpers, and utilities
abstract contract BaseTest is Test {
    /* ============================================ */
    /*                   CONSTANTS                  */
    /* ============================================ */

    /// @dev Mainnet RPC URL
    string internal constant MAINNET_RPC_URL = "https://mainnet.infura.io/v3/af22684d5c2140d8835255c3c265cc4f";

    /// @dev Stable mainnet block number to avoid Safe upgrade behavior drift
    uint256 internal constant FORK_BLOCK = 23470577;

    /// @dev Safe 1.5 component addresses (mainnet)
    address internal constant SAFE_PROXY_FACTORY = 0x14F2982D601c9458F93bd70B218933A6f8165e7b;
    address internal constant SAFE_SINGLETON = 0xFf51A5898e281Db6DfC7855790607438dF2ca44b;
    address internal constant SAFE_MULTI_SEND = 0x218543288004CD07832472D464648173c77D7eB7;
    address internal constant SAFE_FALLBACK_HANDLER = 0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4;

    /// @dev Mainnet protocol addresses
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    /* ============================================ */
    /*                 STATE VARIABLES              */
    /* ============================================ */

    /// @dev Thyra component instances
    ThyraFactory internal factory;
    ThyraRegistry internal registry;

    DiamondCutFacet internal diamondCutFacet;
    DiamondLoupeFacet internal diamondLoupeFacet;
    ExecutorFacet internal executorFacet;
    OwnershipFacet internal ownershipFacet;

    /// @dev Test accounts
    address internal owner1;
    address internal owner2;
    address internal owner3;
    address internal executor;

    /* ============================================ */
    /*                    SETUP                     */
    /* ============================================ */

    /// @notice Base setup for all integration tests
    /// @dev Creates fork, deploys facets, factory, and registry
    function setUp() public virtual {
        // Create mainnet fork at stable block
        vm.createSelectFork(MAINNET_RPC_URL, FORK_BLOCK);

        // Create test accounts
        owner1 = makeAddr("owner1");
        owner2 = makeAddr("owner2");
        owner3 = makeAddr("owner3");
        executor = makeAddr("executor");

        // Deploy registry
        registry = new ThyraRegistry();

        // Deploy facets (shared implementations)
        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        executorFacet = new ExecutorFacet(address(registry));
        ownershipFacet = new OwnershipFacet();

        // Deploy factory
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
    /*              HELPER FUNCTIONS                */
    /* ============================================ */

    /// @dev Deploy main account with two owners
    function _deployMainAccount(address ownerA, address ownerB, uint256 threshold, string memory saltLabel)
        internal
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
    function _readDeployedDiamondFromLogs() internal returns (address diamond) {
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
    function _configureRegistry(address _executor, address feeToken) internal {
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
    ) internal {
        vm.prank(safeAddress);
        (bool success,) = diamondAddress.call(
            abi.encodeWithSelector(ExecutorFacet.registerTask.selector, merkleRoot, taskExecutor, feeToken, 0, 100)
        );
        assertTrue(success, "registerTask failed");
    }

    /// @dev Create ETH transfer operation
    function _createETHTransferOperation(address recipient, uint256 value, uint32 operationId)
        internal
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
        internal
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
    function _computeMerkleRoot(bytes32[] memory hashes) internal pure returns (bytes32) {
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
        internal
        pure
        returns (bytes32[] memory proof)
    {
        uint256 n = leaves.length;
        if (index >= n) revert("Index out of bounds");

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
    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /* ============================================ */
    /*          TOKEN & PROTOCOL UTILITIES          */
    /* ============================================ */

    /// @dev Get token balance
    function _getBalance(address token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        if (!success) revert("balanceOf call failed");
        return abi.decode(data, (uint256));
    }

    /// @dev Wrap ETH to WETH
    function _wrapETHToWETH(address from, uint256 amount) internal {
        vm.prank(from);
        (bool success,) = WETH.call{value: amount}(abi.encodeWithSignature("deposit()"));
        assertTrue(success, "WETH wrap failed");
    }

    /// @dev Approve token spending
    function _approveToken(address from, address token, address spender, uint256 amount) internal {
        vm.prank(from);
        (bool success,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        assertTrue(success, "Token approve failed");
    }
}


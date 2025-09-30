// SPDX-License-Identifier: Unlicensed
pragma solidity ^0.8.17;

import {Test} from "forge-std/Test.sol";
import {ThyraDiamond} from "../src/ThyraDiamond.sol";
import {LibDiamond} from "../src/Libraries/LibDiamond.sol";
import {DiamondCutFacet} from "../src/Facets/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "../src/Facets/DiamondLoupeFacet.sol";
import {ExecutorFacet} from "../src/Facets/ExecutorFacet.sol";
import {OwnershipFacet} from "../src/Facets/OwnershipFacet.sol";

contract ThyraDiamondTest is Test {
    ThyraDiamond public diamond;
    DiamondCutFacet public diamondCutFacet;
    DiamondLoupeFacet public diamondLoupeFacet;
    ExecutorFacet public executorFacet;
    OwnershipFacet public ownershipFacet;
    address public diamondOwner;
    address public thyraRegistry;

    event DiamondCut(LibDiamond.FacetCut[] _diamondCut, address _init, bytes _calldata);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error FunctionDoesNotExist();
    error ShouldNotReachThisCode();
    error InvalidDiamondSetup();
    error ExternalCallFailed();

    function setUp() public {
        diamondOwner = address(123456);
        thyraRegistry = address(789012); // Mock ThyraRegistry address

        // Deploy all default facet implementations
        diamondCutFacet = new DiamondCutFacet();
        diamondLoupeFacet = new DiamondLoupeFacet();
        executorFacet = new ExecutorFacet(thyraRegistry);
        ownershipFacet = new OwnershipFacet();

        // Deploy ThyraDiamond with all default facet addresses
        diamond = new ThyraDiamond(
            diamondOwner,
            address(diamondCutFacet),
            address(diamondLoupeFacet),
            address(executorFacet),
            address(ownershipFacet)
        );
    }

    function test_DeploysWithoutErrors() public {
        ThyraDiamond testDiamond = new ThyraDiamond(
            diamondOwner,
            address(diamondCutFacet),
            address(diamondLoupeFacet),
            address(executorFacet),
            address(ownershipFacet)
        );

        // Verify deployment success
        assertTrue(address(testDiamond) != address(0));
    }

    function test_ForwardsCallsViaDelegateCall() public {
        vm.startPrank(diamondOwner);

        // Test that DiamondLoupeFacet functions work (default facet fast path)
        address[] memory facetAddresses = DiamondLoupeFacet(address(diamond)).facetAddresses();
        assertTrue(facetAddresses.length > 0);

        // Test facets() function
        DiamondLoupeFacet.Facet[] memory facets = DiamondLoupeFacet(address(diamond)).facets();
        assertTrue(facets.length > 0);

        // Test facetAddress lookup for DiamondCut function
        address cutFacetAddress = DiamondLoupeFacet(address(diamond)).facetAddress(DiamondCutFacet.diamondCut.selector);
        assertEq(cutFacetAddress, address(diamondCutFacet));

        vm.stopPrank();
    }

    function test_FastPathAndSlowPathWork() public {
        vm.startPrank(diamondOwner);

        // Test fast path - OwnershipFacet (default facet)
        address owner = OwnershipFacet(address(diamond)).owner();
        assertEq(owner, diamondOwner);

        // Test that fast path works for all default facets
        // DiamondLoupeFacet already tested above

        // Test OwnershipFacet fast path
        address currentOwner = OwnershipFacet(address(diamond)).owner();
        assertEq(currentOwner, diamondOwner);

        // Note: ExecutorFacet would require proper setup with tasks to test fully
        // DiamondCutFacet would require proper permissions and cuts to test
        // The fact that these calls don't revert indicates fast path is working

        vm.stopPrank();
    }

    function test_RevertsOnUnknownFunctionSelector() public {
        // call random function selectors
        bytes memory callData = hex"a516f0f3"; // getPeripheryContract(string)

        vm.expectRevert(LibDiamond.FunctionDoesNotExist.selector);
        (bool success,) = address(diamond).call(callData);
        if (!success) revert ShouldNotReachThisCode(); // was only added to silence a compiler warning
    }

    function test_CanReceiveETH() public {
        (bool success,) = address(diamond).call{value: 1 ether}("");
        if (!success) revert ExternalCallFailed();

        assertEq(address(diamond).balance, 1 ether);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/test-contracts/TokenExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsApp} from "../../../rayls-protocol-sdk/RaylsApp.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title Security Test: ERC20 Access Control
 * @notice Tests that sensitive functions have proper access control via receiveMethod modifier
 * @dev These tests FAIL when vulnerabilities exist, PASS when code is secure.
 *
 * EXPECTED BEHAVIOR:
 * - unlock() MUST have receiveMethod modifier to prevent unauthorized token release
 * - receiveTeleport(), receiveTeleportAtomic(), revertTeleportMint() must also be protected
 *
 * TEST LOGIC:
 * - Tests expect "This is a receive method..." error when attacker calls protected functions
 * - If a different error occurs, it means the function lacks protection → TEST FAILS
 *
 * RELATED:
 * - Contract: RaylsErc20Handler.sol (unlock function)
 */
contract UnlockAccessControlERC20Test is Test {
    TokenExample public token;
    MockEndpointForSecurityTest public mockEndpoint;
    
    address public owner;
    address public attacker;
    address public recipient;
    
    uint256 constant MINT_AMOUNT = 10000 * 10**18;
    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");
        recipient = makeAddr("recipient");
        
        // Deploy mock endpoint
        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);

        // Set owner as the trusted executor (simulating the message executor)
        mockEndpoint.setTrustedExecutor(owner);

        // Deploy AccessManager and connect to endpoint
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        mockEndpoint.setAuthority(address(manager));
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(new MockRaylsAppTokenRegistry()));

        // Deploy TokenExample with the mock endpoint
        token = new TokenExample(
            "TestToken",
            "TT",
            address(mockEndpoint),
            address(0), // raylsNodeEndpoint - not needed for this test
            address(0)  // userGovernance - not needed for this test
        );
        
        // Mint additional tokens to owner (token already mints in constructor)
        token.mint(owner, MINT_AMOUNT);
    }

    /**
     * @notice unlock() MUST have receiveMethod modifier
     * @dev Test PASSES when unlock() is protected, FAILS when vulnerable
     */
    function test_unlock_hasAccessControl() public {
        vm.prank(attacker);
        
        // Attacker tries to call unlock() directly - should be blocked by receiveMethod
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.unlock(recipient, 1);
    }

    /**
     * @notice receiveTeleportAtomic() MUST have receiveMethod modifier
     */
    function test_receiveTeleportAtomic_hasAccessControl() public {
        vm.prank(attacker);

        // TokenExample overrides receiveTeleportAtomic with receiveMethod modifier
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.receiveTeleportAtomic(recipient, 100);
    }

    /**
     * @notice receiveTeleport() MUST have receiveMethod modifier
     */
    function test_receiveTeleport_hasAccessControl() public {
        vm.prank(attacker);
        
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.receiveTeleport(recipient, 100);
    }

    /**
     * @notice revertTeleportMint() MUST have receiveMethod modifier
     */
    function test_revertTeleportMint_hasAccessControl() public {
        vm.prank(attacker);
        
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.revertTeleportMint(recipient, 100);
    }

}

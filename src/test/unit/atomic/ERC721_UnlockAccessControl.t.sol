// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/test-contracts/Erc721Example.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsApp} from "../../../rayls-protocol-sdk/RaylsApp.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Security Test: ERC721 Access Control
 * @notice Tests that sensitive functions have proper access control via receiveMethod modifier
 * @dev These tests FAIL when vulnerabilities exist, PASS when code is secure.
 *
 * EXPECTED BEHAVIOR:
 * - unlock() MUST have receiveMethod modifier to prevent unauthorized token release
 * - receiveTeleport() MUST have receiveMethod modifier to prevent unauthorized minting
 * - receiveTeleportAtomic() MUST have receiveMethod modifier to prevent unauthorized minting
 * - revertTeleportMint(), revertTeleportBurn() must also be protected
 *
 * RELATED:
 * - Contract: RaylsErc721Handler.sol
 */
contract UnlockAccessControlERC721Test is Test, IERC721Receiver {
    RaylsErc721Example public token;
    MockEndpointForSecurityTest public mockEndpoint;
    
    address public owner;
    address public attacker;
    address public recipient;
    
    uint256 constant TOKEN_ID = 1000;
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

        // Deploy ERC721 token with the mock endpoint
        token = new RaylsErc721Example(
            "https://example.com/",
            "TestNFT",
            "TNFT",
            address(mockEndpoint),
            address(0), // raylsNodeEndpoint - not needed for this test
            address(0)  // userGovernance - not needed for this test
        );
    }

    /**
     * @notice unlock() MUST have receiveMethod modifier
     */
    function test_unlock_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.unlock(recipient, TOKEN_ID);
    }

    /**
     * @notice receiveTeleport() MUST have receiveMethod modifier
     */
    function test_receiveTeleport_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.receiveTeleport(attacker, TOKEN_ID);
    }

    /**
     * @notice receiveTeleportAtomic() MUST have receiveMethod modifier
     */
    function test_receiveTeleportAtomic_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.receiveTeleportAtomic(attacker, TOKEN_ID);
    }

    /**
     * @notice revertTeleportMint() MUST have receiveMethod modifier
     */
    function test_revertTeleportMint_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.revertTeleportMint(recipient, TOKEN_ID);
    }

    /**
     * @notice revertTeleportBurn() MUST have receiveMethod modifier
     */
    function test_revertTeleportBurn_hasAccessControl() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token.revertTeleportBurn(recipient, TOKEN_ID);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

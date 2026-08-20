// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../rayls-protocol/test-contracts/EnygmaTokenExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {RaylsEnygmaHandler} from "../../../rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title MockEnygmaPNEvents
 * @notice Minimal mock that accepts all IEnygmaPNEvents calls without reverting
 */
contract MockEnygmaPNEvents {
    fallback() external {}
}

/**
 * @title Unit Test: RaylsEnygmaHandler Zero Amount Validation
 * @notice Tests that mint, burn, depositToDvp, and callWithdrawFromDvp
 *         revert when called with zero amounts.
 */
contract RaylsEnygmaHandlerZeroAmountTest is Test {
    EnygmaTokenExample public token;
    MockEndpointForSecurityTest public mockEndpoint;
    MockEnygmaPNEvents public mockPNEvents;

    address public owner;
    address public user;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_ID = 99999;
    uint256 constant MINT_AMOUNT = 1000 ether;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_ID);
        mockEndpoint.setTrustedExecutor(owner);

        // Deploy AccessManager and connect to endpoint
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        mockEndpoint.setAuthority(address(manager));
        MockRaylsAppTokenRegistry registry = new MockRaylsAppTokenRegistry();
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));

        // Deploy mock PN events and register it on the mock endpoint
        mockPNEvents = new MockEnygmaPNEvents();
        mockEndpoint.registerResourceId(
            Constants.RESOURCE_ID_ENYGMA_PN_EVENTS,
            address(mockPNEvents)
        );

        token = new EnygmaTokenExample(
            "TestEnygma",
            "TENYG",
            address(mockEndpoint)
        );

        // Approve the token at the hub so hub-gated paths (depositToDvp / callWithdrawFromDvp)
        // pass the whenHubActive guard and actually reach their zero-amount validation.
        vm.prank(address(registry));
        token.setResourceId(bytes32(uint256(1)));
    }

    // ========== mint() zero amount ==========

    function test_mint_zeroAmount_reverts() public {
        vm.expectRevert(RaylsEnygmaHandler.RaylsEnygmaHandler__ZeroAmount.selector);
        token.mint(user, 0);
    }

    function test_mint_validAmount_succeeds() public {
        token.mint(user, MINT_AMOUNT);
        assertEq(token.balanceOf(user), MINT_AMOUNT);
    }

    function test_mint_oneWei_succeeds() public {
        token.mint(user, 1);
        assertEq(token.balanceOf(user), 1);
    }

    // ========== burn() zero amount ==========

    function test_burn_zeroAmount_reverts() public {
        token.mint(user, MINT_AMOUNT);
        vm.expectRevert(RaylsEnygmaHandler.RaylsEnygmaHandler__ZeroAmount.selector);
        token.burn(user, 0);
    }

    function test_burn_validAmount_succeeds() public {
        token.mint(user, MINT_AMOUNT);
        token.burn(user, MINT_AMOUNT);
        assertEq(token.balanceOf(user), 0);
    }

    // ========== depositToDvp() zero amount allowed ==========

    function test_depositToDvp_zeroAmount_succeeds() public {
        vm.prank(user);
        token.depositToDvp(0);
    }

    // ========== callWithdrawFromDvp() zero amount reverts ==========

    function test_callWithdrawFromDvp_zeroAmount_reverts() public {
        vm.prank(user);
        vm.expectRevert(RaylsEnygmaHandler.RaylsEnygmaHandler__ZeroAmount.selector);
        token.callWithdrawFromDvp(0);
    }

    // ========== decimals() returns correct value ==========

    function test_decimals_returns18() public view {
        assertEq(token.decimals(), 18);
    }

    // ========== invalid decimals at construction ==========

    function test_constructor_invalidDecimals_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RaylsEnygmaHandler.RaylsEnygmaHandler__InvalidDecimals.selector, uint8(78)));
        new EnygmaTokenExample78Decimals(
            "TestEnygma",
            "TENYG",
            address(mockEndpoint)
        );
    }
}

/// @dev Helper contract that tries to deploy with 78 decimals
contract EnygmaTokenExample78Decimals is RaylsEnygmaHandler {
    constructor(string memory _name, string memory _symbol, address _endpoint)
        RaylsEnygmaHandler(_name, _symbol, _endpoint, msg.sender, 78, false) {}
}

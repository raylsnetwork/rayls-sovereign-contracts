// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TokenRegistryV1} from "../../../privateHub/TokenRegistry/TokenRegistryV1.sol";
import {TokenStructs} from "../../../privateHub/TokenRegistry/libraries/TokenStructs.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import "../mocks/MockEndpointForSecurityTest.sol";

// ─── Mock authority ───────────────────────────────────────────────────────────

contract MockAuthority_TR {
    mapping(address => bool) private _allowed;

    function allow(address who) external { _allowed[who] = true; }
    function deny(address who) external { _allowed[who] = false; }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32, bool) {
        return (_allowed[caller], 0, false);
    }
}

/**
 * @title TokenRegistryV1 Governance Access Tests
 * @notice Verifies that all `restricted` governance functions are properly gated and
 *         that `receiveMethod`-gated functions remain protected independently.
 */
contract TokenRegistryV1GovernanceAccessTest is Test {
    TokenRegistryV1 public registry;
    MockAuthority_TR public auth;
    MockEndpointForSecurityTest public mockEndpoint;

    address public admin;
    address public attacker;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant HUB_ID   = 99999;

    function setUp() public {
        admin    = makeAddr("admin");
        attacker = makeAddr("attacker");
        auth     = new MockAuthority_TR();
        auth.allow(address(this));

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, HUB_ID);
        mockEndpoint.setTrustedExecutor(admin);

        // TokenRegistryV1 has no constructor disabling initializers
        registry = new TokenRegistryV1();
        registry.initialize(address(mockEndpoint), address(auth));
    }

    // ─── authority ───────────────────────────────────────────────────────────

    function test_authority_isSet() public view {
        assertEq(registry.authority(), address(auth));
    }

    // ─── configureModules (restricted) ───────────────────────────────────────

    function test_configureModules_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.configureModules(makeAddr("c"), makeAddr("f"), makeAddr("e"));
    }

    function test_configureModules_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.configureModules(makeAddr("c"), makeAddr("f"), makeAddr("e"));
    }

    function test_configureModules_allowed_passesAuthCheck() public {
        // Will revert on zero-address require, not on access control
        try registry.configureModules(address(0), makeAddr("f"), makeAddr("e")) {}
        catch (bytes memory reason) {
            // Must NOT be an Unauthorized error
            assertTrue(
                keccak256(reason) != keccak256(abi.encodeWithSelector(
                    RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)
                )),
                "Must not fail on access control"
            );
        }
    }

    // ─── setTokenCore (restricted) ───────────────────────────────────────────

    function test_setTokenCore_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.setTokenCore(makeAddr("c"));
    }

    function test_setTokenCore_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.setTokenCore(makeAddr("c"));
    }

    // ─── setTokenFreezeManager (restricted) ──────────────────────────────────

    function test_setTokenFreezeManager_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.setTokenFreezeManager(makeAddr("f"));
    }

    // ─── setEnygmaTokenManager (restricted) ──────────────────────────────────

    function test_setEnygmaTokenManager_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.setEnygmaTokenManager(makeAddr("e"));
    }

    // ─── updateStatus (restricted) ───────────────────────────────────────────

    function test_updateStatus_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.updateStatus(bytes32(0), TokenStructs.TokenStatus.ACTIVE);
    }

    function test_updateStatus_attacker_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        registry.updateStatus(bytes32(0), TokenStructs.TokenStatus.ACTIVE);
    }

    // ─── freezeToken (restricted) ────────────────────────────────────────────

    function test_freezeToken_denied_reverts() public {
        auth.deny(address(this));
        uint256[] memory chains = new uint256[](1);
        chains[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.freezeToken(bytes32(0), chains);
    }

    // ─── unfreezeToken (restricted) ──────────────────────────────────────────

    function test_unfreezeToken_denied_reverts() public {
        auth.deny(address(this));
        uint256[] memory chains = new uint256[](1);
        chains[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.unfreezeToken(bytes32(0), chains);
    }

    // ─── setEnygmaFactory (restricted) ───────────────────────────────────────

    function test_setEnygmaFactory_denied_reverts() public {
        auth.deny(address(this));
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, address(this)));
        registry.setEnygmaFactory(makeAddr("fac"));
    }

    // ─── addToken (receiveMethod — unchanged) ─────────────────────────────────

    function test_addToken_attacker_revertsOnReceiveMethod() public {
        vm.prank(attacker);
        vm.expectRevert(); // RaylsAppV1__UnauthorizedExecutor
        registry.addToken(_buildTokenData());
    }

    // ─── contractVersion ─────────────────────────────────────────────────────

    function test_contractVersion_returns1() public view {
        assertEq(registry.contractVersion(), 1);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _buildTokenData() internal pure returns (SharedObjects.TokenRegistrationData memory) {
        return SharedObjects.TokenRegistrationData({
            name: "T", symbol: "T", uri: "",
            totalSupply: abi.encode(0),
            issuerChainId: 1,
            pnRegistryAddress: address(0xBEEF),
            bytecode: hex"00",
            initializerParams: hex"00",
            isFungible: true,
            ercStandard: SharedObjects.ErcStandard.ERC20,
            isCustom: false,
            tokenAddress: address(0x1234)
        });
    }
}

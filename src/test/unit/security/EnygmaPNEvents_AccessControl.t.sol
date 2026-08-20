// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {EnygmaPNEvents} from "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaPNEvents.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

// ─── Minimal endpoint stub ──────────────────────────────────────────────────
// Only needs getChainId() for the validateTransfer modifier.
contract MockEndpointForEnygma {
    function getChainId() external pure returns (uint256) { return 1; }
    function authority() external pure returns (address) { return address(0); }
}

contract MockParticipantValidator {
    function validateParticipantStatus(uint256) external pure {}
}

contract MockTokenValidator {
    function validateTokenForParticipant(bytes32, uint256) external pure {}
}

/**
 * @title Security Test: EnygmaPNEvents Access Control (AUTH-V3)
 * @notice Verifies that all event-emitting functions are gated by AUTH-V3 `restricted`.
 *
 * After the AUTH-V3 migration:
 *   - `onlyAuthorized` (endpoint.authorizedAddresses check) is replaced with `restricted`.
 *   - Only holders of ENDPOINT_SENDER_ID (or ADMIN) may call these functions.
 *   - Unauthorized callers revert with RaylsAccessManaged__Unauthorized.
 */
contract EnygmaPNEventsAccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    EnygmaPNEvents public pnEvents;
    MockEndpointForEnygma public mockEndpoint;

    uint64 public ENDPOINT_SENDER_ID;

    address public admin;
    address public authorized; // holds ENDPOINT_SENDER_ID
    address public attacker;

    bytes32 constant RESOURCE_ID = bytes32(uint256(1));

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin      = address(this);
        authorized = makeAddr("authorized");
        attacker   = makeAddr("attacker");

        // Deploy manager proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Deploy stubs
        mockEndpoint = new MockEndpointForEnygma();
        MockParticipantValidator pv = new MockParticipantValidator();
        MockTokenValidator tv = new MockTokenValidator();

        // Deploy EnygmaPNEvents with manager as authority
        pnEvents = new EnygmaPNEvents(address(mockEndpoint), address(pv), address(tv), address(manager));

        // Register ENDPOINT_SENDER role and grant it to `authorized`
        ENDPOINT_SENDER_ID = manager.registerRole("ENDPOINT_SENDER");
        manager.grantRole(ENDPOINT_SENDER_ID, authorized, 0);

        // Map all restricted selectors on pnEvents to ENDPOINT_SENDER_ID
        bytes4[] memory selectors = new bytes4[](23);
        selectors[0]  = EnygmaPNEvents.setParticipantValidator.selector;
        selectors[1]  = EnygmaPNEvents.setTokenValidator.selector;
        selectors[2]  = EnygmaPNEvents.mint.selector;
        selectors[3]  = EnygmaPNEvents.burn.selector;
        selectors[4]  = bytes4(keccak256("creation(bytes32,uint256)"));
        selectors[5]  = EnygmaPNEvents.sendTransferPNH.selector;
        selectors[6]  = EnygmaPNEvents.revertMint.selector;
        selectors[7]  = EnygmaPNEvents.cancelSwap.selector;
        selectors[8]  = EnygmaPNEvents.depositToDvp.selector;
        selectors[9]  = EnygmaPNEvents.withdrawFromDvp.selector;
        selectors[10] = EnygmaPNEvents.swapWithDvpForERC721.selector;
        selectors[11] = EnygmaPNEvents.dvp721Creation.selector;
        selectors[12] = EnygmaPNEvents.dvp721Mint.selector;
        selectors[13] = EnygmaPNEvents.dvp721Burn.selector;
        selectors[14] = EnygmaPNEvents.dvp721DepositIntoDvp.selector;
        selectors[15] = EnygmaPNEvents.dvp721SwapForEnygma.selector;
        selectors[16] = EnygmaPNEvents.dvp721WithdrawFromDvp.selector;
        selectors[17] = EnygmaPNEvents.dvp721SwapCompleted.selector;
        selectors[18] = EnygmaPNEvents.dvp1155Creation.selector;
        selectors[19] = EnygmaPNEvents.dvp1155Mint.selector;
        selectors[20] = EnygmaPNEvents.dvp1155Burn.selector;
        selectors[21] = EnygmaPNEvents.dvp1155DepositIntoDvp.selector;
        selectors[22] = EnygmaPNEvents.dvp1155SwapForEnygma.selector;
        manager.addFunctionAllowedRoles(address(pnEvents), selectors, _singleRole(ENDPOINT_SENDER_ID));

        // Map remaining selectors (those not already covered above)
        bytes4[] memory selectors2 = new bytes4[](3);
        selectors2[0] = EnygmaPNEvents.swapWithDvpForERC1155.selector;
        selectors2[1] = EnygmaPNEvents.dvp1155WithdrawFromDvp.selector;
        selectors2[2] = EnygmaPNEvents.dvp1155SwapCompleted.selector;
        manager.addFunctionAllowedRoles(address(pnEvents), selectors2, _singleRole(ENDPOINT_SENDER_ID));
    }

    // ── helpers ────────────────────────────────────────────────────────────────

    function _expectUnauthorized() internal {
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  NEGATIVE TESTS — attacker cannot call any restricted function
    // ══════════════════════════════════════════════════════════════════════════

    function test_cancelSwap_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.cancelSwap(bytes32(0), 0, bytes32(0), 0, 0, SharedObjects.ErcStandard.ERC20, bytes32(0), 0, 0, SharedObjects.ErcStandard.ERC20);
    }

    function test_depositToDvp_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.depositToDvp(RESOURCE_ID, 100, attacker, bytes32(0));
    }

    function test_withdrawFromDvp_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.withdrawFromDvp(RESOURCE_ID, 100, attacker, bytes32(0));
    }

    function test_swapWithDvpForERC721_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.swapWithDvpForERC721(RESOURCE_ID, 1, bytes32(0), 100, attacker, 1, bytes32(0), 0);
    }

    function test_dvp721Creation_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721Creation(RESOURCE_ID);
    }

    function test_dvp721Mint_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721Mint(RESOURCE_ID, 1);
    }

    function test_dvp721Burn_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721Burn(RESOURCE_ID, 1);
    }

    function test_dvp721DepositIntoDvp_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721DepositIntoDvp(RESOURCE_ID, 1, attacker);
    }

    function test_dvp721SwapForEnygma_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721SwapForEnygma(RESOURCE_ID, 1, 100, bytes32(0), attacker, 1, bytes32(0), 0);
    }

    function test_dvp721WithdrawFromDvp_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721WithdrawFromDvp(RESOURCE_ID, 1, attacker);
    }

    function test_dvp721SwapCompleted_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp721SwapCompleted(RESOURCE_ID, 1, 1, attacker);
    }

    function test_dvp1155Creation_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155Creation(RESOURCE_ID);
    }

    function test_dvp1155Mint_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155Mint(RESOURCE_ID, 1, 100, "");
    }

    function test_dvp1155Burn_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155Burn(RESOURCE_ID, attacker, 1, 100);
    }

    function test_dvp1155DepositIntoDvp_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155DepositIntoDvp(RESOURCE_ID, 1, attacker, 100, "");
    }

    function test_dvp1155SwapForEnygma_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155SwapForEnygma(RESOURCE_ID, 1, 100, "", 50, bytes32(0), attacker, 1, bytes32(0), 0);
    }

    function test_swapWithDvpForERC1155_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.swapWithDvpForERC1155(RESOURCE_ID, 1, bytes32(0), 1, 100, attacker, 1, bytes32(0), 0);
    }

    function test_dvp1155WithdrawFromDvp_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155WithdrawFromDvp(RESOURCE_ID, 1, 100, "", attacker);
    }

    function test_dvp1155SwapCompleted_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.dvp1155SwapCompleted(RESOURCE_ID, 1, 1, attacker);
    }

    function test_mint_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.mint(RESOURCE_ID, attacker, 100);
    }

    function test_burn_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.burn(RESOURCE_ID, attacker, 100);
    }

    function test_creation_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.creation(RESOURCE_ID, 1000);
    }

    function test_revertMint_attackerReverts() public {
        vm.prank(attacker); _expectUnauthorized();
        pnEvents.revertMint(RESOURCE_ID, 100, attacker, "reason");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  POSITIVE TESTS — role holder can call all restricted functions
    // ══════════════════════════════════════════════════════════════════════════

    function test_depositToDvp_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.depositToDvp(RESOURCE_ID, 100, authorized, bytes32(0));
    }

    function test_withdrawFromDvp_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.withdrawFromDvp(RESOURCE_ID, 100, authorized, bytes32(0));
    }

    function test_dvp721Creation_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.dvp721Creation(RESOURCE_ID);
    }

    function test_dvp721Mint_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.dvp721Mint(RESOURCE_ID, 1);
    }

    function test_dvp1155Creation_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.dvp1155Creation(RESOURCE_ID);
    }

    function test_dvp1155Mint_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.dvp1155Mint(RESOURCE_ID, 1, 100, "");
    }

    function test_mint_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.mint(RESOURCE_ID, authorized, 100);
    }

    function test_burn_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.burn(RESOURCE_ID, authorized, 100);
    }

    function test_creation_authorizedSucceeds() public {
        vm.prank(authorized);
        pnEvents.creation(RESOURCE_ID, 1000);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  ADMIN BYPASS — ADMIN always passes regardless of selector mapping
    // ══════════════════════════════════════════════════════════════════════════

    function test_admin_canAlwaysCall() public {
        // admin = address(this), holds ADMIN
        pnEvents.mint(RESOURCE_ID, authorized, 100);
        pnEvents.dvp721Creation(RESOURCE_ID);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  REVOCATION — revoking role immediately blocks caller
    // ══════════════════════════════════════════════════════════════════════════

    function test_revokeRole_blocksSubsequentCalls() public {
        vm.prank(authorized);
        pnEvents.mint(RESOURCE_ID, authorized, 1);

        manager.revokeRole(ENDPOINT_SENDER_ID, authorized);

        vm.prank(authorized);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, authorized)
        );
        pnEvents.mint(RESOURCE_ID, authorized, 1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  initialize() idempotency guard (unchanged behaviour)
    // ══════════════════════════════════════════════════════════════════════════

    function test_initialize_cannotBeCalledTwice() public {
        pnEvents.initialize();
        vm.expectRevert("Already initialized");
        pnEvents.initialize();
    }

    function test_initialize_attackerCannotReinitialize() public {
        pnEvents.initialize();
        vm.prank(attacker);
        vm.expectRevert("Already initialized");
        pnEvents.initialize();
    }
}

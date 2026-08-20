// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {DvpErc721PNH} from "../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc721PNH.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/// @notice Access-control tests for `DvpErc721PNH.mint`, `burn`, and
///         `UpdateInfosAfterDvpWithdraw`. Verifies non-RELAYER callers are
///         rejected and that a RELAYER-role caller succeeds.
contract DvpErc721PNH_AccessControl is Test {
    address internal admin;
    address internal relayer;
    address internal victim;
    address internal attacker;

    RaylsAccessManagerV1 internal manager;
    DvpErc721PNH internal token;

    uint64 internal relayerRoleId;

    function setUp() public {
        admin    = address(this);
        relayer  = makeAddr("RELAYER_EOA");
        victim   = makeAddr("VICTIM");
        attacker = makeAddr("ATTACKER");

        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory init = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), init)));

        // RELAYER role must exist before the token constructor self-registers
        // its selectors against it (lookup is by name).
        relayerRoleId = manager.registerRole("RELAYER");
        manager.grantRole(relayerRoleId, relayer, 0);

        token = new DvpErc721PNH(
            "https://example.com/{id}",
            "DVP NFT",
            "DNFT",
            address(manager),
            8
        );
    }

    /// @dev Zero-length `Dvp721ExtraData` array for calls that require the
    ///      parameter but exercise no extras.
    function _emptyExtras() internal pure returns (SharedObjects.Dvp721ExtraData[] memory) {
        return new SharedObjects.Dvp721ExtraData[](0);
    }

    /// @dev Single-element `Dvp721ExtraData` array with `isPublic = true`.
    function _oneExtra(string memory key, string memory value)
        internal pure returns (SharedObjects.Dvp721ExtraData[] memory arr)
    {
        arr = new SharedObjects.Dvp721ExtraData[](1);
        arr[0] = SharedObjects.Dvp721ExtraData(key, value, true);
    }

    // ─── baseline ──────────────────────────────────────────────────────────

    function test_baseline_token_authority_wired() public view {
        assertEq(token.authority(), address(manager));
    }

    function test_baseline_relayer_holds_role() public view {
        (bool isMember,) = manager.hasRole(relayerRoleId, relayer);
        assertTrue(isMember);
    }

    function test_baseline_attacker_has_no_role() public view {
        (bool isMember,) = manager.hasRole(relayerRoleId, attacker);
        assertFalse(isMember);
    }

    // ─── unauthorized callers must revert ──────────────────────────────────

    function test_unauthorized_caller_cannot_mint() public {
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        token.mint(attacker, 0xCAFE, 1, _emptyExtras());
    }

    function test_unauthorized_caller_cannot_burn() public {
        uint256 nftId = 0xBEEF;
        vm.prank(relayer);
        token.mint(victim, nftId, 1, _emptyExtras());
        assertEq(token.ownerOf(nftId), victim);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        token.burn(nftId);
    }

    function test_unauthorized_caller_cannot_UpdateInfosAfterDvpWithdraw() public {
        uint256 nftId = 0xDEAD;

        vm.prank(relayer);
        token.mint(victim, nftId, 1, _emptyExtras());
        assertEq(token.ownerOf(nftId), victim);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        token.UpdateInfosAfterDvpWithdraw(nftId, 1, _emptyExtras(), attacker);
    }

    // ─── relayer-role caller succeeds ──────────────────────────────────────

    function test_relayer_can_mint() public {
        uint256 nftId = 1;
        vm.prank(relayer);
        token.mint(victim, nftId, 1, _emptyExtras());
        assertEq(token.ownerOf(nftId), victim);
    }

    function test_relayer_can_burn() public {
        uint256 nftId = 2;
        vm.startPrank(relayer);
        token.mint(victim, nftId, 1, _emptyExtras());
        token.burn(nftId);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, nftId)
        );
        token.ownerOf(nftId);
    }

    function test_relayer_can_UpdateInfosAfterDvpWithdraw() public {
        uint256 nftId = 3;
        address newOwner = makeAddr("NEW_OWNER");

        vm.startPrank(relayer);
        token.mint(victim, nftId, 1, _emptyExtras());
        token.UpdateInfosAfterDvpWithdraw(nftId, 7, _emptyExtras(), newOwner);
        vm.stopPrank();

        assertEq(token.ownerOf(nftId), newOwner);
        assertEq(token.getChainIdByTokenId(nftId), 7);
    }

    // ─── data lifecycle ────────────────────────────────────────────────────

    /// @notice `burn` must clear `nftExtraData[id]`; otherwise a future re-mint
    ///         of the same id inherits stale entries.
    function test_burn_clears_extra_data() public {
        uint256 nftId = 0xC1EA0;

        vm.startPrank(relayer);
        token.mint(victim, nftId, 1, _oneExtra("color", "red"));

        SharedObjects.Dvp721ExtraData[] memory beforeBurn = token.getNftExtradaData(nftId);
        assertEq(beforeBurn.length, 1);
        assertEq(beforeBurn[0].value, "red");

        token.burn(nftId);
        vm.stopPrank();

        SharedObjects.Dvp721ExtraData[] memory afterBurn = token.getNftExtradaData(nftId);
        assertEq(afterBurn.length, 0, "extra data must be cleared on burn");

        // Re-minting the same id with no extras must not surface stale entries.
        vm.prank(relayer);
        token.mint(victim, nftId, 1, _emptyExtras());

        SharedObjects.Dvp721ExtraData[] memory afterRemint = token.getNftExtradaData(nftId);
        assertEq(afterRemint.length, 0, "re-mint must not inherit stale extra data");
    }
}

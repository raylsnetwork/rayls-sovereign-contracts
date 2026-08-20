// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DvpErc1155PNH} from "../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc1155PNH.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/// @notice Access-control tests for `DvpErc1155PNH.mint`, `burn`, and
///         `UpdateInfosAfterDvpWithdraw`. Verifies non-RELAYER callers are
///         rejected and that a RELAYER-role caller succeeds.
contract DvpErc1155PNH_AccessControl is Test {
    address internal admin;
    address internal relayer;
    address internal victim;
    address internal attacker;

    RaylsAccessManagerV1 internal manager;
    DvpErc1155PNH internal token;

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

        token = new DvpErc1155PNH(
            "https://example.com/{id}",
            "DVP 1155",
            address(manager),
            8
        );
    }

    /// @dev Zero-length `Dvp1155ExtraData` array for calls that require the
    ///      parameter but exercise no extras.
    function _emptyExtras() internal pure returns (SharedObjects.Dvp1155ExtraData[] memory) {
        return new SharedObjects.Dvp1155ExtraData[](0);
    }

    /// @dev Single-element `Dvp1155ExtraData` array with `isPublic = true`.
    function _oneExtra(string memory key, string memory value)
        internal pure returns (SharedObjects.Dvp1155ExtraData[] memory arr)
    {
        arr = new SharedObjects.Dvp1155ExtraData[](1);
        arr[0] = SharedObjects.Dvp1155ExtraData(key, value, true);
    }

    /// @dev Single-element id array. Matches the batch shape required by
    ///      `UpdateInfosAfterDvpWithdraw` while keeping tests focused on one id.
    function _ids(uint256 id) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = id;
    }

    /// @dev Single-element amount array, parallel to {_ids}.
    function _amounts(uint256 amount) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = amount;
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
        token.mint(attacker, 0xCAFE, 1000, "", 1, _emptyExtras());
    }

    function test_unauthorized_caller_cannot_burn() public {
        uint256 tokenId = 0xBEEF;
        uint256 amount  = 100;

        vm.prank(relayer);
        token.mint(victim, tokenId, amount, "", 1, _emptyExtras());
        assertEq(token.balanceOf(victim, tokenId), amount);

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        token.burn(victim, tokenId, amount);
    }

    function test_unauthorized_caller_cannot_UpdateInfosAfterDvpWithdraw() public {
        uint256 tokenId = 0xDEAD;

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        token.UpdateInfosAfterDvpWithdraw(
            _ids(tokenId),
            _amounts(0),
            42,
            _emptyExtras(),
            attacker
        );
    }

    // ─── relayer-role caller succeeds ──────────────────────────────────────

    function test_relayer_can_mint() public {
        uint256 tokenId = 1;
        uint256 amount  = 500;

        vm.prank(relayer);
        token.mint(victim, tokenId, amount, "", 1, _emptyExtras());

        assertEq(token.balanceOf(victim, tokenId), amount);
    }

    function test_relayer_can_burn() public {
        uint256 tokenId = 2;
        uint256 amount  = 300;

        vm.startPrank(relayer);
        token.mint(victim, tokenId, amount, "", 1, _emptyExtras());
        token.burn(victim, tokenId, amount);
        vm.stopPrank();

        assertEq(token.balanceOf(victim, tokenId), 0);
    }

    function test_relayer_can_UpdateInfosAfterDvpWithdraw() public {
        uint256 tokenId = 3;
        address newOwner = makeAddr("NEW_OWNER");

        // _amounts of 0 keeps `_update` a no-op while still exercising the
        // mapping/extra-data writes that the function performs.
        vm.prank(relayer);
        token.UpdateInfosAfterDvpWithdraw(
            _ids(tokenId),
            _amounts(0),
            7,
            _emptyExtras(),
            newOwner
        );

        assertEq(token.getChainIdByTokenId(tokenId), 7);
    }

    /// @notice Exercises the ERC1155 transfer path inside
    ///         `_update(msg.sender, _newOwner, _ids, _amounts)` with a real,
    ///         non-zero balance held by the relayer.
    function test_relayer_UpdateInfosAfterDvpWithdraw_transfers_balance() public {
        uint256 tokenId = 4;
        uint256 amount  = 250;
        uint256 chainId = 11;
        address newOwner = makeAddr("NEW_OWNER");

        vm.startPrank(relayer);
        // Mint to the relayer itself so `_update(msg.sender = relayer, ...)`
        // has the balance to move.
        token.mint(relayer, tokenId, amount, "", chainId, _emptyExtras());
        assertEq(token.balanceOf(relayer, tokenId), amount);

        token.UpdateInfosAfterDvpWithdraw(
            _ids(tokenId),
            _amounts(amount),
            chainId,
            _oneExtra("color", "red"),
            newOwner
        );
        vm.stopPrank();

        // Balance moved from relayer to newOwner.
        assertEq(token.balanceOf(relayer, tokenId), 0);
        assertEq(token.balanceOf(newOwner, tokenId), amount);

        // Routing/metadata mutations landed.
        assertEq(token.getChainIdByTokenId(tokenId), chainId);

        SharedObjects.Dvp1155ExtraData[] memory extras = token.getTokenExtraData(tokenId);
        assertEq(extras.length, 1);
        assertEq(extras[0].value, "red");
    }

    // ─── data lifecycle ────────────────────────────────────────────────────

    /// @notice Partial burn must NOT clear the per-id chainId mapping —
    ///         it is per-token-id, not per-holder, and other holders may
    ///         still need it.
    function test_partial_burn_preserves_chainId() public {
        uint256 tokenId = 0xC1EA0;
        uint256 chainId = 42;

        vm.startPrank(relayer);
        token.mint(victim, tokenId, 100, "", chainId, _emptyExtras());
        assertEq(token.getChainIdByTokenId(tokenId), chainId);

        token.burn(victim, tokenId, 60);
        vm.stopPrank();

        assertEq(token.balanceOf(victim, tokenId), 40, "remaining balance");
        assertEq(
            token.getChainIdByTokenId(tokenId),
            chainId,
            "chainId must persist while supply > 0"
        );
    }

    /// @notice Full burn (supply hits zero) must clear both `_tokenIdToChainId`
    ///         and `tokenExtraData` so a future re-mint of the same id starts
    ///         from a clean slate.
    function test_full_burn_clears_chainId_and_extra_data() public {
        uint256 tokenId = 0xBEEF;
        uint256 chainId = 7;

        vm.startPrank(relayer);
        token.mint(victim, tokenId, 100, "", chainId, _oneExtra("color", "red"));

        SharedObjects.Dvp1155ExtraData[] memory beforeBurn = token.getTokenExtraData(tokenId);
        assertEq(beforeBurn.length, 1);

        token.burn(victim, tokenId, 100);
        vm.stopPrank();

        assertEq(token.totalSupply(tokenId), 0, "supply zeroed");
        assertEq(token.getChainIdByTokenId(tokenId), 0, "chainId cleared");

        SharedObjects.Dvp1155ExtraData[] memory afterBurn = token.getTokenExtraData(tokenId);
        assertEq(afterBurn.length, 0, "tokenExtraData cleared");

        // Re-mint with no extras must observe a fresh empty array.
        vm.prank(relayer);
        token.mint(victim, tokenId, 1, "", 99, _emptyExtras());

        SharedObjects.Dvp1155ExtraData[] memory afterRemint = token.getTokenExtraData(tokenId);
        assertEq(afterRemint.length, 0, "re-mint must not inherit stale extras");
    }

    /// @notice Full burn must also clear `tokenRegisteredToGroup` and
    ///         `tokenIsFungible`. The first-mint registration block in `mint`
    ///         only runs when `tokenRegisteredToGroup[_id] == false`, so a
    ///         leftover `true` would silently skip re-registration on a
    ///         subsequent re-mint of the same id (matters once the currently
    ///         commented-out factory registration is re-enabled).
    function test_full_burn_clears_registered_and_fungible_flags() public {
        uint256 tokenId = 0xCAFE;

        vm.startPrank(relayer);
        token.mint(victim, tokenId, 50, "", 1, _emptyExtras());
        assertTrue(token.isTokenRegistered(tokenId), "registered after first mint");
        assertTrue(token.getTokenFungibility(tokenId), "fungible after first mint");

        token.burn(victim, tokenId, 50);
        vm.stopPrank();

        assertEq(token.totalSupply(tokenId), 0, "supply zeroed");
        assertFalse(token.isTokenRegistered(tokenId), "tokenRegisteredToGroup must be cleared on full burn");
        // `getTokenFungibility` reverts when the token does not exist; checking
        // registration is the public-surface signal that the slot was cleared.
    }
}

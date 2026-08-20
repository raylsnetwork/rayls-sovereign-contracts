// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import {TOKEN_OWNER} from "../../../privateHub/AccessControl/AccessManagerTypes.sol";

/**
 * @title F19_GrantRole_Global_TokenOwner_CrossTokenMasterKey
 * @notice Reproduction tests for audit finding F19:
 *         `RaylsAccessManagerV1.grantRole` accepts `TOKEN_OWNER` (role id 2) as
 *         a GLOBAL grant, turning a single call into a cross-token master key.
 *
 * BACKGROUND
 * ----------
 * `TOKEN_OWNER` is a per-contract-scoped role by design: every token that
 * self-registers via `selfRegisterManagedContract` maps its privileged owner
 * selectors (mint/burn/submitTokenUpdate) to `TOKEN_OWNER` in the token's own
 * `allowedRoleSegments[selector]` bitmap. The intended grant API is
 * `grantContractScopedRole(TOKEN_OWNER, account, token, 0)`, which writes
 * `$._roles[TOKEN_OWNER].contractScopedGrants[account][token]`.
 *
 * `grantRole` ([AccessManagerRoleConfigLib.sol:91-98]) rejects `PUBLIC` but
 * DOES NOT reject `TOKEN_OWNER`. A global grant writes
 * `$._roles[TOKEN_OWNER].globalGrants[account]`; `_checkGlobalBitmap` in
 * `AccessManagerAuthLib.canCall` accepts it against EVERY managed contract's
 * `allowedRoleSegments[selector]` bitmap that lists TOKEN_OWNER. In this
 * protocol that is every self-registered token — so one call mints on all of
 * them.
 *
 * TEST SEMANTICS (project convention)
 * -----------------------------------
 *  - `test_F19_baseline_*` — always-pass scaffolding checks.
 *  - `test_F19_exploit_*` — FAIL on current code (grant succeeds and attacker
 *    can mint on every token); PASS once `grantRole` rejects TOKEN_OWNER.
 *  - `test_F19_postfix_*` — positive controls; must pass pre- and post-fix.
 */
contract F19_GrantRole_Global_TokenOwner_CrossTokenMasterKey is Test {
    address internal admin;
    address internal attacker;
    address internal innocent;

    RaylsAccessManagerV1 internal manager;
    MinimalManagedToken internal token1;
    MinimalManagedToken internal token2;

    bytes4 internal mintSelector;

    function setUp() public {
        admin = makeAddr("ADMIN");
        attacker = makeAddr("ATTACKER");
        innocent = makeAddr("INNOCENT");

        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory mgrInit = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), mgrInit)));

        // Deploy two minimal tokens that each self-register with the
        // owner-selector convention. After the constructor:
        //   - token.allowedRoleSegments[mint.selector] bitmap has TOKEN_OWNER
        //     set — so canCall(x, token, mint.sig) succeeds if x holds
        //     TOKEN_OWNER (globally or scoped to this token).
        //   - The deployer (this test contract) is granted TOKEN_OWNER scoped
        //     to the token and becomes the token's contract authority.
        token1 = new MinimalManagedToken(address(manager), "F19-Token1");
        token2 = new MinimalManagedToken(address(manager), "F19-Token2");

        mintSelector = MinimalManagedToken.mint.selector;
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  BASELINE TESTS
    // ═════════════════════════════════════════════════════════════════════════

    /// Attacker has no role — neither token lets them mint directly.
    function test_F19_baseline_attacker_cannot_mint_either_token() public {
        (bool a1, , ) = manager.canCall(attacker, address(token1), mintSelector);
        (bool a2, , ) = manager.canCall(attacker, address(token2), mintSelector);
        assertFalse(a1, "baseline: attacker should not mint token1");
        assertFalse(a2, "baseline: attacker should not mint token2");

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        token1.mint(attacker, 1 ether);
    }

    /// Owner-scoped TOKEN_OWNER grants work correctly (positive control).
    function test_F19_baseline_scoped_grant_lets_holder_mint_its_token_only() public {
        // `this` is token1's contract authority (set during constructor).
        manager.grantContractScopedRole(TOKEN_OWNER, innocent, address(token1), 0);

        (bool a1, , ) = manager.canCall(innocent, address(token1), mintSelector);
        (bool a2, , ) = manager.canCall(innocent, address(token2), mintSelector);
        assertTrue(a1, "scoped grant should pass canCall for token1");
        assertFalse(a2, "scoped grant must NOT pass canCall for token2");

        vm.prank(innocent);
        token1.mint(innocent, 1 ether);
        assertEq(token1.balanceOf(innocent), 1 ether);

        vm.prank(innocent);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, innocent));
        token2.mint(innocent, 1 ether);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  EXPLOIT TESTS — fail pre-fix, pass post-fix
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * Demonstrates the broken API: `grantRole(TOKEN_OWNER, attacker, 0)` is
     * accepted today by `AccessManagerRoleConfigLib.grantRole`. Post-fix the
     * call must revert with a dedicated error (e.g. `TokenOwnerIsScopeOnly`).
     *
     * Assertion: `hasRole(TOKEN_OWNER, attacker)` is FALSE after the call.
     * Pre-fix the grant succeeds → hasRole is TRUE → FAIL.
     * Post-fix the grant reverts → hasRole stays FALSE → PASS.
     */
    function test_F19_exploit_global_tokenOwner_grant_should_be_rejected() public {
        bool granted;
        vm.prank(admin);
        try manager.grantRole(TOKEN_OWNER, attacker, 0) {
            granted = true;
        } catch {
            granted = false;
        }

        if (granted) {
            console2.log("F19-exploit: grantRole(TOKEN_OWNER, attacker, 0) succeeded - MASTER KEY MINTED");
        }

        (bool isMember, ) = manager.hasRole(TOKEN_OWNER, attacker);
        assertFalse(
            isMember,
            "F19: grantRole(TOKEN_OWNER, ...) landed a global TOKEN_OWNER grant"
        );
    }

    /**
     * The master-key impact: ONE global TOKEN_OWNER grant and the attacker
     * mints on BOTH token1 AND token2.
     *
     * Pre-fix: both mints succeed → balances > 0 → FAIL.
     * Post-fix: the grant reverts (see test above) so mints revert → balances
     *           stay 0 → PASS.
     */
    function test_F19_exploit_attacker_mints_on_both_tokens_via_global_grant() public {
        // Admin "mistakenly" (or maliciously) grants TOKEN_OWNER globally.
        vm.prank(admin);
        try manager.grantRole(TOKEN_OWNER, attacker, 0) {
            // pre-fix: the grant goes through
        } catch {
            // post-fix: the call reverts and we skip the exploit body
            assertEq(token1.balanceOf(attacker), 0, "token1 should have no attacker balance post-fix");
            assertEq(token2.balanceOf(attacker), 0, "token2 should have no attacker balance post-fix");
            return;
        }

        vm.prank(attacker);
        try token1.mint(attacker, 100 ether) {} catch {}

        vm.prank(attacker);
        try token2.mint(attacker, 200 ether) {} catch {}

        uint256 b1 = token1.balanceOf(attacker);
        uint256 b2 = token2.balanceOf(attacker);

        if (b1 > 0 || b2 > 0) {
            console2.log("F19-exploit: cross-token master key landed");
            console2.log("  token1 attacker balance:", b1);
            console2.log("  token2 attacker balance:", b2);
        }

        assertEq(b1, 0, "F19: attacker minted on token1 via global TOKEN_OWNER grant");
        assertEq(b2, 0, "F19: attacker minted on token2 via global TOKEN_OWNER grant (master key)");
    }

    /**
     * Independence check: even if only ONE token exists, the global grant is
     * still the wrong abstraction — it unconditionally matches every token's
     * TOKEN_OWNER bitmap. This test uses only token1 to prove the bypass at
     * the manager layer regardless of how many tokens are in the environment.
     */
    function test_F19_exploit_single_token_global_grant_bypasses_scope() public {
        vm.prank(admin);
        try manager.grantRole(TOKEN_OWNER, attacker, 0) {} catch {
            // post-fix: grant rejected; nothing else to test in this case
            (bool a1Post, , ) = manager.canCall(attacker, address(token1), mintSelector);
            assertFalse(a1Post, "post-fix: no grant so canCall must be false");
            return;
        }

        (bool allowed, , ) = manager.canCall(attacker, address(token1), mintSelector);
        if (allowed) {
            console2.log("F19-exploit: canCall returned true for globally-granted TOKEN_OWNER");
        }

        assertFalse(allowed, "F19: global TOKEN_OWNER grant satisfies canCall against token1");
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  POSTFIX POSITIVE CONTROL — must pass in either regime
    // ═════════════════════════════════════════════════════════════════════════

    /**
     * The intended API (`grantContractScopedRole`) isolates authority per
     * token. This test is already expected to PASS pre-fix (scoped grants
     * already work). It only verifies the fix does not regress scoped grants.
     */
    function test_F19_postfix_scoped_grant_still_isolates_authority() public {
        manager.grantContractScopedRole(TOKEN_OWNER, attacker, address(token1), 0);

        (bool a1, , ) = manager.canCall(attacker, address(token1), mintSelector);
        (bool a2, , ) = manager.canCall(attacker, address(token2), mintSelector);
        assertTrue(a1, "scoped grant must pass for token1");
        assertFalse(a2, "scoped grant must NOT leak to token2");
    }
}

/**
 * @dev Minimal token-shaped `RaylsAccessManaged` consumer.
 *      Self-registers `mint` under TOKEN_OWNER the same way production tokens
 *      do via `RaylsErc20Handler._registerAccessControl`.
 */
contract MinimalManagedToken is RaylsAccessManaged {
    string public name;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address authority_, string memory _name) {
        name = _name;
        _initializeAuthority(authority_);

        bytes4[] memory ownerSels = new bytes4[](1);
        ownerSels[0] = this.mint.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings =
            new IRaylsAccessManager.SelectorRoleMapping[](0);

        IRaylsAccessManager(authority_).selfRegisterManagedContract(msg.sender, ownerSels, mappings);
    }

    function mint(address to, uint256 value) external restricted {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }
}

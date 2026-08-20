// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CustomTokenExample} from "../../../rayls-protocol/test-contracts/CustomTokenExample.sol";
import {RaylsErc20Handler} from "../../../rayls-protocol-sdk/tokens/RaylsErc20Handler.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

/**
 * @title _registerAccessControl coverage suite
 * @notice Verifies that handler `_registerAccessControl` overrides map the intended
 *         selectors to the intended roles AND that no critical surface leaks to admin
 *         (which would break access-control invariants for receive paths or expose
 *         privileged supply-control to the wrong actor).
 *
 *         Scope: focuses on contracts whose `_registerAccessControl` was modified by
 *         issue #98 — `RaylsErc20Handler` (made `virtual`) and `CustomTokenExample`
 *         (override that extends ownerSels with `setAttestationUuid`). Other handlers
 *         (`RaylsErc721Handler`, `RaylsErc1155Handler`, `RaylsEnygmaHandler`, the DvP
 *         variants) keep their pre-#98 implementation and are exercised end-to-end via
 *         the existing teleport / DvP suites; adding parallel unit fixtures for them is
 *         tracked as a follow-up but out of scope for this finding.
 */

/// @dev Endpoint stub matching CustomTokenExample's expectations during construction +
///      initialize. Mirrors the stub used by `CustomTokenExample_AccessControl.t.sol`.
contract _MockEndpointForRegisterCoverage {
    address private _authority;

    function setAuthority(address a) external {
        _authority = a;
    }

    function authority() external view returns (address) {
        return _authority;
    }

    function getUserGovernanceAddress() external pure returns (address) {
        return address(0);
    }

    function contractVersion() external pure returns (uint256) {
        return 1;
    }

    function getPrivateHubAddress(string memory) external pure returns (address) {
        return address(0);
    }

    function getAddressByResourceId(bytes32) external pure returns (address) {
        return address(0);
    }
}

contract RegisterAccessControl_CoverageTest is Test {
    RaylsAccessManagerV1 internal manager;
    _MockEndpointForRegisterCoverage internal endpoint;

    address internal admin = address(this);
    address internal raylsNodeEndpoint = makeAddr("raylsNodeEndpoint");
    address internal tokenOwner = makeAddr("tokenOwner");

    uint64 internal tokenOwnerRoleId; // RaylsAccessManagerV1.TOKEN_OWNER == 2 (built-in)
    uint64 internal messageExecutorRoleId;

    // Selectors we expect to be ownerSels on CustomTokenExample (registered to TOKEN_OWNER).
    bytes4 internal constant SEL_MINT                  = bytes4(keccak256("mint(address,uint256)"));
    bytes4 internal constant SEL_BURN_ADMIN            = bytes4(keccak256("burn(address,uint256)"));
    bytes4 internal constant SEL_SUBMIT_TOKEN_UPDATE   = bytes4(keccak256("submitTokenUpdate(uint8,uint256)"));
    bytes4 internal constant SEL_SET_ATTESTATION_UUID  = bytes4(keccak256("setAttestationUuid(bytes32)"));

    // Selectors we expect to be executorSels (registered to MESSAGE_EXECUTOR).
    bytes4 internal constant SEL_RECEIVE_TELEPORT          = bytes4(keccak256("receiveTeleport(address,uint256)"));
    bytes4 internal constant SEL_RECEIVE_TELEPORT_ATOMIC   = bytes4(keccak256("receiveTeleportAtomic(address,uint256)"));
    bytes4 internal constant SEL_REVERT_TELEPORT_MINT      = bytes4(keccak256("revertTeleportMint(address,uint256)"));
    bytes4 internal constant SEL_REVERT_TELEPORT_BURN      = bytes4(keccak256("revertTeleportBurn(address,uint256)"));
    bytes4 internal constant SEL_UNLOCK                    = bytes4(keccak256("unlock(address,uint256)"));
    bytes4 internal constant SEL_RECEIVE_TELEPORT_FROM_PUB = bytes4(keccak256("receiveTeleportFromPublicChain(address,uint256)"));
    bytes4 internal constant SEL_REVERT_TELEPORT_TO_PUB    = bytes4(keccak256("revertTeleportToPublicChain(address,uint256)"));

    // Selectors that MUST stay public (i.e. NOT be registered to any role).
    bytes4 internal constant SEL_BURN_PUBLIC               = bytes4(keccak256("burn(uint256)"));
    bytes4 internal constant SEL_BURN_FROM_PUBLIC          = bytes4(keccak256("burnFrom(address,uint256)"));

    function setUp() public {
        // Stand up an AccessManager backed by ERC1967Proxy.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(mgrImpl.initialize, (admin))
        )));

        // TOKEN_OWNER is a constant role (id = 2) auto-assigned by `selfRegisterManagedContract`.
        tokenOwnerRoleId = manager.TOKEN_OWNER();
        // MESSAGE_EXECUTOR is registered by name and looked up at registration time.
        messageExecutorRoleId = manager.registerRole("MESSAGE_EXECUTOR");

        endpoint = new _MockEndpointForRegisterCoverage();
    }

    // ─────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────

    /// @dev Direct-deploy a CustomTokenExample with `endpoint.authority()` set so the parent's
    ///      `_registerAccessControl(_owner)` runs exactly once via the override (single-call
    ///      registration — confirms the #M2 fix that eliminates the double-register paradox).
    function _deployCustomToken() internal returns (CustomTokenExample tok) {
        endpoint.setAuthority(address(manager));
        // msg.sender = address(this) becomes _owner (TOKEN_OWNER recipient) for direct-deploy.
        tok = new CustomTokenExample(
            "CustomTok",
            "CTK",
            0,
            address(0),
            address(endpoint),
            raylsNodeEndpoint,
            address(manager)
        );
    }

    /// @dev Lookup whether a selector is registered to a given role on a managed contract.
    ///      Reads the AccessManager's `getFunctionAllowedRoles` mapping.
    function _isRegistered(address managed, bytes4 sel, uint64 roleId) internal view returns (bool) {
        uint64[] memory roles = manager.getFunctionAllowedRoles(managed, sel);
        for (uint256 i; i < roles.length; ++i) {
            if (roles[i] == roleId) return true;
        }
        return false;
    }

    /// @dev True when no role has been mapped to a selector. Important for asserting that a
    ///      function is intended to be public (unmapped → admin-only fallback in the
    ///      AccessManager, but in this codebase such functions are intentionally NOT
    ///      reached via `restricted` — they bypass the modifier entirely and remain public).
    function _selectorIsUnmapped(address managed, bytes4 sel) internal view returns (bool) {
        return manager.getFunctionAllowedRoles(managed, sel).length == 0;
    }

    // ─────────────────────────────────────────────────────────────────
    //  CustomTokenExample override — owner-gated selector mapping
    // ─────────────────────────────────────────────────────────────────

    function test_customTokenExample_mint_isTokenOwnerSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_MINT, tokenOwnerRoleId),
            "mint(address,uint256) must be registered to TOKEN_OWNER"
        );
    }

    function test_customTokenExample_burnAdmin_isTokenOwnerSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_BURN_ADMIN, tokenOwnerRoleId),
            "burn(address,uint256) must be registered to TOKEN_OWNER"
        );
    }

    function test_customTokenExample_submitTokenUpdate_isTokenOwnerSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_SUBMIT_TOKEN_UPDATE, tokenOwnerRoleId),
            "submitTokenUpdate(uint8,uint256) must be registered to TOKEN_OWNER"
        );
    }

    function test_customTokenExample_setAttestationUuid_isTokenOwnerSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_SET_ATTESTATION_UUID, tokenOwnerRoleId),
            "setAttestationUuid(bytes32) must be registered to TOKEN_OWNER (override-added)"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    //  CustomTokenExample override — MESSAGE_EXECUTOR selector mapping
    // ─────────────────────────────────────────────────────────────────

    function test_customTokenExample_receiveTeleport_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_RECEIVE_TELEPORT, messageExecutorRoleId),
            "receiveTeleport(address,uint256) must be registered to MESSAGE_EXECUTOR"
        );
    }

    function test_customTokenExample_receiveTeleportAtomic_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_RECEIVE_TELEPORT_ATOMIC, messageExecutorRoleId),
            "receiveTeleportAtomic must be registered to MESSAGE_EXECUTOR"
        );
    }

    function test_customTokenExample_revertTeleportMint_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_REVERT_TELEPORT_MINT, messageExecutorRoleId),
            "revertTeleportMint must be registered to MESSAGE_EXECUTOR"
        );
    }

    function test_customTokenExample_revertTeleportBurn_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_REVERT_TELEPORT_BURN, messageExecutorRoleId),
            "revertTeleportBurn must be registered to MESSAGE_EXECUTOR"
        );
    }

    function test_customTokenExample_unlock_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_UNLOCK, messageExecutorRoleId),
            "unlock(address,uint256) must be registered to MESSAGE_EXECUTOR"
        );
    }

    function test_customTokenExample_receiveTeleportFromPublicChain_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_RECEIVE_TELEPORT_FROM_PUB, messageExecutorRoleId),
            "receiveTeleportFromPublicChain must be registered to MESSAGE_EXECUTOR"
        );
    }

    function test_customTokenExample_revertTeleportToPublicChain_isMessageExecutorSelector() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _isRegistered(address(tok), SEL_REVERT_TELEPORT_TO_PUB, messageExecutorRoleId),
            "revertTeleportToPublicChain must be registered to MESSAGE_EXECUTOR"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    //  Negative coverage — public selectors must stay unmapped
    // ─────────────────────────────────────────────────────────────────

    /// @dev `burn(uint256)` on CustomTokenExample is the holder-side self-burn — public per
    ///      ERC20Burnable convention. Registering it to ANY role would break that contract:
    ///      AccessManager would interpret the function as access-controlled, and the
    ///      function lacks the `restricted` modifier so the registration would silently no-op
    ///      while creating a confusing surface for auditors. Verify it stays unmapped.
    function test_customTokenExample_burnPublic_isUnmapped() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _selectorIsUnmapped(address(tok), SEL_BURN_PUBLIC),
            "burn(uint256) must remain unmapped - it is a public ERC20Burnable self-burn"
        );
    }

    function test_customTokenExample_burnFromPublic_isUnmapped() public {
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(
            _selectorIsUnmapped(address(tok), SEL_BURN_FROM_PUBLIC),
            "burnFrom(address,uint256) must remain unmapped - it is a public ERC20Burnable allowance burn"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    //  #M2 regression — single-call registration, no double-register
    // ─────────────────────────────────────────────────────────────────

    /// @notice Direct-deploy with `endpoint.authority() != 0` exercises the parent
    ///         constructor's `_registerAccessControl(_owner)` call (now via the override).
    ///         Pre-#M2-fix, the constructor body invoked `selfRegisterManagedContract` a
    ///         second time and reverted with `__ContractAlreadyRegistered`. Post-fix, the
    ///         single override-routed call is the ONLY registration.
    function test_customTokenExample_directDeployAuthSet_doesNotRevertWithAlreadyRegistered() public {
        // Should NOT revert.
        CustomTokenExample tok = _deployCustomToken();
        assertTrue(address(tok).code.length > 0, "constructor must complete with authority != 0");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Cardinality assertions — total ownerSels = 4, executorSels = 7
    //  Catches accidental additions/removals to the override.
    // ─────────────────────────────────────────────────────────────────

    function test_customTokenExample_ownerSelector_count_equals4() public {
        CustomTokenExample tok = _deployCustomToken();
        uint256 ownerSelectorCount;
        bytes4[8] memory candidates = [
            SEL_MINT,
            SEL_BURN_ADMIN,
            SEL_SUBMIT_TOKEN_UPDATE,
            SEL_SET_ATTESTATION_UUID,
            SEL_BURN_PUBLIC,           // must NOT count — public
            SEL_BURN_FROM_PUBLIC,      // must NOT count — public
            bytes4(keccak256("nonexistent()")),
            bytes4(keccak256("alsoNonexistent()"))
        ];
        for (uint256 i; i < candidates.length; ++i) {
            if (_isRegistered(address(tok), candidates[i], tokenOwnerRoleId)) {
                ownerSelectorCount++;
            }
        }
        assertEq(ownerSelectorCount, 4, "exactly 4 selectors must be mapped to TOKEN_OWNER");
    }

    function test_customTokenExample_executorSelector_count_equals7() public {
        CustomTokenExample tok = _deployCustomToken();
        uint256 executorSelectorCount;
        bytes4[7] memory candidates = [
            SEL_RECEIVE_TELEPORT,
            SEL_RECEIVE_TELEPORT_ATOMIC,
            SEL_REVERT_TELEPORT_MINT,
            SEL_REVERT_TELEPORT_BURN,
            SEL_UNLOCK,
            SEL_RECEIVE_TELEPORT_FROM_PUB,
            SEL_REVERT_TELEPORT_TO_PUB
        ];
        for (uint256 i; i < candidates.length; ++i) {
            if (_isRegistered(address(tok), candidates[i], messageExecutorRoleId)) {
                executorSelectorCount++;
            }
        }
        assertEq(executorSelectorCount, 7, "exactly 7 selectors must be mapped to MESSAGE_EXECUTOR");
    }
}

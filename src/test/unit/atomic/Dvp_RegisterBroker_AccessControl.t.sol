// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Dvp} from "../../../rayls-protocol/Enygma/Enygma-DVP/Dvp.sol";
import {IDvp} from "../../../rayls-protocol/interfaces/IDvp.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";

/**
 * @title Security Test: Dvp.registerBroker() Access Control (Auth V3)
 * @notice Tests that registerBroker() has proper role-based access control via RaylsAccessManager.
 * @dev These tests FAIL when the vulnerability exists (no access control),
 *      and PASS when the fix is applied (`restricted` modifier with TOKEN_OWNER role).
 *
 * ISSUE:
 *   registerBroker() was publicly callable by anyone. Other sensitive registration
 *   functions (registerAuditor, registerVault, registerAssetGroup, etc.) all require
 *   TOKEN_OWNER role, and registerBroker() should too.
 *
 * TEST LOGIC:
 *   - Uses vm.expectRevert with RaylsAccessManaged__Unauthorized error
 *   - If function HAS restricted → reverts with RaylsAccessManaged__Unauthorized → test PASSES
 *   - If function LACKS restricted → reverts with a different error or succeeds → test FAILS
 */
contract Dvp_RegisterBroker_AccessControlTest is Test {
    Dvp public dvp;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public attacker;

    function setUp() public {
        owner = address(this);
        attacker = makeAddr("attacker");

        // Deploy AccessManager via proxy — owner becomes initial admin
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (owner));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Register roles referenced by Dvp's selfRegisterManagedContract
        manager.registerRole("ENYGMA_CREATOR");
        manager.registerRole("COIN_VAULT");

        // Deploy Dvp — constructor self-registers with AccessManager
        dvp = new Dvp(
            address(0x1), // hashPoseidonContractAddress
            address(0x2), // enygmaFactoryAddress
            address(0x3), // dvpErc721FactoryAddress
            address(0x4), // dvpErc1155FactoryAddress
            address(0x5), // dvpTeleportAddress
            address(manager)
        );
    }

    // ============================================================
    // NEGATIVE TEST: Unauthorized caller MUST be rejected
    // FAILS when vulnerability exists, PASSES when fixed
    // ============================================================

    /**
     * @notice SECURITY: registerBroker() MUST have `restricted` access control
     * @dev Without access control, anyone can register as a broker, enabling:
     *      - Spam registrations polluting the broker registry
     *      - Malicious broker identities
     *      - Registry bloat affecting contract performance
     *
     * TEST BEHAVIOR:
     *   - FAILS when vulnerability exists: function reverts with proof-validation error
     *     instead of RaylsAccessManaged__Unauthorized
     *   - PASSES when fixed: function reverts with RaylsAccessManaged__Unauthorized
     *     BEFORE reaching any proof validation logic
     */
    function test_registerBroker_mustRevertForUnauthorizedCaller() public {
        IDvp.ProofReceipt memory fakeProof;
        fakeProof.proof = IDvp.SnarkProof({
            a: IDvp.G1Point(0, 0),
            b: IDvp.G2Point([uint256(0), 0], [uint256(0), 0]),
            c: IDvp.G1Point(0, 0)
        });
        fakeProof.treeNumbers = new uint256[](2);
        fakeProof.message = 0;
        fakeProof.merkleRoots = new uint256[](2);
        fakeProof.commitments = new uint256[](0);
        fakeProof.nullifiers = new uint256[](2);

        vm.prank(attacker);

        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                attacker
            )
        );
        dvp.registerBroker(fakeProof);
    }

    // ============================================================
    // POSITIVE TEST: Owner MUST be able to call registerBroker
    // ============================================================

    /**
     * @notice Owner should NOT be blocked by access control on registerBroker()
     * @dev This test verifies the owner (TOKEN_OWNER) passes the access control gate.
     *      The call will revert deeper in proof validation (no verifier/groups configured),
     *      but it must NOT revert with RaylsAccessManaged__Unauthorized.
     */
    function test_registerBroker_ownerPassesAccessControl() public {
        IDvp.ProofReceipt memory fakeProof;
        fakeProof.proof = IDvp.SnarkProof({
            a: IDvp.G1Point(0, 0),
            b: IDvp.G2Point([uint256(0), 0], [uint256(0), 0]),
            c: IDvp.G1Point(0, 0)
        });
        fakeProof.treeNumbers = new uint256[](2);
        fakeProof.message = 0;
        fakeProof.merkleRoots = new uint256[](2);
        fakeProof.commitments = new uint256[](0);
        fakeProof.nullifiers = new uint256[](2);

        // Owner calls — will revert in proof validation (no verifier configured),
        // but we use try/catch to confirm it's NOT an access control rejection.
        try dvp.registerBroker(fakeProof) {
        } catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(reason, 32)) }
                assertTrue(
                    selector != RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                    "Owner should not be rejected by access control"
                );
            }
        }
    }
}

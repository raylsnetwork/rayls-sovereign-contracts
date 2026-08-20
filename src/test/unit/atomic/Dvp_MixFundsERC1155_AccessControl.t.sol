// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Dvp} from "../../../rayls-protocol/Enygma/Enygma-DVP/Dvp.sol";
import {IDvp} from "../../../rayls-protocol/interfaces/IDvp.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";

/**
 * @title Security Test: Dvp.mixFundsERC1155 Access Control
 * @notice Verifies that mixFundsERC1155() is intentionally public (no role restriction)
 * @dev mixFundsERC1155 differs from mixFunds by design:
 *
 * ARCHITECTURE:
 * - mixFunds() is protected by `restricted` because Enygma operations
 *   flow through EnygmaDvpIntegration which holds the ENYGMA_CREATOR role.
 * - mixFundsERC1155() is public because ERC1155 operations are called directly by the
 *   relayer with CTS-generated keys. The ENYGMA_CREATOR role is never granted for ERC1155 callers.
 * - Security is provided by ZK proof verification in Erc1155CoinVault.transfer().
 * - This is consistent with depositERC1155() and withdrawERC1155() which are also public.
 */
contract DvpMixFundsERC1155AccessControlTest is Test {
    Dvp public dvp;
    RaylsAccessManagerV1 public manager;

    address public owner;
    address public caller;
    address public authorizedEnygma;

    function _buildFakeProof() internal pure returns (IDvp.ProofReceipt memory) {
        IDvp.ProofReceipt memory fakeProof;
        fakeProof.proof = IDvp.SnarkProof({
            a: IDvp.G1Point(0, 0),
            b: IDvp.G2Point([uint256(0), 0], [uint256(0), 0]),
            c: IDvp.G1Point(0, 0)
        });
        fakeProof.treeNumbers = new uint256[](0);
        fakeProof.message = 0;
        fakeProof.merkleRoots = new uint256[](0);
        fakeProof.commitments = new uint256[](0);
        fakeProof.nullifiers = new uint256[](0);
        return fakeProof;
    }

    function setUp() public {
        owner = address(this);
        caller = makeAddr("caller");
        authorizedEnygma = makeAddr("enygmaIntegration");

        // Deploy AccessManager via proxy — owner becomes initial admin
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (owner));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(address(impl), initData)));

        // Register roles referenced by Dvp's selfRegisterManagedContract
        manager.registerRole("ENYGMA_CREATOR");
        manager.registerRole("COIN_VAULT");

        // Deploy Dvp — constructor self-registers ENYGMA_CREATOR and COIN_VAULT roles
        dvp = new Dvp(
            address(0x1), // hashPoseidonContractAddress (mock)
            address(0x2), // enygmaFactoryAddress (mock)
            address(0x3), // dvpErc721FactoryAddress (mock)
            address(0x4), // dvpErc1155FactoryAddress (mock)
            address(0x5), // dvpTeleportAddress (mock)
            address(manager)
        );

        // Grant ENYGMA_CREATOR role to authorizedEnygma
        uint64 enygmaCreatorRole = manager.getRoleIdByName("ENYGMA_CREATOR");
        manager.grantRole(enygmaCreatorRole, authorizedEnygma, 0);
    }

    // ================================================================
    // mixFundsERC1155 is PUBLIC — any caller passes access control
    // Security is enforced by ZK proof verification in the vault.
    // ================================================================

    /**
     * @notice Any address can call mixFundsERC1155 (no role restriction).
     * @dev The call reverts on vault lookup (no vault registered for 0xBEEF),
     *      but it must NOT revert with RaylsAccessManaged__Unauthorized.
     */
    function test_mixFundsERC1155_anyCallerPassesAccessControl() public {
        IDvp.ProofReceipt memory fakeProof = _buildFakeProof();

        vm.prank(caller);
        try dvp.mixFundsERC1155(address(0xBEEF), fakeProof) {
        } catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(reason, 32)) }
                assertTrue(
                    selector != RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                    "mixFundsERC1155 should not have role-based access control"
                );
            }
        }
    }

    /**
     * @notice Even a random EOA reaches vault logic (not blocked by access control).
     */
    function test_mixFundsERC1155_randomEOAPassesAccessControl() public {
        address randomUser = makeAddr("randomUser");
        IDvp.ProofReceipt memory fakeProof = _buildFakeProof();

        vm.prank(randomUser);
        try dvp.mixFundsERC1155(address(0xBEEF), fakeProof) {
        } catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(reason, 32)) }
                assertTrue(
                    selector != RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                    "Random EOA should not be blocked by access control on mixFundsERC1155"
                );
            }
        }
    }

    // ================================================================
    // mixFunds STILL requires ENYGMA_CREATOR role (Enygma flow uses integration)
    // ================================================================

    /**
     * @notice mixFunds() MUST still reject callers without ENYGMA_CREATOR role.
     * @dev This confirms the role restriction remains on the Enygma path.
     */
    function test_mixFunds_stillRequiresEnygmaRole() public {
        IDvp.ProofReceipt memory fakeProof = _buildFakeProof();

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                caller
            )
        );
        dvp.mixFunds(1, fakeProof);
    }

    // ================================================================
    // ARCHITECTURAL CONSISTENCY — ERC1155 functions are all public
    // ================================================================

    /**
     * @notice Confirms the intentional design difference between mixFunds and mixFundsERC1155.
     * @dev mixFunds rejects unauthorized callers; mixFundsERC1155 does not.
     *      This is by design: ERC1155 operations bypass EnygmaDvpIntegration.
     */
    function test_architecturalDifference_mixFunds_vs_mixFundsERC1155() public {
        IDvp.ProofReceipt memory fakeProof = _buildFakeProof();

        // mixFunds rejects caller without ENYGMA_CREATOR role
        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                caller
            )
        );
        dvp.mixFunds(1, fakeProof);

        // mixFundsERC1155 does NOT reject the same caller (public function)
        vm.prank(caller);
        try dvp.mixFundsERC1155(address(0xBEEF), fakeProof) {
        } catch (bytes memory reason) {
            if (reason.length >= 4) {
                bytes4 selector;
                assembly { selector := mload(add(reason, 32)) }
                assertTrue(
                    selector != RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector,
                    "mixFundsERC1155 should not reject based on access control"
                );
            }
        }
    }
}

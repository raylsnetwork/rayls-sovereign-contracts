// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Erc721CoinVault} from "../../../rayls-protocol/Enygma/Enygma-DVP/Erc721CoinVault.sol";
import {MockPoseidonWrapper} from "../mocks/MockPoseidonWrapper.sol";
import {MockReentrantDvpTeleport} from "../mocks/MockReentrantDvpTeleport.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";

/**
 * @title Slither Medium #9-30: reentrancy-no-eth
 * @notice Tests that CoinVault functions are protected against reentrancy via DvpTeleport callbacks.
 *
 * VULNERABILITY:
 *   CoinVault deposit/withdraw/transfer functions make external calls to DvpTeleport
 *   (emitCommitments, emitNullifier) and then write state variables afterwards.
 *   A malicious or compromised DvpTeleport could re-enter the vault during these
 *   callbacks, corrupting merkle tree state and potentially enabling double-spends.
 *
 *   Affected contracts and functions (19 remaining, EnygmaV1 already fixed):
 *   - AbstractCoinVault._nullifyFromReceipt (#22)
 *   - Erc721CoinVault: deposit, withdraw (#16), transfer (#24)
 *   - Erc1155CoinVault: deposit (#21), withdraw (#15), transfer (#28)
 *   - EnygmaCoinVault: withdraw (#30), transfer (#26)
 *   - RaylsErc721DvpHandler: dvpSwapCompleted (#10), burn (#14)
 *   - TokenCoreV1: addToken (#11)
 *   - ZkAuction: newAuction (#12), declareWinner (#13), submitBid (#17)
 *   - Dvp: registerAssetGroup (#18)
 *   - ResourceManager: handleWithResourceId (#20)
 *   - EnygmaFactory: initiateEnygmaCreation (#25)
 *
 * FIX: Add ReentrancyGuard (nonReentrant modifier) to all affected functions.
 *      Move ReentrancyGuard to AbstractCoinVault so all vault subclasses inherit it.
 *
 * TEST LOGIC:
 *   - Deploy vault with MockReentrantDvpTeleport as the DvpTeleport
 *   - MockReentrantDvpTeleport re-enters vault.deposit() during emitCommitments callback
 *   - Test asserts reentrancy is BLOCKED (reentrancySucceeded == false)
 *   - Test FAILS when vulnerability present (reentrancy succeeds)
 *   - Test PASSES when fixed (nonReentrant blocks re-entry)
 */

/**
 * @notice Test reentrancy on Erc721CoinVault.deposit()
 * @dev Erc721CoinVault.deposit() does NOT transfer tokens (expects NFT already in vault).
 *      It computes a commitment, inserts into merkle tree, then calls DvpTeleport.emitCommitments.
 *      The external DvpTeleport call is the reentrancy vector.
 *
 *      ATTACK SCENARIO:
 *      1. Attacker calls vault.deposit([tokenId=1, publicKey=12345])
 *      2. Vault computes commitment, inserts leaf into merkle tree
 *      3. Vault calls DvpTeleport.emitCommitments() → EXTERNAL CALL
 *      4. Malicious DvpTeleport re-enters vault.deposit([tokenId=999, publicKey=67890])
 *      5. WITHOUT FIX: Second deposit succeeds mid-first-deposit, inserting extra commitment
 *         - Merkle tree integrity violated (unexpected leaf count)
 *         - Event ordering corrupted (inner deposit events before outer deposit completes)
 *      6. WITH FIX: Re-entry reverts with ReentrancyGuardReentrantCall
 */
contract SlitherMedium_Reentrancy_Erc721CoinVault_Test is Test {
    Erc721CoinVault public vault;
    MockReentrantDvpTeleport public reentrantTeleport;
    MockPoseidonWrapper public poseidon;
    address public dvpContract;

    RaylsAccessManagerV1 public manager;

    function setUp() public {
        dvpContract = address(this);
        poseidon = new MockPoseidonWrapper();
        reentrantTeleport = new MockReentrantDvpTeleport();

        // Deploy AccessManager via proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(this)))))
        );

        // Register role referenced by CoinVault's selfRegisterManagedContract
        manager.registerRole("DVP_CONTRACT");

        // Deploy vault — constructor self-registers DVP_CONTRACT role
        vault = new Erc721CoinVault(
            dvpContract,
            address(reentrantTeleport),
            address(poseidon),
            8,
            address(manager)
        );

        // Grant DVP_CONTRACT role to dvpContract (address(this))
        uint64 dvpRole = manager.getRoleIdByName("DVP_CONTRACT");
        manager.grantRole(dvpRole, dvpContract, 0);

        // Initialize vault (caller is dvpContract which has DVP_CONTRACT role)
        vault.initializeVault(
            1,                      // vaultId
            makeAddr("nft"),        // assetContractAddress
            8,                      // treeDepth
            address(poseidon),      // hashContractAddress
            address(0),             // verifierContractAddress
            address(0)              // zkAuctionContractAddress
        );

        // Configure reentrant teleport to target this vault
        reentrantTeleport.setTarget(address(vault));
    }

    /**
     * @notice Reentrancy via DvpTeleport.emitCommitments MUST be blocked
     * @dev Test FAILS when vulnerability present (re-entry succeeds → reentrancySucceeded = true)
     *      Test PASSES when fixed with nonReentrant (re-entry blocked → reentrancySucceeded = false)
     */
    function test_deposit_reentrancy_via_dvpTeleport_blocked() public {
        // Arm the reentrant teleport
        reentrantTeleport.arm();

        // Call deposit - this will:
        // 1. Compute commitment
        // 2. Insert into merkle tree
        // 3. Call DvpTeleport.emitCommitments → triggers re-entry attempt
        uint256[] memory params = new uint256[](3);
        params[0] = 1;      // tokenId
        params[1] = 12345;  // publicKey
        params[2] = 67890;  // salt

        vault.deposit(params);

        // Verify reentrancy was attempted
        assertTrue(
            reentrantTeleport.reentrancyAttempted(),
            "reentrancy should have been attempted by MockReentrantDvpTeleport"
        );

        // CRITICAL ASSERTION: reentrancy must NOT succeed
        // Before fix: reentrancySucceeded = true  → this assertion FAILS
        // After fix:  reentrancySucceeded = false → this assertion PASSES
        assertFalse(
            reentrantTeleport.reentrancySucceeded(),
            "REENTRANCY VULNERABILITY: deposit() was re-entered during DvpTeleport callback. "
            "A malicious DvpTeleport can insert extra commitments into the merkle tree mid-transaction, "
            "breaking integrity invariants and potentially enabling double-spend attacks. "
            "Fix: add nonReentrant modifier to deposit()."
        );
    }

    /**
     * @notice Normal deposit (no reentrancy) should still work after fix
     * @dev Verifies that the nonReentrant modifier doesn't break normal operation
     */
    function test_deposit_normal_operation_succeeds() public {
        // Teleport NOT armed - no reentrancy attempt
        uint256[] memory params = new uint256[](3);
        params[0] = 1;
        params[1] = 12345;
        params[2] = 67890; // salt

        bool success = vault.deposit(params);
        assertTrue(success, "normal deposit should succeed");
    }
}


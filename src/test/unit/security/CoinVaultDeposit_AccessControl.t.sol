// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Erc721CoinVault} from "../../../rayls-protocol/Enygma/Enygma-DVP/Erc721CoinVault.sol";
import {Erc1155CoinVault} from "../../../rayls-protocol/Enygma/Enygma-DVP/Erc1155CoinVault.sol";
import {MockPoseidonWrapper} from "../mocks/MockPoseidonWrapper.sol";
import {MockDvpTeleport} from "../mocks/MockDvpTeleport.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title Issue #303 — CoinVault.deposit public custody bypass (NFT theft)
 * @notice https://github.com/raylsnetwork/rayls-privacy-contracts/issues/303
 *
 * VULNERABILITY (P0 / Critical):
 *   `Erc721CoinVault.deposit` and the single-token branch of `Erc1155CoinVault.deposit`
 *   are `public` with NO `restricted` modifier, and `deposit.selector` is NOT registered
 *   in the vault's `DVP_CONTRACT` SelectorRoleMapping. `deposit` transfers NO asset — it
 *   trusts that `Dvp.depositERC721 / Dvp.depositERC1155` already moved the token into the
 *   vault (Dvp.sol:435 / Dvp.sol:473) before delegating to the vault. Because the call is
 *   unauthenticated, ANY EOA can insert a Poseidon commitment built from caller-controlled
 *   inputs WITHOUT depositing an asset. The attacker later withdraws a victim's custodied
 *   token with a valid ZK ownership proof for the leaf they fabricated (they know its
 *   opening), because the circuit only attests Merkle membership + knowledge of the opening
 *   — nothing enforces `#commitments-per-asset == #assets-custodied`.
 *
 * REFERENCE (correct design already in-tree):
 *   `EnygmaCoinVault` gates deposit/withdraw/transfer with `restricted` AND registers those
 *   selectors in DVP_CONTRACT (EnygmaCoinVault.sol:66-68), with natspec:
 *   "DVP-restricted (unlike ERC20/721/1155 vaults). Only callable via Dvp.depositEnygma()."
 *
 * FIX (do NOT apply here — asserted by these tests):
 *   Add `restricted` to `Erc721CoinVault.deposit` and `Erc1155CoinVault.deposit`, and add
 *   `this.deposit.selector` to the DVP_CONTRACT `dvpSels` set in both constructors, so only
 *   the Dvp contract (holder of DVP_CONTRACT) can invoke deposit — coupling commitment
 *   creation with the asset transfer that Dvp already performs.
 *
 * TEST CONTRACT (the "fails-when-vuln / passes-when-fixed" security assertion):
 *   - test_deposit_directCallByAttacker_mustRevert:
 *       An unauthorized EOA calling `vault.deposit(...)` directly MUST revert with
 *       RaylsAccessManaged__Unauthorized.
 *       * VULNERABLE (current):  deposit has no `restricted` → the call SUCCEEDS →
 *         `vm.expectRevert` is not satisfied → test FAILS (RED). Issue confirmed.
 *       * FIXED:                 deposit is DVP-gated → the call reverts Unauthorized →
 *         test PASSES (GREEN).
 *   - test_deposit_viaDvpRoleHolder_succeeds (regression guard):
 *       The legitimate DVP caller (holder of DVP_CONTRACT) can still deposit. GREEN before
 *       AND after the fix — ensures the fix does not over-restrict the intended path.
 */

// ─────────────────────────────────────────────────────────────────────────────
//  ERC721 vault
// ─────────────────────────────────────────────────────────────────────────────
contract Erc721CoinVaultDepositAccessControlTest is Test {
    Erc721CoinVault internal vault;
    MockPoseidonWrapper internal poseidon;
    MockDvpTeleport internal teleport;
    RaylsAccessManagerV1 internal manager;

    address internal dvpContract; // holds DVP_CONTRACT role (stands in for the Dvp facade)
    address internal attacker;

    uint256 internal constant VICTIM_NFT_ID = 7;

    function setUp() public {
        dvpContract = address(this);
        attacker = makeAddr("attacker");

        poseidon = new MockPoseidonWrapper();
        teleport = new MockDvpTeleport();

        // RaylsAccessManagerV1 is UUPS — deploy impl + ERC1967Proxy, never `new` directly.
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(this)))))
        );

        // Role must exist BEFORE the vault constructor self-registers its selectors by name.
        manager.registerRole("DVP_CONTRACT");

        vault = new Erc721CoinVault(
            dvpContract, // dvpContractAddress
            address(teleport), // dvpTeleportAddress
            address(poseidon), // poseidonWrapperAddress
            8, // treeDepth (unused in ctor)
            address(manager) // authority_
        );

        // Grant DVP_CONTRACT to the legitimate caller (the Dvp facade stand-in).
        uint64 dvpRole = manager.getRoleIdByName("DVP_CONTRACT");
        manager.grantRole(dvpRole, dvpContract, 0);

        // initializeVault is `restricted`; dvpContract now holds the role.
        vault.initializeVault(
            1, // vaultId
            makeAddr("nftAsset"), // assetContractAddress
            8, // treeDepth (2^8 = 256 leaves)
            address(poseidon), // hashContractAddress
            address(0), // verifierContractAddress (deposit does not use it)
            address(0) // zkAuctionContractAddress
        );
    }

    /// @dev Attacker fabricates a commitment for a victim-custodied NFT without transferring anything.
    ///      Params: [tokenId, spendPK, salt]  (Erc721CoinVault.sol:86-88)
    function test_deposit_directCallByAttacker_mustRevert() public {
        uint256[] memory params = new uint256[](3);
        params[0] = VICTIM_NFT_ID; // NFT already custodied by an honest deposit
        params[1] = uint256(uint160(attacker)); // attacker-controlled spendPK
        params[2] = 0xA11CE; // attacker-controlled salt

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        vault.deposit(params);
    }

    /// @dev Regression: the authorized DVP path (Dvp already moved the NFT) must keep working.
    function test_deposit_viaDvpRoleHolder_succeeds() public {
        uint256[] memory params = new uint256[](3);
        params[0] = VICTIM_NFT_ID;
        params[1] = uint256(uint160(makeAddr("victim")));
        params[2] = 0xBEEF;

        // Caller is dvpContract (address(this)), which holds DVP_CONTRACT.
        bool ok = vault.deposit(params);
        assertTrue(ok, "authorized DVP deposit must succeed");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
//  ERC1155 vault (single-token branch: params.length == 4 — no transfer performed)
// ─────────────────────────────────────────────────────────────────────────────
contract Erc1155CoinVaultDepositAccessControlTest is Test {
    Erc1155CoinVault internal vault;
    MockPoseidonWrapper internal poseidon;
    MockDvpTeleport internal teleport;
    RaylsAccessManagerV1 internal manager;

    address internal dvpContract;
    address internal attacker;

    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant AMOUNT = 50;

    function setUp() public {
        dvpContract = address(this);
        attacker = makeAddr("attacker");

        poseidon = new MockPoseidonWrapper();
        teleport = new MockDvpTeleport();

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (address(this)))))
        );

        manager.registerRole("DVP_CONTRACT");

        vault = new Erc1155CoinVault(
            dvpContract, // dvpContractAddress
            address(teleport), // dvpTeleportAddress
            address(poseidon), // poseidonWrapperAddress
            8, // treeDepth (unused in ctor)
            address(manager) // authority_
        );

        uint64 dvpRole = manager.getRoleIdByName("DVP_CONTRACT");
        manager.grantRole(dvpRole, dvpContract, 0);

        vault.initializeVault(
            1, // vaultId
            makeAddr("erc1155Asset"), // assetContractAddress
            8, // treeDepth
            address(poseidon), // hashContractAddress
            address(0), // verifierContractAddress
            address(0) // zkAuctionContractAddress
        );
    }

    /// @dev Single-token deposit params: [amountOrOne, tokenId, spendPK, salt] (Erc1155CoinVault.sol:109-112).
    ///      This branch (length == 4) skips the token transfer, so an attacker can insert an
    ///      unbacked commitment exactly as in the ERC721 case.
    function test_deposit_directCallByAttacker_mustRevert() public {
        uint256[] memory params = new uint256[](4);
        params[0] = AMOUNT; // amountOrOne
        params[1] = TOKEN_ID; // tokenId
        params[2] = uint256(uint160(attacker)); // attacker-controlled spendPK
        params[3] = 0xA11CE; // attacker-controlled salt

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        vault.deposit(params);
    }

    /// @dev The batch branch (params.length > 4, a multiple of 4) is behind the SAME `restricted`
    ///      guard: an attacker calling it directly MUST also revert Unauthorized. That branch is not
    ///      yet wired to a Dvp entry point (see Erc1155CoinVault.deposit else-branch) and is
    ///      currently unreachable, but the access guard must hold for it too — this completes the
    ///      deposit regression surface across both param shapes.
    function test_deposit_batchPath_directCallByAttacker_mustRevert() public {
        // 2-token batch, parsed by Erc1155CoinVault.deposit else-branch as
        // [tokenIds x2, amounts x2, spendPKs x2, salts x2] => length 8.
        uint256[] memory params = new uint256[](8);
        params[0] = TOKEN_ID; // tokenIds
        params[1] = TOKEN_ID + 1;
        params[2] = AMOUNT; // amounts
        params[3] = AMOUNT + 1;
        params[4] = uint256(uint160(attacker)); // spendPKs
        params[5] = uint256(uint160(attacker));
        params[6] = 0xA11CE; // salts
        params[7] = 0xB0B;

        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker)
        );
        vault.deposit(params);
    }

    /// @dev Regression: the authorized DVP path must keep working after the fix.
    function test_deposit_viaDvpRoleHolder_succeeds() public {
        uint256[] memory params = new uint256[](4);
        params[0] = AMOUNT;
        params[1] = TOKEN_ID;
        params[2] = uint256(uint160(makeAddr("victim")));
        params[3] = 0xBEEF;

        bool ok = vault.deposit(params);
        assertTrue(ok, "authorized DVP deposit must succeed");
    }
}

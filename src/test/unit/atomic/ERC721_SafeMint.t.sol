// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import "../../../rayls-protocol/test-contracts/Erc721Example.sol";
import "../../../rayls-protocol/test-contracts/Erc721DvpExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title ERC721 SafeMint Callback Tests
 * @notice Proves that ERC721 _mint() does not call onERC721Received and must be _safeMint()
 * @dev Tests FAIL before fix (when _mint is used), PASS after fix (when _safeMint is used)
 *
 * ======================================================================
 *                        THE EXPLOIT STORY
 * ======================================================================
 *
 * Acme Bank deploys a Treasury Vault smart contract on a Rayls Privacy Node.
 * The vault is designed to receive ERC721 bond tokens via cross-chain teleportation
 * from other Privacy Nodes. It implements IERC721Receiver so it can safely handle
 * incoming ERC721 tokens and execute internal accounting in onERC721Received —
 * recording the bond, updating collateral ratios, and emitting audit events.
 *
 * SCENARIO 1 — Silent accounting failure:
 *   A bond token is teleported to the vault via receiveTeleport(). Because the
 *   handler uses _mint() instead of _safeMint(), the vault's onERC721Received
 *   callback is NEVER called. The bond arrives but the vault has no record of it.
 *   Collateral ratios are wrong. Audits fail. Regulatory reporting is broken.
 *
 * SCENARIO 2 — Permanent token loss:
 *   A basic multisig contract (no IERC721Receiver) is used as the recipient.
 *   With _mint(), the token is silently minted to the multisig — but the multisig
 *   has no way to interact with ERC721 tokens. The bond is permanently stuck.
 *   With _safeMint(), this would correctly revert, preventing the loss.
 *
 * SCENARIO 3 - Reentrancy via callback (after fixing to _safeMint):
 *   A malicious contract implements onERC721Received and uses the callback to
 *   re-enter the token contract (e.g., calling teleport() to immediately send the
 *   just-minted token to another chain). The nonReentrant guard must block this.
 *
 * THE FIX: _mint() -> _safeMint() + ReentrancyGuard on all mint/teleport paths.
 * ---------------------------------------------------------------
 */

// --- Mock Contracts -------------------------------------------------

/// @notice Treasury vault that tracks onERC721Received callbacks for accounting
contract TreasuryVault is IERC721Receiver {
    bool public callbackReceived;
    uint256 public callbackCount;
    address public lastOperator;
    address public lastFrom;
    uint256 public lastTokenId;

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        callbackReceived = true;
        callbackCount++;
        lastOperator = operator;
        lastFrom = from;
        lastTokenId = tokenId;
        return IERC721Receiver.onERC721Received.selector;
    }

    function resetTracking() external {
        callbackReceived = false;
        callbackCount = 0;
    }
}

/// @notice Basic multisig contract — does NOT implement IERC721Receiver.
///         Tokens minted here via _mint() succeed silently but are PERMANENTLY STUCK.
///         Tokens minted here via _safeMint() correctly revert, preventing loss.
contract BasicMultisig {
    uint256 public value;

    function execute() external {
        value = 42;
    }
}

/// @notice Malicious contract that exploits onERC721Received to re-enter and teleport
contract MintReentrancyAttacker is IERC721Receiver {
    RaylsErc721Example public target;
    bool public attackAttempted;
    bool public attackSucceeded;

    constructor(address _target) {
        target = RaylsErc721Example(_target);
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        attackAttempted = true;
        // During the mint callback, try to teleport the token to another chain.
        // This is a reentrancy attack — should be blocked by nonReentrant.
        try target.teleport(address(0xdead), tokenId, 99999) {
            attackSucceeded = true; // BAD: reentrancy succeeded
        } catch {
            attackSucceeded = false; // GOOD: reentrancy blocked
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

/// @notice Malicious contract that exploits onERC721Received to re-enter DVP mint
contract DvpMintReentrancyAttacker is IERC721Receiver {
    Erc721DvpExample public target;
    bool public attackAttempted;
    bool public attackSucceeded;

    constructor(address _target) {
        target = Erc721DvpExample(_target);
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        attackAttempted = true;
        // Try to deposit the just-minted token into DVP during callback
        try target.depositIntoDvp(tokenId) {
            attackSucceeded = true; // BAD: reentrancy succeeded
        } catch {
            attackSucceeded = false; // GOOD: reentrancy blocked
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}

// ─── Test Contract: RaylsErc721Handler ───────────────────────────────

contract ERC721SafeMintTest is Test, IERC721Receiver {
    RaylsErc721Example public token;
    MockEndpointForSecurityTest public mockEndpoint;

    TreasuryVault public vault;
    BasicMultisig public multisig;

    address public owner;
    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);

        // Deploy AccessManager and connect to endpoint
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        mockEndpoint.setAuthority(address(manager));
        MockRaylsAppTokenRegistry registry = new MockRaylsAppTokenRegistry();
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));

        token = new RaylsErc721Example(
            "https://example.com/",
            "TestNFT",
            "TNFT",
            address(mockEndpoint),
            address(0),
            address(0)
        );

        // Activate the token: the resourceId gate in RaylsApp reverts until the
        // token registry assigns a non-zero resourceId.
        vm.prank(address(registry));
        token.setResourceId(bytes32(uint256(1)));

        vault = new TreasuryVault();
        multisig = new BasicMultisig();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // -----------------------------------------------------------------
    //  receiveTeleport() - cross-chain token arrival
    // -----------------------------------------------------------------

    /**
     * @notice receiveTeleport MUST call onERC721Received when minting to a contract
     * @dev FAILS before fix: _mint() skips the callback, vault has no record
     *      PASSES after fix: _safeMint() calls the callback, vault accounting works
     */
    function test_receiveTeleport_mustCallOnERC721Received() public {
        uint256 tokenId = 5000;

        // Teleport a bond token to the treasury vault
        token.receiveTeleport(address(vault), tokenId);

        // The vault MUST have received the onERC721Received callback
        assertTrue(vault.callbackReceived(), "EXPLOIT: onERC721Received was NOT called - vault accounting broken");
        assertEq(vault.lastTokenId(), tokenId, "Callback received wrong tokenId");
        assertEq(vault.callbackCount(), 1, "Callback should be called exactly once");
    }

    /**
     * @notice receiveTeleport MUST revert when minting to a non-receiver contract
     * @dev FAILS before fix: _mint() silently succeeds, token permanently stuck
     *      PASSES after fix: _safeMint() reverts, preventing token loss
     */
    function test_receiveTeleport_mustRevertForNonReceiver() public {
        uint256 tokenId = 5001;

        // Attempt to teleport a bond token to a basic multisig (no IERC721Receiver)
        // This MUST revert to prevent permanent token loss
        vm.expectRevert();
        token.receiveTeleport(address(multisig), tokenId);
    }

    // -----------------------------------------------------------------
    //  mint() - owner minting new tokens
    // -----------------------------------------------------------------

    /**
     * @notice mint() MUST call onERC721Received when minting to a contract
     * @dev FAILS before fix: _mint() skips callback
     *      PASSES after fix: _safeMint() calls callback
     */
    function test_mint_mustCallOnERC721Received() public {
        uint256 tokenId = 6000;

        token.mint(address(vault), tokenId);

        assertTrue(vault.callbackReceived(), "EXPLOIT: onERC721Received was NOT called on mint()");
        assertEq(vault.lastTokenId(), tokenId);
    }

    /**
     * @notice mint() MUST revert when minting to a non-receiver contract
     * @dev FAILS before fix: token silently stuck in non-receiver
     *      PASSES after fix: correctly reverts
     */
    function test_mint_mustRevertForNonReceiver() public {
        uint256 tokenId = 6001;

        vm.expectRevert();
        token.mint(address(multisig), tokenId);
    }

    // -----------------------------------------------------------------
    //  revertTeleportMint() - rollback minting
    // -----------------------------------------------------------------

    /**
     * @notice revertTeleportMint() MUST call onERC721Received
     * @dev FAILS before fix, PASSES after fix
     */
    function test_revertTeleportMint_mustCallOnERC721Received() public {
        uint256 tokenId = 7000;

        token.revertTeleportMint(address(vault), tokenId);

        assertTrue(vault.callbackReceived(), "EXPLOIT: onERC721Received NOT called on revertTeleportMint()");
        assertEq(vault.lastTokenId(), tokenId);
    }

    /**
     * @notice revertTeleportMint() MUST revert for non-receiver contracts
     * @dev FAILS before fix, PASSES after fix
     */
    function test_revertTeleportMint_mustRevertForNonReceiver() public {
        uint256 tokenId = 7001;

        vm.expectRevert();
        token.revertTeleportMint(address(multisig), tokenId);
    }

    // -----------------------------------------------------------------
    //  receiveTeleportAtomic() - atomic teleport with lock
    // -----------------------------------------------------------------

    /**
     * @notice receiveTeleportAtomic() mints to owner() — must call onERC721Received
     *         if owner() is a contract
     * @dev FAILS before fix, PASSES after fix
     *      In this test, owner() is this test contract (implements IERC721Receiver)
     */
    function test_receiveTeleportAtomic_mustCallOnERC721ReceivedOnContract() public {
        uint256 tokenId = 8000;
        address user = makeAddr("user");

        // receiveTeleportAtomic mints to address(this) (the token contract) then locks for 'to'
        token.receiveTeleportAtomic(user, tokenId);

        // Verify token was minted to the contract (vault) and locked for user
        assertEq(token.ownerOf(tokenId), address(token));
        assertTrue(token.isTokenLocked(user, tokenId));
    }

    // -----------------------------------------------------------------
    //  Reentrancy protection - callback must not allow re-entry
    // -----------------------------------------------------------------

    /**
     * @notice After fixing to _safeMint, a malicious receiver must NOT be able to
     *         re-enter the contract via onERC721Received callback
     * @dev The attacker receives a token via mint(), then in onERC721Received tries
     *      to call teleport() to immediately drain the token to another chain.
     *      With nonReentrant on mint() and teleport(), this MUST be blocked.
     *
     *      PASSES after fix: callback fires but reentrancy is blocked
     */
    function test_mint_reentrancyViaCallbackBlocked() public {
        MintReentrancyAttacker attacker = new MintReentrancyAttacker(address(token));
        uint256 tokenId = 9000;

        // Owner mints a token to the attacker contract
        token.mint(address(attacker), tokenId);

        // After _safeMint fix: callback WAS called (attack was attempted)
        assertTrue(attacker.attackAttempted(), "Callback must be called with _safeMint");
        // But the reentrancy must have been BLOCKED
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: Reentrancy via onERC721Received succeeded!");
    }

    /**
     * @notice receiveTeleport reentrancy via callback must be blocked
     */
    function test_receiveTeleport_reentrancyViaCallbackBlocked() public {
        MintReentrancyAttacker attacker = new MintReentrancyAttacker(address(token));
        uint256 tokenId = 9001;

        token.receiveTeleport(address(attacker), tokenId);

        assertTrue(attacker.attackAttempted(), "Callback must be called with _safeMint");
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: Reentrancy via receiveTeleport callback succeeded!");
    }
}

// ─── Test Contract: RaylsErc721DvpHandler ────────────────────────────

contract ERC721DvpSafeMintTest is Test, IERC721Receiver {
    Erc721DvpExample public dvpToken;
    MockEndpointForSecurityTest public mockEndpoint;
    MockRaylsAppTokenRegistry public registry;

    TreasuryVault public vault;
    BasicMultisig public multisig;

    address public owner;
    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);

        mockEndpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_CHAIN_ID);
        mockEndpoint.setTrustedExecutor(owner);

        // Deploy AccessManager and connect to endpoint
        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        RaylsAccessManagerV1 manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        mockEndpoint.setAuthority(address(manager));
        registry = new MockRaylsAppTokenRegistry();
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(registry));

        dvpToken = new Erc721DvpExample(
            "https://example.com/",
            "TestDvpNFT",
            "TDNFT",
            address(mockEndpoint)
        );

        vault = new TreasuryVault();
        multisig = new BasicMultisig();
    }

    /// @dev Activate the token by assigning a non-zero resourceId (as the token registry).
    ///      Required only by hub-gated paths (`whenHubActive`); the owner `mint()` path
    ///      intentionally stays inactive so it does not emit into an unregistered
    ///      EnygmaPNEvents contract.
    function _activate() internal {
        vm.prank(address(registry));
        dvpToken.setResourceId(bytes32(uint256(1)));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // -----------------------------------------------------------------
    //  DVP mint() - owner minting with extra data
    // -----------------------------------------------------------------

    /**
     * @notice DVP mint() MUST call onERC721Received when minting to a contract
     * @dev FAILS before fix: _mint() skips callback
     *      PASSES after fix: _safeMint() calls callback
     */
    function test_dvpMint_mustCallOnERC721Received() public {
        uint256 tokenId = 10000;
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);

        dvpToken.mint(address(vault), tokenId, extraDatas);

        assertTrue(vault.callbackReceived(), "EXPLOIT: onERC721Received NOT called on DVP mint()");
        assertEq(vault.lastTokenId(), tokenId);
    }

    /**
     * @notice DVP mint() MUST revert for non-receiver contracts
     * @dev FAILS before fix: token silently stuck
     *      PASSES after fix: correctly reverts
     */
    function test_dvpMint_mustRevertForNonReceiver() public {
        uint256 tokenId = 10001;
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);

        vm.expectRevert();
        dvpToken.mint(address(multisig), tokenId, extraDatas);
    }

    // -----------------------------------------------------------------
    //  DVP MintFromSwapDvp() - minting from DVP swap
    // -----------------------------------------------------------------

    /**
     * @notice MintFromSwapDvp() MUST call onERC721Received
     * @dev FAILS before fix: _mint() skips callback
     *      PASSES after fix: _safeMint() calls callback
     */
    function test_MintFromSwapDvp_mustCallOnERC721Received() public {
        _activate();
        uint256 tokenId = 11000;
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);

        dvpToken.MintFromSwapDvp(tokenId, address(vault), extraDatas);

        assertTrue(vault.callbackReceived(), "EXPLOIT: onERC721Received NOT called on MintFromSwapDvp()");
        assertEq(vault.lastTokenId(), tokenId);
    }

    /**
     * @notice MintFromSwapDvp() MUST revert for non-receiver contracts
     * @dev FAILS before fix: token stuck
     *      PASSES after fix: correctly reverts
     */
    function test_MintFromSwapDvp_mustRevertForNonReceiver() public {
        _activate();
        uint256 tokenId = 11001;
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(multisig)));
        dvpToken.MintFromSwapDvp(tokenId, address(multisig), extraDatas);
    }

    // -----------------------------------------------------------------
    //  DVP Reentrancy protection
    // -----------------------------------------------------------------

    /**
     * @notice DVP mint reentrancy via onERC721Received must be blocked
     * @dev Attacker tries to deposit the just-minted token into DVP during callback
     */
    function test_dvpMint_reentrancyViaCallbackBlocked() public {
        DvpMintReentrancyAttacker attacker = new DvpMintReentrancyAttacker(address(dvpToken));
        uint256 tokenId = 12000;
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);

        dvpToken.mint(address(attacker), tokenId, extraDatas);

        assertTrue(attacker.attackAttempted(), "Callback must be called with _safeMint");
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: DVP reentrancy via onERC721Received succeeded!");
    }
}

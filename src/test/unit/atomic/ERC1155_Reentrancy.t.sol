// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../../../rayls-protocol/test-contracts/Erc1155TokenExample.sol";
import "../../../rayls-protocol/test-contracts/Erc1155DvpExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title ERC1155 Reentrancy via onERC1155Received Tests
 * @notice Proves that ERC1155 _mint() calls onERC1155Received (unlike ERC721 _mint),
 *         making reentrancy ALREADY EXPLOITABLE without any code change to enable callbacks.
 * @dev Tests FAIL before fix (reentrancy succeeds), PASS after fix (nonReentrant blocks it)
 *
 * ======================================================================
 *                        THE EXPLOIT STORY
 * ======================================================================
 *
 * Unlike ERC721, OpenZeppelin's ERC1155 _mint() ALREADY calls onERC1155Received
 * on contract recipients. This means reentrancy is possible RIGHT NOW.
 *
 * SCENARIO: A malicious settlement contract receives ERC1155 bond tokens via
 * cross-chain teleportation. During the onERC1155Received callback, the attacker
 * re-enters the token contract to call teleport(), immediately sending the
 * just-minted tokens to yet another chain. Since there's no nonReentrant guard,
 * the reentrancy succeeds -- the attacker can drain tokens mid-mint.
 *
 * For the DVP handler, the attacker can deposit the just-minted tokens into DVP
 * during the callback, or trigger a swap before the outer mint completes.
 *
 * THE FIX: Add ReentrancyGuard + nonReentrant to all mint/teleport/unlock paths.
 * ======================================================================
 */

// --- Mock Contracts -------------------------------------------------

/// @notice Minimal stub for IEnygmaPNEvents so DVP handler calls don't revert
contract MockEnygmaPNEvents {
    fallback() external {}
}

/// @notice Tracks onERC1155Received callbacks for accounting verification
contract ERC1155AccountingVault is IERC1155Receiver {
    bool public callbackReceived;
    uint256 public callbackCount;
    address public lastOperator;
    address public lastFrom;
    uint256 public lastTokenId;
    uint256 public lastValue;

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata
    ) external override returns (bytes4) {
        callbackReceived = true;
        callbackCount++;
        lastOperator = operator;
        lastFrom = from;
        lastTokenId = id;
        lastValue = value;
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function resetTracking() external {
        callbackReceived = false;
        callbackCount = 0;
    }
}

/// @notice Malicious contract that exploits onERC1155Received to re-enter receiveTeleport
contract ERC1155MintReentrancyAttacker is IERC1155Receiver {
    RaylsErc1155Example public target;
    bool public attackAttempted;
    bool public attackSucceeded;
    uint256 public reentrantTokenId;

    constructor(address _target) {
        target = RaylsErc1155Example(_target);
    }

    function onERC1155Received(
        address,
        address,
        uint256 id,
        uint256,
        bytes calldata
    ) external override returns (bytes4) {
        attackAttempted = true;
        reentrantTokenId = id + 1;
        // During the mint callback, try to call receiveTeleport again
        // This is a reentrancy attack -- should be blocked by nonReentrant
        try target.teleport(address(0xdead), id, 1, 99999, "") {
            attackSucceeded = true; // BAD: reentrancy succeeded
        } catch {
            attackSucceeded = false; // GOOD: reentrancy blocked
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

/// @notice Malicious contract that exploits onERC1155Received to re-enter DVP depositIntoDvp
contract ERC1155DvpReentrancyAttacker is IERC1155Receiver {
    Erc1155DvpExample public target;
    bool public attackAttempted;
    bool public attackSucceeded;

    constructor(address _target) {
        target = Erc1155DvpExample(_target);
    }

    function onERC1155Received(
        address,
        address,
        uint256 id,
        uint256 value,
        bytes calldata
    ) external override returns (bytes4) {
        attackAttempted = true;
        // Try to deposit the just-minted tokens into DVP during callback
        try target.depositIntoDvp(id, value, "") {
            attackSucceeded = true; // BAD: reentrancy succeeded
        } catch {
            attackSucceeded = false; // GOOD: reentrancy blocked
        }
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

// --- Test Contract: RaylsErc1155Handler ---

contract ERC1155ReentrancyTest is Test, IERC1155Receiver {
    RaylsErc1155Example public token;
    MockEndpointForSecurityTest public mockEndpoint;

    ERC1155AccountingVault public vault;

    address public owner;
    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;
    uint256 constant RESOURCE_ID_SLOT = 3;

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
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(new MockRaylsAppTokenRegistry()));

        token = new RaylsErc1155Example(
            "https://example.com/",
            "TestMulti",
            address(mockEndpoint),
            address(0),
            address(0)
        );

        // Set resourceId so teleport() doesn't revert on "Token not registered" check.
        // This simulates production state where tokens ARE registered.
        vm.store(address(token), bytes32(RESOURCE_ID_SLOT), bytes32(uint256(0xABCD)));

        vault = new ERC1155AccountingVault();
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // -----------------------------------------------------------------
    //  ERC1155 _mint() already calls onERC1155Received (verify baseline)
    // -----------------------------------------------------------------

    /**
     * @notice Verify ERC1155 _mint() calls onERC1155Received (unlike ERC721)
     * @dev This should PASS even before fix -- ERC1155 _mint() always calls callback.
     *      This proves the callback vector is already active.
     */
    function test_receiveTeleport_callsOnERC1155Received() public {
        uint256 tokenId = 5000;
        uint256 amount = 100;

        token.receiveTeleport(address(vault), tokenId, amount, "");

        assertTrue(vault.callbackReceived(), "ERC1155 _mint must call onERC1155Received");
        assertEq(vault.lastTokenId(), tokenId);
        assertEq(vault.lastValue(), amount);
        assertEq(vault.callbackCount(), 1);
    }

    /**
     * @notice Verify mint() calls onERC1155Received
     */
    function test_mint_callsOnERC1155Received() public {
        uint256 tokenId = 6000;
        uint256 amount = 50;

        token.mint(address(vault), tokenId, amount, "");

        assertTrue(vault.callbackReceived(), "ERC1155 mint must call onERC1155Received");
        assertEq(vault.lastTokenId(), tokenId);
        assertEq(vault.lastValue(), amount);
    }

    /**
     * @notice Verify revertTeleportMint() calls onERC1155Received
     */
    function test_revertTeleportMint_callsOnERC1155Received() public {
        uint256 tokenId = 7000;
        uint256 amount = 25;

        token.revertTeleportMint(address(vault), tokenId, amount, "");

        assertTrue(vault.callbackReceived(), "revertTeleportMint must call onERC1155Received");
        assertEq(vault.lastTokenId(), tokenId);
    }

    // -----------------------------------------------------------------
    //  Reentrancy protection -- callback must not allow re-entry
    // -----------------------------------------------------------------

    /**
     * @notice Reentrancy via onERC1155Received on receiveTeleport must be blocked
     * @dev FAILS before fix: attacker re-enters teleport() during callback
     *      PASSES after fix: nonReentrant blocks the re-entry
     */
    function test_receiveTeleport_reentrancyBlocked() public {
        ERC1155MintReentrancyAttacker attacker = new ERC1155MintReentrancyAttacker(address(token));
        uint256 tokenId = 8000;
        uint256 amount = 100;

        token.receiveTeleport(address(attacker), tokenId, amount, "");

        // Callback WAS called (ERC1155 _mint always calls it)
        assertTrue(attacker.attackAttempted(), "Callback must be called by ERC1155 _mint");
        // But reentrancy MUST be blocked
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: Reentrancy via onERC1155Received on receiveTeleport succeeded!");
    }

    /**
     * @notice Reentrancy via onERC1155Received on mint() must be blocked
     * @dev FAILS before fix: attacker re-enters teleport() during mint callback
     *      PASSES after fix: nonReentrant blocks the re-entry
     */
    function test_mint_reentrancyBlocked() public {
        ERC1155MintReentrancyAttacker attacker = new ERC1155MintReentrancyAttacker(address(token));
        uint256 tokenId = 9000;
        uint256 amount = 50;

        token.mint(address(attacker), tokenId, amount, "");

        assertTrue(attacker.attackAttempted(), "Callback must be called by ERC1155 _mint");
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: Reentrancy via onERC1155Received on mint() succeeded!");
    }

    /**
     * @notice Reentrancy via onERC1155Received on revertTeleportMint() must be blocked
     * @dev FAILS before fix, PASSES after fix
     */
    function test_revertTeleportMint_reentrancyBlocked() public {
        ERC1155MintReentrancyAttacker attacker = new ERC1155MintReentrancyAttacker(address(token));
        uint256 tokenId = 9500;
        uint256 amount = 10;

        token.revertTeleportMint(address(attacker), tokenId, amount, "");

        assertTrue(attacker.attackAttempted(), "Callback must be called by ERC1155 _mint");
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: Reentrancy via onERC1155Received on revertTeleportMint() succeeded!");
    }
}

// --- Test Contract: RaylsErc1155DvpHandler ---

contract ERC1155DvpReentrancyTest is Test, IERC1155Receiver {
    Erc1155DvpExample public dvpToken;
    MockEndpointForSecurityTest public mockEndpoint;

    ERC1155AccountingVault public vault;

    address public owner;
    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;
    uint256 constant RESOURCE_ID_SLOT = 3;

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
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(new MockRaylsAppTokenRegistry()));

        dvpToken = new Erc1155DvpExample(
            "https://example.com/",
            "TestDvpMulti",
            address(mockEndpoint)
        );

        // Set resourceId so DVP functions don't revert on "Token not approved" check.
        vm.store(address(dvpToken), bytes32(RESOURCE_ID_SLOT), bytes32(uint256(0xABCD)));

        // Register a mock IEnygmaPNEvents so dvp1155Mint/dvp1155Burn calls don't revert
        MockEnygmaPNEvents mockEvents = new MockEnygmaPNEvents();
        mockEndpoint.registerResourceId(
            bytes32(uint256(0x02)), // Constants.RESOURCE_ID_ENYGMA_PN_EVENTS
            address(mockEvents)
        );

        vault = new ERC1155AccountingVault();
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // -----------------------------------------------------------------
    //  DVP mint() callback verification
    // -----------------------------------------------------------------

    /**
     * @notice DVP mint() calls onERC1155Received
     */
    function test_dvpMint_callsOnERC1155Received() public {
        uint256 tokenId = 10000;
        uint256 amount = 100;
        SharedObjects.Dvp1155ExtraData[] memory extraDatas = new SharedObjects.Dvp1155ExtraData[](0);

        dvpToken.mint(address(vault), tokenId, amount, "", extraDatas);

        assertTrue(vault.callbackReceived(), "DVP mint must call onERC1155Received");
        assertEq(vault.lastTokenId(), tokenId);
        assertEq(vault.lastValue(), amount);
    }

    /**
     * @notice DVP MintFromSwapDvp() calls onERC1155Received
     */
    function test_MintFromSwapDvp_callsOnERC1155Received() public {
        uint256 tokenId = 11000;
        uint256 amount = 50;
        SharedObjects.Dvp1155ExtraData[] memory extraDatas = new SharedObjects.Dvp1155ExtraData[](0);

        dvpToken.MintFromSwapDvp(tokenId, address(vault), amount, "", extraDatas);

        assertTrue(vault.callbackReceived(), "MintFromSwapDvp must call onERC1155Received");
        assertEq(vault.lastTokenId(), tokenId);
        assertEq(vault.lastValue(), amount);
    }

    // -----------------------------------------------------------------
    //  DVP Reentrancy protection
    // -----------------------------------------------------------------

    /**
     * @notice DVP mint reentrancy via onERC1155Received must be blocked
     * @dev FAILS before fix: attacker deposits into DVP during callback
     *      PASSES after fix: nonReentrant blocks re-entry
     */
    function test_dvpMint_reentrancyBlocked() public {
        ERC1155DvpReentrancyAttacker attacker = new ERC1155DvpReentrancyAttacker(address(dvpToken));
        uint256 tokenId = 12000;
        uint256 amount = 100;
        SharedObjects.Dvp1155ExtraData[] memory extraDatas = new SharedObjects.Dvp1155ExtraData[](0);

        dvpToken.mint(address(attacker), tokenId, amount, "", extraDatas);

        assertTrue(attacker.attackAttempted(), "Callback must be called by ERC1155 _mint");
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: DVP reentrancy via onERC1155Received succeeded!");
    }

    /**
     * @notice DVP MintFromSwapDvp reentrancy via onERC1155Received must be blocked
     * @dev FAILS before fix, PASSES after fix
     */
    function test_MintFromSwapDvp_reentrancyBlocked() public {
        ERC1155DvpReentrancyAttacker attacker = new ERC1155DvpReentrancyAttacker(address(dvpToken));
        uint256 tokenId = 13000;
        uint256 amount = 50;
        SharedObjects.Dvp1155ExtraData[] memory extraDatas = new SharedObjects.Dvp1155ExtraData[](0);

        dvpToken.MintFromSwapDvp(tokenId, address(attacker), amount, "", extraDatas);

        assertTrue(attacker.attackAttempted(), "Callback must be called by ERC1155 _mint");
        assertFalse(attacker.attackSucceeded(), "EXPLOIT: DVP MintFromSwapDvp reentrancy succeeded!");
    }
}

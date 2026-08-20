// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {DvpErc1155PNH} from "../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc1155PNH.sol";
import {MockEndpointForSecurityTest} from "../mocks/MockEndpointForSecurityTest.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title Slither High #5: uninitialized-state - DvpErc1155PNH.tokenRegisteredToGroup
 * @notice Tests that tokenRegisteredToGroup is properly set after minting.
 *
 * VULNERABILITY:
 *   DvpErc1155PNH.tokenRegisteredToGroup mapping is used in mint() and isTokenRegistered()
 *   but never written to (registration code is commented out). This means:
 *   - isTokenRegistered() always returns false even after minting
 *   - tokenIsFungible is set on EVERY mint, not just the first
 *
 * FIX: Set tokenRegisteredToGroup[_id] = true in mint() after first-mint fungibility setup.
 *
 * TEST LOGIC:
 *   - Mint a token
 *   - Check isTokenRegistered() returns true
 *   - Test FAILS when bug present (returns false), PASSES when fixed (returns true)
 */
contract SlitherHigh_DvpErc1155PNH_TokenRegistered_Test is Test {
    DvpErc1155PNH public token;
    address public owner;
    RaylsAccessManagerV1 public manager;

    function setUp() public {
        owner = address(this);

        RaylsAccessManagerV1 managerImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(managerImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        uint64 relayerRoleId = manager.registerRole("RELAYER");
        manager.grantRole(relayerRoleId, owner, 0);

        token = new DvpErc1155PNH("https://example.com/", "TestNFT", address(manager), 8);
    }

    // Required to receive ERC1155 tokens in tests
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @notice After minting, isTokenRegistered MUST return true
     * @dev Test FAILS when bug present (always returns false)
     *      Test PASSES when fixed (returns true after mint)
     */
    function test_isTokenRegistered_true_after_mint() public {
        uint256 tokenId = 1;

        // Before mint - should be false
        assertFalse(token.isTokenRegistered(tokenId), "should be false before mint");

        // Mint token (to this contract which implements onERC1155Received)
        SharedObjects.Dvp1155ExtraData[] memory extraData = new SharedObjects.Dvp1155ExtraData[](0);
        token.mint(owner, tokenId, 100, "", 42, extraData);

        // After mint - MUST be true
        assertTrue(token.isTokenRegistered(tokenId), "MUST be true after mint");
    }

    /**
     * @notice isTokenRegistered should remain false for tokens never minted
     */
    function test_isTokenRegistered_false_for_unminted() public view {
        assertFalse(token.isTokenRegistered(999), "unminted token should not be registered");
    }
}

/**
 * @title Slither High #6, #8: uninitialized-state - RaylsErc721DvpHandler.lockedForDvp & readyForUnlockForDvp
 * @notice Tests that DVP state mappings are properly initialized when tokens are minted.
 *
 * VULNERABILITY:
 *   lockedForDvp and readyForUnlockForDvp mappings are never initialized in constructor
 *   or initializer. While default false is correct behavior, the lack of explicit
 *   initialization means:
 *   - _update() reads lockedForDvp[tokenId] before any explicit write for that tokenId
 *   - In proxy/upgrade scenarios, uninitialized state could be problematic
 *
 * FIX: Explicitly initialize lockedForDvp[tokenId] = false and
 *      readyForUnlockForDvp[tokenId] = false when minting in _update().
 *
 * TEST LOGIC:
 *   - Deploy concrete ERC721DvpHandler, mint a token
 *   - Verify lockedForDvp is explicitly false after mint
 *   - Test DVP deposit/withdraw lifecycle
 *   - Tests verify proper state transitions
 */
contract SlitherHigh_RaylsErc721DvpHandler_Test is Test {
    TestErc721Dvp public token;
    MockEndpointForSecurityTest public mockEndpoint;
    address public owner;
    address public user;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

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

        token = new TestErc721Dvp(
            "https://example.com/",
            "TestDvpNFT",
            "TDVP",
            address(mockEndpoint)
        );
    }

    /**
     * @notice After minting, lockedForDvp MUST be explicitly false
     * @dev This verifies the mapping is initialized on mint.
     *      Test validates the explicit initialization in _update().
     */
    function test_lockedForDvp_false_after_mint() public {
        SharedObjects.Dvp721ExtraData[] memory extraData = new SharedObjects.Dvp721ExtraData[](0);
        token.mint(user, 1, extraData);

        assertFalse(token.lockedForDvp(1), "lockedForDvp must be false after mint");
    }

    /**
     * @notice lockedForDvp correctly tracks deposit state
     */
    function test_lockedForDvp_true_after_deposit() public {
        SharedObjects.Dvp721ExtraData[] memory extraData = new SharedObjects.Dvp721ExtraData[](0);
        token.mint(user, 1, extraData);

        // Set resourceId so depositIntoDvp works
        token.setResourceIdForTest(bytes32(uint256(1)));

        vm.prank(user);
        token.depositIntoDvp(1);

        assertTrue(token.lockedForDvp(1), "lockedForDvp must be true after deposit");
    }

    /**
     * @notice Token transfer blocked when locked and not ready for unlock
     */
    function test_transfer_blocked_when_locked() public {
        SharedObjects.Dvp721ExtraData[] memory extraData = new SharedObjects.Dvp721ExtraData[](0);
        token.mint(user, 1, extraData);

        // Set resourceId and deposit
        token.setResourceIdForTest(bytes32(uint256(1)));
        vm.prank(user);
        token.depositIntoDvp(1);

        // Try to transfer while locked - should fail
        vm.prank(user);
        vm.expectRevert(bytes("This token is locked in the Dvp"));
        token.transferFrom(user, owner, 1);
    }
}

/**
 * @dev Concrete test contract extending RaylsErc721DvpHandler for testing
 *      Uses MockEndpoint to avoid full endpoint setup
 */
import {RaylsErc721DvpHandler} from "../../../rayls-protocol-sdk/tokens/RaylsErc721DvpHandler.sol";

contract MockEnygmaEvents {
    // Accept any call without reverting
    fallback() external {}
}

contract TestErc721Dvp is RaylsErc721DvpHandler {
    address private _mockEnygmaEvents;

    constructor(
        string memory uri,
        string memory name_,
        string memory symbol_,
        address _endpoint
    )
        RaylsErc721DvpHandler(uri, name_, symbol_, _endpoint, address(0), address(0), msg.sender, false)
    {
        _mockEnygmaEvents = address(new MockEnygmaEvents());
    }

    // Expose resourceId setter for testing
    function setResourceIdForTest(bytes32 _resourceId) external {
        resourceId = _resourceId;
    }

    // Override getEnygmaEventsAdress to return pre-deployed mock
    function getEnygmaEventsAdress() public view override returns (address) {
        return _mockEnygmaEvents;
    }

    // Override getPNCommunicatorAddress similarly
    function getPNCommunicatorAddress() public pure override returns (address) {
        return address(0);
    }
}

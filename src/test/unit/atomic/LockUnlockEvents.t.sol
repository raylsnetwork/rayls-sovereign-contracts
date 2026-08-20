// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../../../rayls-protocol/test-contracts/TokenExample.sol";
import "../../../rayls-protocol/test-contracts/Erc721Example.sol";
import "../../../rayls-protocol/test-contracts/Erc1155TokenExample.sol";
import "../../../rayls-protocol/test-contracts/Erc721DvpExample.sol";
import "../../../rayls-protocol/test-contracts/Erc1155DvpExample.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";

/**
 * @title Lock/Unlock Events Test
 * @notice Tests that lock and unlock operations emit the correct events
 * @dev Covers all 5 token handlers: ERC20, ERC721, ERC1155, ERC721Dvp, ERC1155Dvp
 */
contract LockUnlockEventsTest is Test, IERC721Receiver, IERC1155Receiver {
    MockEndpointForSecurityTest public mockEndpoint;

    TokenExample public erc20Token;
    RaylsErc721Example public erc721Token;
    RaylsErc1155Example public erc1155Token;
    Erc721DvpExample public erc721DvpToken;
    Erc1155DvpExample public erc1155DvpToken;

    address public owner;
    address public user;

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_CHAIN_ID = 99999;

    function setUp() public {
        owner = address(this);
        user = makeAddr("user");

        // Deploy mock endpoint
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

        // Deploy ERC20
        erc20Token = new TokenExample(
            "TestERC20", "T20",
            address(mockEndpoint), address(0), address(0)
        );

        // Deploy ERC721
        erc721Token = new RaylsErc721Example(
            "https://example.com/", "TestERC721", "T721",
            address(mockEndpoint), address(0), address(0)
        );

        // Deploy ERC1155
        erc1155Token = new RaylsErc1155Example(
            "https://example.com/", "TestERC1155",
            address(mockEndpoint), address(0), address(0)
        );

        // Deploy ERC721 DVP
        erc721DvpToken = new Erc721DvpExample(
            "https://example.com/", "TestERC721Dvp", "T721D",
            address(mockEndpoint)
        );

        // Deploy ERC1155 DVP
        erc1155DvpToken = new Erc1155DvpExample(
            "https://example.com/", "TestERC1155Dvp",
            address(mockEndpoint)
        );

        // Activate tokens: hub-gated lock/unlock paths (`whenHubActive`) revert until
        // the token registry assigns a non-zero resourceId.
        vm.startPrank(address(registry));
        erc20Token.setResourceId(bytes32(uint256(1)));
        erc721Token.setResourceId(bytes32(uint256(1)));
        erc1155Token.setResourceId(bytes32(uint256(1)));
        vm.stopPrank();
    }

    // ERC721Receiver and ERC1155Receiver implementations so this contract can receive NFTs
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId ||
               interfaceId == type(IERC1155Receiver).interfaceId ||
               interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 LOCK/UNLOCK EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_erc20_lockEmitsTokensLocked() public {
        // receiveTeleportAtomic mints to owner then calls _lockInternal for user
        // which should emit TokensLocked
        uint256 amount = 100;

        vm.expectEmit(true, false, false, true, address(erc20Token));
        emit RaylsErc20Handler.TokensLocked(user, amount);

        // receiveTeleportAtomic: mints to owner(), then _lockInternal(to, value, false)
        erc20Token.receiveTeleportAtomic(user, amount);
    }

    function test_erc20_unlockEmitsTokensUnlocked() public {
        uint256 amount = 100;

        // First lock via receiveTeleportAtomic
        erc20Token.receiveTeleportAtomic(user, amount);

        // Now unlock should emit TokensUnlocked
        vm.expectEmit(true, false, false, true, address(erc20Token));
        emit RaylsErc20Handler.TokensUnlocked(user, amount);

        erc20Token.unlock(user, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        ERC721 LOCK/UNLOCK EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_erc721_lockEmitsTokenLocked() public {
        uint256 newTokenId = 999;

        vm.expectEmit(true, true, false, true, address(erc721Token));
        emit RaylsErc721Handler.TokenLocked(user, newTokenId);

        erc721Token.receiveTeleportAtomic(user, newTokenId);
    }

    function test_erc721_unlockEmitsTokenUnlocked() public {
        uint256 newTokenId = 999;

        // Lock first
        erc721Token.receiveTeleportAtomic(user, newTokenId);

        // Now unlock should emit TokenUnlocked
        vm.expectEmit(true, true, false, true, address(erc721Token));
        emit RaylsErc721Handler.TokenUnlocked(user, newTokenId);

        erc721Token.unlock(user, newTokenId);
    }

    /*//////////////////////////////////////////////////////////////
                       ERC1155 LOCK/UNLOCK EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_erc1155_lockEmitsTokensLocked() public {
        uint256 tokenId = 10;
        uint256 amount = 50;

        vm.expectEmit(true, true, false, true, address(erc1155Token));
        emit RaylsErc1155Handler.TokensLocked(user, tokenId, amount);

        erc1155Token.receiveTeleportAtomic(user, tokenId, amount, "");
    }

    function test_erc1155_unlockEmitsTokensUnlocked() public {
        uint256 tokenId = 10;
        uint256 amount = 50;

        // Lock first
        erc1155Token.receiveTeleportAtomic(user, tokenId, amount, "");

        // Now unlock should emit TokensUnlocked
        vm.expectEmit(true, true, false, true, address(erc1155Token));
        emit RaylsErc1155Handler.TokensUnlocked(user, tokenId, amount);

        erc1155Token.unlock(user, tokenId, amount, "");
    }

}

/**
 * @title DVP Lock/Unlock Events Test with Helper Contracts
 * @notice Uses helper contracts that expose internal _lock/_unlock for testing
 */

contract TestableErc721Dvp is Erc721DvpExample {
    constructor(string memory baseUri, string memory name, string memory symbol, address _endpoint)
        Erc721DvpExample(baseUri, name, symbol, _endpoint)
    {}

    function exposedLock(address to, uint256 id) external {
        _lock(to, id);
    }

    function exposedUnlock(address to, uint256 id) external returns (bool) {
        return _unlock(to, id);
    }
}

contract TestableErc1155Dvp is Erc1155DvpExample {
    constructor(string memory baseUri, string memory name, address _endpoint)
        Erc1155DvpExample(baseUri, name, _endpoint)
    {}

    function exposedLock(address to, uint256 id) external {
        _lock(to, id);
    }

    function exposedUnlock(address to, uint256 id) external returns (bool) {
        return _unlock(to, id);
    }
}

contract DvpLockUnlockEventsTest is Test {
    MockEndpointForSecurityTest public mockEndpoint;
    TestableErc721Dvp public erc721DvpToken;
    TestableErc1155Dvp public erc1155DvpToken;

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

        erc721DvpToken = new TestableErc721Dvp(
            "https://example.com/", "TestERC721Dvp", "T721D",
            address(mockEndpoint)
        );

        erc1155DvpToken = new TestableErc1155Dvp(
            "https://example.com/", "TestERC1155Dvp",
            address(mockEndpoint)
        );
    }

    /*//////////////////////////////////////////////////////////////
                     ERC721 DVP LOCK/UNLOCK EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_erc721Dvp_lockEmitsTokenLocked() public {
        // Mint token to user
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);
        erc721DvpToken.mint(user, 1, extraDatas);

        vm.expectEmit(true, true, false, true, address(erc721DvpToken));
        emit RaylsErc721DvpHandler.TokenLocked(user, 1);

        erc721DvpToken.exposedLock(user, 1);
    }

    function test_erc721Dvp_unlockEmitsTokenUnlocked() public {
        // Mint and lock
        SharedObjects.Dvp721ExtraData[] memory extraDatas = new SharedObjects.Dvp721ExtraData[](0);
        erc721DvpToken.mint(user, 1, extraDatas);
        erc721DvpToken.exposedLock(user, 1);

        vm.expectEmit(true, true, false, true, address(erc721DvpToken));
        emit RaylsErc721DvpHandler.TokenUnlocked(user, 1);

        erc721DvpToken.exposedUnlock(user, 1);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC1155 DVP LOCK/UNLOCK EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_erc1155Dvp_lockEmitsTokenLocked() public {
        // Mint tokens first
        erc1155DvpToken.mint(
            user, 1, 100, "",
            new SharedObjects.Dvp1155ExtraData[](0)
        );

        vm.expectEmit(true, true, false, true, address(erc1155DvpToken));
        emit RaylsErc1155DvpHandler.TokenLocked(user, 1);

        erc1155DvpToken.exposedLock(user, 1);
    }

    function test_erc1155Dvp_unlockEmitsTokenUnlocked() public {
        // Mint and lock
        erc1155DvpToken.mint(
            user, 1, 100, "",
            new SharedObjects.Dvp1155ExtraData[](0)
        );
        erc1155DvpToken.exposedLock(user, 1);

        vm.expectEmit(true, true, false, true, address(erc1155DvpToken));
        emit RaylsErc1155DvpHandler.TokenUnlocked(user, 1);

        erc1155DvpToken.exposedUnlock(user, 1);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RaylsPublicApp} from "../RaylsPublicApp.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {RaylsNodeBridgedTransferMetadata, RaylsNodeBridgeableERC} from "../../rayls-privacy-node/RNMessageLib.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

/**
 * @title RaylsPublicERC721Handler
 * @notice Handles ERC721 token operations for cross-chain bridging in Rayls Network
 * @dev Abstract contract that manages NFT burning/minting for cross-chain transfers
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
abstract contract RaylsPublicERC721Handler is RaylsPublicApp, ERC721 {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RaylsPublicERC721Handler__CallerIsNotOwnerNorApproved();
    error RaylsPublicERC721Handler__DestinationIsZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when this ERC721 public chain token contract is created
    /// @param tokenAddress The address of the newly created token contract
    event RaylsPublicErc721TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    string private _uri;
    string private _tokenName;
    string private _tokenSymbol;
    address private privateAddress;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Rayls Public ERC721 Handler
     * @param uri Base URI for token metadata
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param _raylsNodeEndpoint Address of the Rayls Node endpoint
     * @param _owner Owner address
     * @param _privateAddress Corresponding private chain address
     */
    constructor(
        string memory uri,
        string memory name_,
        string memory symbol_,
        address _raylsNodeEndpoint,
        address _owner,
        address _privateAddress
    )
        ERC721(name_, symbol_)
        RaylsPublicApp(_raylsNodeEndpoint)
    {
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _uri = uri;
        privateAddress = _privateAddress;
        _registerAccessControl(_owner);
        emit RaylsPublicErc721TokenCreated(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burns NFT on public chain and initiates cross-chain unlock on private chain
     * @param to Recipient address on private chain
     * @param tokenId Token ID to burn
     * @param chainId Destination chain ID
     * @return bool Success status
     */
    function teleportToPrivacyNode(address to, uint256 tokenId, uint256 chainId) external virtual returns (bool) {
        if (to == address(0)) {
            revert RaylsPublicERC721Handler__DestinationIsZeroAddress();
        }
        address tokenOwner = ownerOf(tokenId);
        if (!_isAuthorized(tokenOwner, msg.sender, tokenId)) {
            revert ERC721InsufficientApproval(msg.sender, tokenId);
        }

        _burn(tokenId);

        RaylsNodeBridgedTransferMetadata memory transferMetadata = RaylsNodeBridgedTransferMetadata({
            assetType: RaylsNodeBridgeableERC.ERC721,
            id: tokenId,
            from: msg.sender,
            to: to,
            amount: 1,
            tokenAddress: address(this)
        });

        publicRaylsNodeEndpoint.sendToAddress(
            chainId,
            privateAddress,
            abi.encodeWithSignature("receiveTeleportFromPublicChain(address,uint256)", to, tokenId),
            abi.encodeWithSignature("revertTeleportToPrivacyNode(address,uint256)", tokenOwner, tokenId),
            transferMetadata
        );
        return true;
    }

    /**
     * @notice Mints NFT on public chain (called from private chain)
     * @dev If `to` is the zero address the mint cannot proceed; instead an explicit callback is sent
     *      back to the private chain via the public endpoint so the relayer can restore the locked token.
     * @param from Original sender on the private chain (used to restore the lock on failure)
     * @param srcChainId Private chain ID (destination for the restore callback)
     * @param to Recipient address on the public chain
     * @param tokenId Token ID to mint
     */
    function receiveTeleportFromPrivacyNode(address from, uint256 srcChainId, address to, uint256 tokenId) external virtual restricted {
        if (to == address(0)) {
            RaylsNodeBridgedTransferMetadata memory transferMetadata = RaylsNodeBridgedTransferMetadata({
                assetType: RaylsNodeBridgeableERC.ERC721,
                id: tokenId,
                from: from,
                tokenAddress: address(this),
                to: from,
                amount: 1
            });
            publicRaylsNodeEndpoint.sendToAddress(
                srcChainId,
                privateAddress,
                abi.encodeWithSignature("revertTeleportToPublicChain(address,uint256)", from, tokenId),
                bytes(""),
                transferMetadata
            );
            return;
        }
        _mint(to, tokenId);
    }

    /**
     * @notice Reverts a failed cross-chain burn by minting the NFT back
     * @dev Called when cross-chain transaction fails on destination chain
     * @param to Address to mint token back to
     * @param tokenId Token ID to mint
     */
    function revertTeleportToPrivacyNode(address to, uint256 tokenId) external virtual restricted {
        _mint(to, tokenId);
    }

    /**
     * @notice Mints NFT (owner only)
     * @param to Recipient address
     * @param tokenId Token ID to mint
     */
    function mint(address to, uint256 tokenId) external virtual restricted {
        _mint(to, tokenId);
    }

    /**
     * @notice Burns NFT (owner only)
     * @param tokenId Token ID to burn
     */
    function burn(uint256 tokenId) external virtual restricted {
        _burn(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the token name
     * @return Token name
     */
    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    /**
     * @notice Returns the token symbol
     * @return Token symbol
     */
    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the base URI for token metadata
     * @return Base URI string
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _uri;
    }

    function _registerAccessControl(address _owner) internal {
        address mgr = address(publicRaylsNodeEndpoint) != address(0) ? publicRaylsNodeEndpoint.authority() : address(0);
        if (mgr == address(0)) return;

        bytes4[] memory ownerSels = new bytes4[](2);
        ownerSels[0] = this.mint.selector;
        ownerSels[1] = this.burn.selector;

        bytes4[] memory executorSels = new bytes4[](2);
        executorSels[0] = this.receiveTeleportFromPrivacyNode.selector;
        executorSels[1] = this.revertTeleportToPrivacyNode.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);
    }
}

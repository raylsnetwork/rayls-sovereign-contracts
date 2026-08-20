// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RaylsPublicApp} from "../RaylsPublicApp.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {RaylsNodeBridgedTransferMetadata, RaylsNodeBridgeableERC} from "../../rayls-privacy-node/RNMessageLib.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

/**
 * @title RaylsPublicERC1155Handler
 * @notice Handles ERC1155 multi-token operations for cross-chain bridging in Rayls Network
 * @dev Abstract contract that manages token burning/minting for cross-chain transfers
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
abstract contract RaylsPublicERC1155Handler is RaylsPublicApp, ERC1155 {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RaylsPublicERC1155Handler__DestinationIsZeroAddress();
    error RaylsPublicERC1155Handler__AmountMustBeGreaterThanZero();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when this ERC1155 public chain token contract is created
    /// @param tokenAddress The address of the newly created token contract
    event RaylsPublicErc1155TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    string private _uri;
    string public name;
    address private privateAddress;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Rayls Public ERC1155 Handler
     * @param uri_ Base URI for token metadata
     * @param _name Token collection name
     * @param _raylsNodeEndpoint Address of the Rayls Node endpoint
     * @param _owner Owner address
     * @param _privateAddress Corresponding private chain address
     */
    constructor(
        string memory uri_,
        string memory _name,
        address _raylsNodeEndpoint,
        address _owner,
        address _privateAddress
    )
        ERC1155(uri_)
        RaylsPublicApp(_raylsNodeEndpoint)
    {
        _uri = uri_;
        name = _name;
        privateAddress = _privateAddress;
        _registerAccessControl(_owner);
        emit RaylsPublicErc1155TokenCreated(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burns tokens on public chain and initiates cross-chain unlock on private chain
     * @param to Recipient address on private chain
     * @param id Token ID to burn
     * @param amount Amount of tokens to burn
     * @param chainId Destination chain ID
     * @return bool Success status
     */
    function teleportToPrivacyNode(address to, uint256 id, uint256 amount, uint256 chainId)
        external
        virtual
        returns (bool)
    {
        if (to == address(0)) {
            revert RaylsPublicERC1155Handler__DestinationIsZeroAddress();
        }
        if (amount == 0) {
            revert RaylsPublicERC1155Handler__AmountMustBeGreaterThanZero();
        }
        _burn(msg.sender, id, amount);

        RaylsNodeBridgedTransferMetadata memory transferMetadata = RaylsNodeBridgedTransferMetadata({
            assetType: RaylsNodeBridgeableERC.ERC1155,
            id: id,
            from: msg.sender,
            to: to,
            amount: amount,
            tokenAddress: address(this)
        });

        publicRaylsNodeEndpoint.sendToAddress(
            chainId,
            privateAddress,
            abi.encodeWithSignature("receiveTeleportFromPublicChain(address,uint256,uint256)", to, id, amount),
            abi.encodeWithSignature("revertTeleportToPrivacyNode(address,uint256,uint256)", msg.sender, id, amount),
            transferMetadata
        );
        return true;
    }

    /**
     * @notice Mints tokens on public chain (called from private chain)
     * @dev If `to` is the zero address the mint cannot proceed; instead an explicit callback is sent
     *      back to the private chain via the public endpoint so the relayer can restore the locked tokens.
     * @param from Original sender on the private chain (used to restore the lock on failure)
     * @param srcChainId Private chain ID (destination for the restore callback)
     * @param to Recipient address on the public chain
     * @param id Token ID to mint
     * @param amount Amount of tokens to mint
     * @param data Additional data for the mint
     */
    function receiveTeleportFromPrivacyNode(address from, uint256 srcChainId, address to, uint256 id, uint256 amount, bytes memory data) external virtual restricted {
        if (to == address(0)) {
            RaylsNodeBridgedTransferMetadata memory transferMetadata = RaylsNodeBridgedTransferMetadata({
                assetType: RaylsNodeBridgeableERC.ERC1155,
                id: id,
                from: from,
                tokenAddress: address(this),
                to: from,
                amount: amount
            });
            publicRaylsNodeEndpoint.sendToAddress(
                srcChainId,
                privateAddress,
                abi.encodeWithSignature("revertTeleportToPublicChain(address,uint256,uint256)", from, id, amount),
                bytes(""),
                transferMetadata
            );
            return;
        }
        _mint(to, id, amount, data);
    }

    /**
     * @notice Reverts a failed cross-chain burn by minting tokens back
     * @dev Called when cross-chain transaction fails on destination chain
     * @param to Address to mint tokens back to
     * @param id Token ID to mint
     * @param amount Amount of tokens to mint
     */
    function revertTeleportToPrivacyNode(address to, uint256 id, uint256 amount) external virtual restricted {
        _mint(to, id, amount, "");
    }

    /**
     * @notice Mints tokens (owner only)
     * @param to Recipient address
     * @param id Token ID to mint
     * @param amount Amount of tokens to mint
     * @param data Additional data for the mint
     */
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external virtual restricted {
        _mint(to, id, amount, data);
    }

    /**
     * @notice Mints multiple token types in batch (owner only)
     * @param to Recipient address
     * @param ids Array of token IDs to mint
     * @param amounts Array of amounts to mint
     * @param data Additional data for the mint
     */
    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external virtual restricted {
        _mintBatch(to, ids, amounts, data);
    }

    /**
     * @notice Burns tokens (owner only)
     * @param from Address to burn tokens from
     * @param id Token ID to burn
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 id, uint256 amount) external virtual restricted {
        _burn(from, id, amount);
    }

    /**
     * @notice Burns multiple token types in batch (owner only)
     * @param from Address to burn tokens from
     * @param ids Array of token IDs to burn
     * @param amounts Array of amounts to burn
     */
    function burnBatch(
        address from,
        uint256[] memory ids,
        uint256[] memory amounts
    ) external virtual restricted {
        _burnBatch(from, ids, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the URI for a token type
     * @return Token metadata URI
     */
    function uri(uint256 /*id*/) public view virtual override returns (string memory) {
        return _uri;
    }

    /**
     * @notice Checks interface support
     * @param interfaceId Interface identifier
     * @return Whether the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Sets the URI for all token types
     * @param newuri New URI to set
     */
    function _setURI(string memory newuri) internal virtual override {
        _uri = newuri;
    }

    function _registerAccessControl(address _owner) internal {
        address mgr = address(publicRaylsNodeEndpoint) != address(0) ? publicRaylsNodeEndpoint.authority() : address(0);
        if (mgr == address(0)) return;

        bytes4[] memory ownerSels = new bytes4[](4);
        ownerSels[0] = this.mint.selector;
        ownerSels[1] = this.mintBatch.selector;
        ownerSels[2] = this.burn.selector;
        ownerSels[3] = this.burnBatch.selector;

        bytes4[] memory executorSels = new bytes4[](2);
        executorSels[0] = this.receiveTeleportFromPrivacyNode.selector;
        executorSels[1] = this.revertTeleportToPrivacyNode.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](1);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);
    }
}

//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../libraries/SharedObjects.sol';

interface IEnygmaPNEvents {
    /**
     * @dev Emits an event when minting Enygma tokens
     * @param resourceId The resource ID of the Enygma token
     * @param to The address to mint the tokens to
     * @param amount The amount to mint
     */
    function mint(bytes32 resourceId, address to, uint256 amount) external;

    /**
     * @dev Emits an event when burning Enygma tokens
     * @param resourceId The resource ID of the Enygma token
     * @param from The address to burn the tokens from
     * @param amount The amount to burn
     */
    function burn(bytes32 resourceId, address from, uint256 amount) external;

    /**
     * @dev Emits an event when creating an Enygma token
     * @param resourceId The resource ID of the Enygma token
     */
    function creation(bytes32 resourceId, uint256 initialSupply) external;

    /**
     * @dev Emits an event when receiving a transfer in PN
     * @param _pnhTransfer Encrypted transfer data
     */
    function sendTransferPNH(SharedObjects.PNHTransfer memory _pnhTransfer) external;

    /**
     * @dev Emits an event when a mint is reverted
     * @param resourceId The resource ID of the Enygma token
     * @param amount The amount that was to be minted
     * @param to The intended recipient
     * @param reason The reason for the revert
     */
    function revertMint(bytes32 resourceId, uint256 amount, address to, string memory reason) external;

    /**
     * @dev Emits an event when depositing to Dvp
     * @param resourceId The resource ID of the Enygma token
     * @param amount The amount to deposit
     * @param from The sender address
     * @param referenceId Reference ID for the deposit
     */
    function depositToDvp(bytes32 resourceId, uint256 amount, address from, bytes32 referenceId) external;

       /**
     * @dev Emits an event when depositing to Dvp
     * @param resourceId The resource ID of the Enygma token
     * @param amount The amount to deposit
     * @param to The caller and receiver address
     * @param referenceId Reference ID for the withdraw
     */
    function withdrawFromDvp(bytes32 resourceId, uint256 amount, address to, bytes32 referenceId) external;


    /**
     * @dev Emits an event when swapping ERC721 tokens
     * @param resourceId The resource ID of the Enygma token
     * @param nftId The ID of the ERC721 token
     * @param nftResourceId The resource ID of the ERC721 token
     * @param enygmaAmount The amount of Enygma tokens to swap
     * @param from The address of the sender
     * @param destChainId The chain ID of the destination chain
     * @param sharedId The shared ID of the swap
     * @param validityTime The validity time for the swap
     */
    // add To address
    function swapWithDvpForERC721(
        bytes32 resourceId,
        uint256 nftId,
        bytes32 nftResourceId,
        uint256 enygmaAmount,
        address from,
        uint256 destChainId,
        bytes32 sharedId,
        uint64 validityTime
    ) external;


    /**
     * @dev Emits an event when swapping ERC1155 tokens
     * @param resourceId The resource ID of the Enygma token
     * @param nftId The ID of the ERC1155 token
     * @param nftResourceId The resource ID of the ERC1155 token
     * @param nftAmountOrOne The amount of ERC1155 tokens to swap
     * @param enygmaAmount The amount of Enygma tokens to swap
     * @param from The address of the sender
     * @param destChainId The chain ID of the destination chain
     * @param sharedId The shared ID of the swap
     * @param validityTime The validity time for the swap
     */
    function swapWithDvpForERC1155(
        bytes32 resourceId,
        uint256 nftId,
        bytes32 nftResourceId,
        uint256 nftAmountOrOne,
        uint256 enygmaAmount,
        address from,
        uint256 destChainId,
        bytes32 sharedId,
        uint64 validityTime
    ) external;

    /**
     * @dev Emits an event when creating a Dvp721 token
     * @param _resourceId The resource ID of the Dvp721 token
     */
    function dvp721Creation(bytes32 _resourceId) external;

    /**
     * @dev Emits an event when creating a Dvp721 token
     * @param _resourceId The resource ID of the Dvp721 token
     */
    function dvp1155Creation(bytes32 _resourceId) external;

    /**
     * @dev Emits an event when depositing a Dvp721 NFT into Dvp
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _nftId The ID of the NFT being deposited
     */
    function dvp721DepositIntoDvp(bytes32 _resourceId, uint256 _nftId, address from) external;

        /**
     * @dev Emits an event when depositing a Dvp721 NFT into Dvp
     * @param _resourceId The resource ID of the Dvp721 token
     */
    function dvp1155DepositIntoDvp(bytes32 _resourceId, uint256 _tokenId, address from, uint256 _value, bytes memory data) external;

    /** 
     * @dev Emits an event when swapping a Dvp721 NFT for Enygma tokens
     * @param _nftResourceId The resource ID of the Dvp721 token
     * @param _nftId The ID of the NFT being swapped
     * @param _enygmaAmount The amount of Enygma tokens to receive
     * @param _enygmaResourceId The resource ID of the token to receive
     * @param _from The address of the sender
     * @param _destChainId The destination chain ID for the swap
     * @param _sharedId The shared ID for the swap
     * @param _validityTime The validity time for the swap
     */
    // add To address
    function dvp721SwapForEnygma(
        bytes32 _nftResourceId,
        uint256 _nftId,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        address _from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) external;


    /** 
     * @dev Emits an event when swapping a Dvp721 NFT for Enygma tokens
     * @param _tokenResourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being swapped
     * @param _tokenValue The amount of tokens to swap
     * @param _tokenData The data of the token
     * @param _enygmaAmount The amount of Enygma tokens to receive
     * @param _enygmaResourceId The resource ID of the token to receive
     * @param from The address of the sender
     * @param _destChainId The destination chain ID for the swap
     * @param _sharedId The shared ID for the swap
     * @param _validityTime The validity time for the swap
     */
    // add To address
    function dvp1155SwapForEnygma(
        bytes32 _tokenResourceId,
        uint256 _tokenId,
        uint256 _tokenValue,
        bytes memory _tokenData,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        address from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) external;

    /**
     * @dev Emits an event when minting a Dvp721 NFT
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being minted
     */
    function dvp721Mint(bytes32 _resourceId, uint256 _tokenId) external;

    /**
     * @dev Emits an event when minting a Dvp721 NFT
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being minted
     */
    function dvp1155Mint(bytes32 _resourceId, uint256 _tokenId, uint256 _value, bytes memory data) external;

    /**
     * @dev Emits an event when burning a Dvp721 NFT
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being burned
     */
    function dvp721Burn(bytes32 _resourceId, uint256 _tokenId) external;

    /**
     * @dev Emits an event when burning a Dvp721 NFT
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being burned
     */
    function dvp1155Burn(bytes32 _resourceId, address _to,  uint256 _tokenId, uint256 _value) external;

    /**
     * @dev Emits an event when withdrawing a Dvp721 NFT from Dvp
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being withdrawn
     */
    function dvp721WithdrawFromDvp(bytes32 _resourceId, uint256 _tokenId, address owner) external;

        /**
     * @dev Emits an event when withdrawing a Dvp721 NFT from Dvp
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being withdrawn
     */
    function dvp1155WithdrawFromDvp(bytes32 _resourceId, uint256 _tokenId, uint256 _value, bytes memory data, address owner) external;

    /**
     * @dev Emits an event when a swap is completed
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being swapped
     * @param _destinationChainId The destination chain ID for the swap
     * @param _destinationOwner The owner of the NFT on the destination chain
     */
    function Dvp721SwapCompleted(bytes32 _resourceId, uint256 _tokenId, uint256 _destinationChainId, address _destinationOwner) external;

    /**
     * @dev Emits an event when a swap is completed
     * @param _resourceId The resource ID of the Dvp721 token
     * @param _tokenId The ID of the NFT being swapped
     * @param _destinationChainId The destination chain ID for the swap
     * @param _destinationOwner The owner of the NFT on the destination chain
     */

    /**
     * @dev Emits an event when a swap is cancelled
     * @param _sharedId The shared ID of the swap
     * @param _toChainId The destination chain ID for the swap
     * @param _tokenInResourceId The resource ID of the token being swapped
     * @param _tokenInAmount The amount of tokens being swapped
     * @param _tokenInId The ID of the token being swapped
     * @param _tokenInStandard The standard of the token being swapped
     * @param _tokenOutResourceId The resource ID of the token being swapped
     * @param _tokenOutAmount The amount of tokens being swapped
     * @param _tokenOutId The ID of the token being swapped
     * @param _tokenOutStandard The standard of the token being swapped
     */
    function cancelSwap(bytes32 _sharedId, uint256 _toChainId, bytes32 _tokenInResourceId, uint256 _tokenInAmount, uint256 _tokenInId, SharedObjects.ErcStandard _tokenInStandard, bytes32 _tokenOutResourceId, uint256 _tokenOutAmount, uint256 _tokenOutId, SharedObjects.ErcStandard _tokenOutStandard) external;

    function Dvp1155SwapCompleted(bytes32 _resourceId, uint256 _tokenId, uint256 _destinationChainId, address _destinationOwner) external;
}

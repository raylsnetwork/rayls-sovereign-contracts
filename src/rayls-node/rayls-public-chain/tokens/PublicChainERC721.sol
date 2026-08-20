// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RaylsPublicERC721Handler.sol";

/**
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract PublicChainERC721 is RaylsPublicERC721Handler {
    uint256 private _tokenIdCounter;

    constructor(
        string memory _baseUri,
        string memory _name,
        string memory _symbol,
        address _raylsNodeEndpoint,
        address _privateAddress
    )
        RaylsPublicERC721Handler(
            _baseUri,
            _name,
            _symbol,
            _raylsNodeEndpoint,
            msg.sender,
            _privateAddress
        )
    {
        // Initialize with counter at 0
        _tokenIdCounter = 0;
    }

    function mintToken(address to) public restricted returns (uint256) {
        uint256 newTokenId = _tokenIdCounter;
        _mint(to, newTokenId);
        _tokenIdCounter++;
        return newTokenId;
    }

    function mintTokenWithId(address to, uint256 tokenId) public restricted {
        _mint(to, tokenId);
        // Update counter if needed
        if (tokenId >= _tokenIdCounter) {
            _tokenIdCounter = tokenId + 1;
        }
    }

    function getCurrentTokenId() public view returns (uint256) {
        return _tokenIdCounter;
    }

    function totalSupply() public view returns (uint256) {
        return _tokenIdCounter;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../rayls-protocol-sdk/tokens/RaylsErc721DvpHandler.sol";

contract Erc721DvpExample is RaylsErc721DvpHandler {
    uint256 private _tokenIdCounter;
    string private _baseUri;

    constructor(string memory baseUri, string memory name, string memory symbol, address _endpoint)
        RaylsErc721DvpHandler(baseUri, name, symbol, _endpoint, address(0), address(0), msg.sender, false)
    {        
        _baseUri = baseUri;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseUri;
    }

}

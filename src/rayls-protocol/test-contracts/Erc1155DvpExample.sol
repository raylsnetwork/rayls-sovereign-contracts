// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsErc1155DvpHandler.sol';

contract Erc1155DvpExample is RaylsErc1155DvpHandler {
    uint256 private _tokenIdCounter;
    string private _baseUri;
    string private _name;

    constructor(string memory baseUri, string memory name, address _endpoint) RaylsErc1155DvpHandler(baseUri, name, _endpoint, address(0), address(0), msg.sender, false) {
        _baseUri = baseUri;
        _name = name;
    }
}

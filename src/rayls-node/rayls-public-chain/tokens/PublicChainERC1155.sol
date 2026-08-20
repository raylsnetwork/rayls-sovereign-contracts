// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RaylsPublicERC1155Handler.sol";

/**
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract PublicChainERC1155 is RaylsPublicERC1155Handler {
    mapping(uint256 => uint256) private _totalSupply;
    mapping(uint256 => bool) private _tokenExists;
    uint256[] private _allTokenTypes;

    constructor(
        string memory _uri,
        string memory _name,
    address _raylsNodeEndpoint,
        address _privateAddress
    )
        RaylsPublicERC1155Handler(
            _uri,
            _name,
            _raylsNodeEndpoint,
            msg.sender,
            _privateAddress
        )
    {
        // Constructor is empty - tokens are created via minting
    }

    function mintTokenType(address to, uint256 id, uint256 amount, bytes memory data) external restricted {
        if (!_tokenExists[id]) {
            _tokenExists[id] = true;
            _allTokenTypes.push(id);
        }
        _totalSupply[id] += amount;
        _mint(to, id, amount, data);
    }

    function mintBatchTokenTypes(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) external restricted {
        uint256 idsLength = ids.length;
        for (uint256 i = 0; i < idsLength; i++) {
            if (!_tokenExists[ids[i]]) {
                _tokenExists[ids[i]] = true;
                _allTokenTypes.push(ids[i]);
            }
            _totalSupply[ids[i]] += amounts[i];
        }
        _mintBatch(to, ids, amounts, data);
    }

    function totalSupply(uint256 id) external view returns (uint256) {
        return _totalSupply[id];
    }

    function tokenExists(uint256 id) external view returns (bool) {
        return _tokenExists[id];
    }

    function getAllTokenTypes() external view returns (uint256[] memory) {
        return _allTokenTypes;
    }

    function getTokenTypeCount() external view returns (uint256) {
        return _allTokenTypes.length;
    }

    function burnWithSupplyUpdate(address from, uint256 id, uint256 amount) external restricted {
        _burn(from, id, amount);
        _totalSupply[id] -= amount;
    }

    function burnBatchWithSupplyUpdate(address from, uint256[] memory ids, uint256[] memory amounts) external restricted {
        _burnBatch(from, ids, amounts);
        uint256 idsLength = ids.length;
        for (uint256 i = 0; i < idsLength; i++) {
            _totalSupply[ids[i]] -= amounts[i];
        }
    }
}
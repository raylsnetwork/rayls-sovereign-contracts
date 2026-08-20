// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RaylsPublicERC20Handler.sol";

/**
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract PublicChainERC20 is RaylsPublicERC20Handler {
    constructor(
        string memory _name,
        string memory _symbol,
        address _raylsNodeEndpoint,
        uint256 _initialSupply,
        address privateAddress
    )
        RaylsPublicERC20Handler(
            _name,
            _symbol,
            _raylsNodeEndpoint,
            msg.sender,
            privateAddress
        )
    {
        if (_initialSupply > 0) {
            _mint(msg.sender, _initialSupply);
        }
    }
}
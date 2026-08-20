// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../rayls-protocol-sdk/tokens/RaylsErc1155Handler.sol";

contract RaylsErc1155Example is RaylsErc1155Handler {
    uint256 public constant Gold = 0;
    uint256 public constant Silver = 50;
    address public constant addressToFail = address(0x0000000000000000000555000000000000001123);

    constructor(string memory _url, string memory name, address _endpoint, address _raylsNodeEndpoint, address _userGovernance)
        RaylsErc1155Handler(_url, name, _endpoint, _raylsNodeEndpoint, _userGovernance, msg.sender, false)
    {
        _mint(msg.sender, Gold, 100, "First Mint");
        _mint(msg.sender, Silver, 2000, "Second Mint");
    }

    function GetERCStandard() public pure override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.ERC1155Test;
    }

    function receiveTeleportAtomic(address to, uint256 id, uint256 value, bytes memory data)
        public
        override
        restricted
    {
        if (to == addressToFail) revert("Destination address is the one that revert messages."); // created for test purposes

        super.receiveTeleportAtomic(to, id, value, data);
    }
}

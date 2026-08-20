// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol';

contract EnygmaTokenExample is RaylsEnygmaHandler {
    address public constant addressToFail = address(0x0000000000000000000555000000000000001123);

    string public message = 'test';
    constructor(string memory _name, string memory _symbol, address _endpoint) RaylsEnygmaHandler(_name, _symbol, _endpoint, msg.sender, 18, false) {}

    function receiveMsgA(string memory _msg) public {
        message = _msg;
    }

    function crossMintStandard(
        address _to,
        uint256 _value,
        bytes32 _referenceId
    ) public override restricted {
        if (_to == addressToFail) revert("Destination address is the one that reverts messages."); // created for test purposes

        super.crossMintStandard(_to, _value, _referenceId);
    }

    function GetERCStandard() public pure override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.EnygmaTest;
    }
}

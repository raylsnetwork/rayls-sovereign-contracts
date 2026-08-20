// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../rayls-protocol-sdk/RaylsMessage.sol";
import {IPublicRaylsNodeEndpoint} from "../rayls-privacy-node/interfaces/IPublicRaylsNodeEndpoint.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
abstract contract RaylsPublicApp is RaylsAccessManaged {
    IPublicRaylsNodeEndpoint internal publicRaylsNodeEndpoint;

    constructor(address _publicRaylsNodeEndpoint) {
        publicRaylsNodeEndpoint = IPublicRaylsNodeEndpoint(_publicRaylsNodeEndpoint);
        address mgr = publicRaylsNodeEndpoint.authority();
        if (mgr != address(0)) {
            _setAuthority(mgr);
        }
    }

    function getPublicRaylsNodeEndpoint() public view returns (address) {
        return address(publicRaylsNodeEndpoint);
    }

    // NOTE: receiveMethod was removed in AUTH-V3; use `restricted` modifier instead.
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import './EnygmaWithdrawFromDvpVerifierk6.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

contract EnygmaWithdrawFromDvpVerifierk6Proxy is RaylsAccessManaged {
    address verifierAddress;

    constructor(address _verifierAddress, address _authority) {
        verifierAddress = _verifierAddress;
        if (_authority != address(0)) _setAuthority(_authority);
    }

    function verifyProof(uint[2] calldata _pA, uint[2][2] calldata _pB, uint[2] calldata _pC, uint[60] calldata _pubSignals) public view returns (bool) {
        return EnygmaWithdrawFromDvpVerifierk6(verifierAddress).verifyProof(_pA, _pB, _pC, _pubSignals);
    }

    function setVerifierAddress(address _verifierAddress) public restricted {
        verifierAddress = _verifierAddress;
    }
}

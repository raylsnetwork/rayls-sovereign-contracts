// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import '../../interfaces/IEnygmaFactorySettings.sol';

// Struct to batch set all verifiers
struct VerifierAddresses {
    address enygmaK2;
    address enygmaK3;
    address enygmaK4;
    address enygmaK5;
    address enygmaK6;
    address depositK2;
    address depositK3;
    address depositK4;
    address depositK5;
    address depositK6;
    address withdrawK2;
    address withdrawK3;
    address withdrawK4;
    address withdrawK5;
    address withdrawK6;
}

contract EnygmaFactorySettings is IEnygmaFactorySettings, RaylsAccessManaged {
    address private _enygmaVerifierk2;
    address private _enygmaVerifierk3;
    address private _enygmaVerifierk4;
    address private _enygmaVerifierk5;
    address private _enygmaVerifierk6;
    address private _dvpAddress;
    address private _dvpTeleportAddress;
    address private _poseidonWrapperAddress;
    address private _depositToDvpVerifierk2;
    address private _depositToDvpVerifierk3;
    address private _depositToDvpVerifierk4;
    address private _depositToDvpVerifierk5;
    address private _depositToDvpVerifierk6;
    address private _withdrawFromDvpVerifierk2;
    address private _withdrawFromDvpVerifierk3;
    address private _withdrawFromDvpVerifierk4;
    address private _withdrawFromDvpVerifierk5;
    address private _withdrawFromDvpVerifierk6;

    constructor(
        address enygmaVerifierk2_,
        address enygmaVerifierk3_,
        address enygmaVerifierk4_,
        address enygmaVerifierk5_,
        address enygmaVerifierk6_,
        address dvpAddress_,
        address dvpTeleportAddress_,
        address poseidonWrapperAddress_,
        address _authority
    ) {
        if (_authority != address(0)) _setAuthority(_authority);
        _enygmaVerifierk2 = enygmaVerifierk2_;
        _enygmaVerifierk3 = enygmaVerifierk3_;
        _enygmaVerifierk4 = enygmaVerifierk4_;
        _enygmaVerifierk5 = enygmaVerifierk5_;
        _enygmaVerifierk6 = enygmaVerifierk6_;
        _dvpAddress = dvpAddress_;
        _dvpTeleportAddress = dvpTeleportAddress_;
        _poseidonWrapperAddress = poseidonWrapperAddress_;
    }

    // Enygma verifiers
    function enygmaVerifierk2() external view returns (address) {
        return _enygmaVerifierk2;
    }

    function enygmaVerifierk3() external view returns (address) {
        return _enygmaVerifierk3;
    }

    function enygmaVerifierk4() external view returns (address) {
        return _enygmaVerifierk4;
    }

    function enygmaVerifierk5() external view returns (address) {
        return _enygmaVerifierk5;
    }

    function enygmaVerifierk6() external view returns (address) {
        return _enygmaVerifierk6;
    }

    // Dvp and Poseidon
    function dvpAddress() external view returns (address) {
        return _dvpAddress;
    }

    function dvpTeleportAddress() external view returns (address) {
        return _dvpTeleportAddress;
    }

    function poseidonWrapperAddress() external view returns (address) {
        return _poseidonWrapperAddress;
    }

    // Deposit verifiers
    function depositToDvpVerifierk2() external view returns (address) {
        return _depositToDvpVerifierk2;
    }

    function depositToDvpVerifierk3() external view returns (address) {
        return _depositToDvpVerifierk3;
    }

    function depositToDvpVerifierk4() external view returns (address) {
        return _depositToDvpVerifierk4;
    }

    function depositToDvpVerifierk5() external view returns (address) {
        return _depositToDvpVerifierk5;
    }

    function depositToDvpVerifierk6() external view returns (address) {
        return _depositToDvpVerifierk6;
    }

    // Withdraw verifiers
    function withdrawFromDvpVerifierk2() external view returns (address) {
        return _withdrawFromDvpVerifierk2;
    }

    function withdrawFromDvpVerifierk3() external view returns (address) {
        return _withdrawFromDvpVerifierk3;
    }

    function withdrawFromDvpVerifierk4() external view returns (address) {
        return _withdrawFromDvpVerifierk4;
    }

    function withdrawFromDvpVerifierk5() external view returns (address) {
        return _withdrawFromDvpVerifierk5;
    }

    function withdrawFromDvpVerifierk6() external view returns (address) {
        return _withdrawFromDvpVerifierk6;
    }

    // Setters for deposit verifiers
    function setDepositToDvpVerifierk2(address verifier) external restricted {
        _depositToDvpVerifierk2 = verifier;
    }

    function setDepositToDvpVerifierk3(address verifier) external restricted {
        _depositToDvpVerifierk3 = verifier;
    }

    function setDepositToDvpVerifierk4(address verifier) external restricted {
        _depositToDvpVerifierk4 = verifier;
    }

    function setDepositToDvpVerifierk5(address verifier) external restricted {
        _depositToDvpVerifierk5 = verifier;
    }

    function setDepositToDvpVerifierk6(address verifier) external restricted {
        _depositToDvpVerifierk6 = verifier;
    }

    // Setters for withdraw verifiers
    function setWithdrawFromDvpVerifierk2(address verifier) external restricted {
        _withdrawFromDvpVerifierk2 = verifier;
    }

    function setWithdrawFromDvpVerifierk3(address verifier) external restricted {
        _withdrawFromDvpVerifierk3 = verifier;
    }

    function setWithdrawFromDvpVerifierk4(address verifier) external restricted {
        _withdrawFromDvpVerifierk4 = verifier;
    }

    function setWithdrawFromDvpVerifierk5(address verifier) external restricted {
        _withdrawFromDvpVerifierk5 = verifier;
    }

    function setWithdrawFromDvpVerifierk6(address verifier) external restricted {
        _withdrawFromDvpVerifierk6 = verifier;
    }

    // Setters for dvp addresses
    function setDvpAddress(address dvpAddress_) external restricted {
        _dvpAddress = dvpAddress_;
    }

    function setDvpTeleportAddress(address dvpTeleportAddress_) external restricted {
        _dvpTeleportAddress = dvpTeleportAddress_;
    }

    function setPoseidonWrapperAddress(address poseidonWrapperAddress_) external restricted {
        _poseidonWrapperAddress = poseidonWrapperAddress_;
    }

    // Batch setter for all verifiers (dvp address should be set separately via setDvpAddress)
    function setAllVerifiers(VerifierAddresses calldata verifiers) external restricted {
        // Set Enygma verifiers
        _enygmaVerifierk2 = verifiers.enygmaK2;
        _enygmaVerifierk3 = verifiers.enygmaK3;
        _enygmaVerifierk4 = verifiers.enygmaK4;
        _enygmaVerifierk5 = verifiers.enygmaK5;
        _enygmaVerifierk6 = verifiers.enygmaK6;

        // Set deposit verifiers
        _depositToDvpVerifierk2 = verifiers.depositK2;
        _depositToDvpVerifierk3 = verifiers.depositK3;
        _depositToDvpVerifierk4 = verifiers.depositK4;
        _depositToDvpVerifierk5 = verifiers.depositK5;
        _depositToDvpVerifierk6 = verifiers.depositK6;

        // Set withdraw verifiers
        _withdrawFromDvpVerifierk2 = verifiers.withdrawK2;
        _withdrawFromDvpVerifierk3 = verifiers.withdrawK3;
        _withdrawFromDvpVerifierk4 = verifiers.withdrawK4;
        _withdrawFromDvpVerifierk5 = verifiers.withdrawK5;
        _withdrawFromDvpVerifierk6 = verifiers.withdrawK6;
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IEnygmaFactorySettings {
    // Enygma verifiers
    function enygmaVerifierk2() external view returns (address);

    function enygmaVerifierk3() external view returns (address);

    function enygmaVerifierk4() external view returns (address);

    function enygmaVerifierk5() external view returns (address);

    function enygmaVerifierk6() external view returns (address);

    function poseidonWrapperAddress() external view returns (address);

    function dvpAddress() external view returns (address);

    function dvpTeleportAddress() external view returns (address);

    // Deposit verifiers
    function depositToDvpVerifierk2() external view returns (address);

    function depositToDvpVerifierk3() external view returns (address);

    function depositToDvpVerifierk4() external view returns (address);

    function depositToDvpVerifierk5() external view returns (address);

    function depositToDvpVerifierk6() external view returns (address);

    // Withdraw verifiers
    function withdrawFromDvpVerifierk2() external view returns (address);

    function withdrawFromDvpVerifierk3() external view returns (address);

    function withdrawFromDvpVerifierk4() external view returns (address);

    function withdrawFromDvpVerifierk5() external view returns (address);

    function withdrawFromDvpVerifierk6() external view returns (address);
}

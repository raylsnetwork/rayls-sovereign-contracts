// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/interfaces/IEnygmaDepositToDvpVerifierk2.sol";
import "../../../rayls-protocol/interfaces/IEnygmaDepositToDvpVerifierk3.sol";
import "../../../rayls-protocol/interfaces/IEnygmaDepositToDvpVerifierk4.sol";
import "../../../rayls-protocol/interfaces/IEnygmaDepositToDvpVerifierk5.sol";
import "../../../rayls-protocol/interfaces/IEnygmaDepositToDvpVerifierk6.sol";
import "../../../rayls-protocol/interfaces/IEnygmaWithdrawFromDvpVerifierk2.sol";
import "../../../rayls-protocol/interfaces/IEnygmaWithdrawFromDvpVerifierk3.sol";
import "../../../rayls-protocol/interfaces/IEnygmaWithdrawFromDvpVerifierk4.sol";
import "../../../rayls-protocol/interfaces/IEnygmaWithdrawFromDvpVerifierk5.sol";
import "../../../rayls-protocol/interfaces/IEnygmaWithdrawFromDvpVerifierk6.sol";

/**
 * @title Deposit and withdraw verifiers share one verifyProof ABI per k
 * @notice EnygmaDvpIntegration._verifyZkProof dispatches both families through the deposit
 *         interfaces. If a circuit change makes the signal counts diverge, this test fails and the
 *         dispatch must be split per family.
 */
contract EnygmaDvpIntegrationVerifierAbiTest is Test {
    function test_depositAndWithdrawVerifiers_shareSelectorPerK() public pure {
        assertEq(IEnygmaDepositToDvpVerifierk2.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk2.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk3.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk3.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk4.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk4.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk5.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk5.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk6.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk6.verifyProof.selector);
    }
}

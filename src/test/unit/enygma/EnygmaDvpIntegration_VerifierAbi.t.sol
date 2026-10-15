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
 * @dev A selector is keccak256 of the full signature, fixed array sizes included, so different signal
 *      counts give different selectors. The second test pins each selector to the literal 8k + 3
 *      signature to make that explicit.
 */
contract EnygmaDvpIntegrationVerifierAbiTest is Test {
    function test_depositAndWithdrawVerifiers_shareSelectorPerK() public pure {
        assertEq(IEnygmaDepositToDvpVerifierk2.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk2.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk3.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk3.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk4.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk4.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk5.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk5.verifyProof.selector);
        assertEq(IEnygmaDepositToDvpVerifierk6.verifyProof.selector, IEnygmaWithdrawFromDvpVerifierk6.verifyProof.selector);
    }

    function test_withdrawVerifiers_use8kPlus3SignalArrays() public pure {
        assertEq(IEnygmaWithdrawFromDvpVerifierk2.verifyProof.selector, _sel(19));
        assertEq(IEnygmaWithdrawFromDvpVerifierk3.verifyProof.selector, _sel(27));
        assertEq(IEnygmaWithdrawFromDvpVerifierk4.verifyProof.selector, _sel(35));
        assertEq(IEnygmaWithdrawFromDvpVerifierk5.verifyProof.selector, _sel(43));
        assertEq(IEnygmaWithdrawFromDvpVerifierk6.verifyProof.selector, _sel(51));
        // A different array size is a different selector.
        assertTrue(_sel(19) != _sel(28));
    }

    function _sel(uint256 signals) private pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(
            "verifyProof(uint256[2],uint256[2][2],uint256[2],uint256[", vm.toString(signals), "])"
        )));
    }
}

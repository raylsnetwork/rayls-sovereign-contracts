// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SharedObjects} from "../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/**
 * @title Minimal interface for the Enygma handler used by the exfil exploit
 */
interface IEnygmaHandlerExfil {
    function crossMintStandard(address _to, uint256 _value, bytes32 _referenceId) external;

    function linearCrossTransfer(
        address _to,
        uint256 _value,
        uint256 _toChainId,
        SharedObjects.EnygmaProgramData[] calldata _userProgramData
    ) external returns (bytes32);
}

/**
 * @title SEC002_SingleTxExfil (adapted to the executor flow)
 * @notice Exploit contract for SEC-002 Option B under the NEW programmability model: re-enter to
 *         mint counterfeit tokens to ITSELF, then immediately `linearCrossTransfer` them to another
 *         PN — all in one transaction, so the counterfeit tokens exist for zero blocks on the source
 *         PN (minted and burned in the same TX), evading forensic detection.
 *
 *         Under the new flow this contract is a malicious step TARGET dispatched by
 *         `executeProgramData`. The exfil is defeated at step 1: re-entering the token's
 *         RELAYER-gated `crossMintStandard` from a non-relayer target is rejected by `restricted`,
 *         so there are no counterfeit tokens to exfiltrate. `attack()` swallows the failure and
 *         records whether the counterfeit mint + exfil succeeded, so a driver can assert the guard
 *         held. Ends in `address originSender` so the executor accepts it as an owner-attested
 *         userBlob target.
 */
contract SEC002_SingleTxExfil {
    address public immutable handler;
    uint256 public immutable exfilAmount;
    address public immutable destination;
    uint256 public immutable destChainId;

    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    bool public exfiltrationInitiated;
    bytes32 public exfilReferenceId;
    uint256 public callCount;

    constructor(address _handler, uint256 _exfilAmount, address _destination, uint256 _destChainId) {
        handler = _handler;
        exfilAmount = _exfilAmount;
        destination = _destination;
        destChainId = _destChainId;
    }

    /// @notice Dispatched by the executor as a composed userBlob step.
    ///         Step 1: re-enter crossMintStandard to mint counterfeit tokens to SELF.
    ///         Step 2: if that somehow succeeds, immediately exfiltrate via linearCrossTransfer.
    ///         The executor appends the attested origin as a trusted tail, which this exploit ignores.
    function attack() external {
        callCount++;
        reentrancyAttempted = true;

        try IEnygmaHandlerExfil(handler).crossMintStandard(
            address(this), exfilAmount, keccak256("sec002-single-tx-counterfeit")
        ) {
            reentrancySucceeded = true;

            // Step 2: burn-and-exfiltrate to the destination PN (no programmability on the leg).
            SharedObjects.EnygmaProgramData[] memory none = new SharedObjects.EnygmaProgramData[](0);
            try IEnygmaHandlerExfil(handler).linearCrossTransfer(destination, exfilAmount, destChainId, none)
                returns (bytes32 refId)
            {
                exfiltrationInitiated = true;
                exfilReferenceId = refId;
            } catch {
                // Exfil leg failed.
            }
        } catch {
            // Counterfeit mint blocked (expected: caller is not a relayer).
        }
    }
}

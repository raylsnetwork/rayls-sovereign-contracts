// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaDvpIntegration.sol";

/**
 * @title Input validation for depositToDvp
 * @notice Malformed proofs must be rejected before any verifier or DvP call: an empty proof with
 *         a custom error rather than an arithmetic panic, and a wrong-sized one by the layout check.
 * @dev EnygmaV1 and the token registry are mocked only as far as the freeze check needs.
 */
contract EnygmaDvpIntegrationDepositInputTest is Test {
    EnygmaDvpIntegration public integration;

    address public factory;
    address public enygmaV1;
    address public tokenRegistry;

    function setUp() public {
        factory = makeAddr("factory");
        enygmaV1 = makeAddr("enygmaV1");
        tokenRegistry = makeAddr("tokenRegistry");

        vm.etch(enygmaV1, hex"00");
        vm.etch(tokenRegistry, hex"00");

        integration = new EnygmaDvpIntegration(enygmaV1, factory);

        vm.mockCall(enygmaV1, abi.encodeWithSignature("tokenRegistryContract()"), abi.encode(tokenRegistry));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("resourceId()"), abi.encode(bytes32("resource")));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("ownerChainId()"), abi.encode(uint256(1)));
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(false));
    }

    function test_depositToDvp_emptyProofSignals_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](0);

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__EmptyPublicSignals.selector);
        integration.depositToDvp(proof, new bytes[](0), "");
    }

    /// @notice Deposit proofs are 8k + 3 signals; anything else matches no k once hashCommitment is stripped.
    function test_depositToDvp_wrongPublicSignalLayout_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * 2 + 12);

        vm.expectRevert(bytes("Invalid transfer proof public_signal length"));
        integration.depositToDvp(proof, new bytes[](0), "");
    }

    /// @notice A proof carrying only hashCommitment leaves no transfer signals.
    function test_depositToDvp_onlyHashCommitmentSignal_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](1);

        vm.expectRevert(bytes("Invalid transfer proof public_signal length"));
        integration.depositToDvp(proof, new bytes[](0), "");
    }
}

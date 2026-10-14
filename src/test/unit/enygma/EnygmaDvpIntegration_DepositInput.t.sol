// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaDvpIntegration.sol";
import "../../../rayls-protocol/interfaces/IEnygmaDepositToDvpVerifierk2.sol";

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
    address public dvp;
    address public verifier;

    uint256 constant HASH_COMMITMENT = 0xDEC0DE;

    function setUp() public {
        factory = makeAddr("factory");
        enygmaV1 = makeAddr("enygmaV1");
        tokenRegistry = makeAddr("tokenRegistry");

        dvp = makeAddr("dvp");
        verifier = makeAddr("verifier");

        vm.etch(enygmaV1, hex"fe");
        vm.etch(tokenRegistry, hex"fe");
        vm.etch(dvp, hex"fe");
        vm.etch(verifier, hex"fe");

        integration = new EnygmaDvpIntegration(enygmaV1, factory);
        vm.startPrank(factory);
        integration.addDepositToDvpVerifier(verifier, 2);
        integration.addDvp(dvp);
        integration.setVaultId(1);
        vm.stopPrank();

        vm.mockCall(enygmaV1, abi.encodeWithSignature("tokenRegistryContract()"), abi.encode(tokenRegistry));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("resourceId()"), abi.encode(bytes32("resource")));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("ownerChainId()"), abi.encode(uint256(1)));
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(false));
    }

    /// @notice A well-formed k=2 deposit reaches the verifier and the DvP and names the Enygma contract
    ///         in its event.
    function test_depositToDvp_validProof_succeeds() public {
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpValidateTransferInputs.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpFinalisePendingTransactions.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpAddPendingTransaction.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpSendEvents.selector), "");
        vm.mockCall(enygmaV1, abi.encodeWithSelector(EnygmaV1.dvpSetLastblockNumPending.selector), "");
        vm.mockCall(verifier, abi.encodeWithSelector(IEnygmaDepositToDvpVerifierk2.verifyProof.selector), abi.encode(true));
        vm.mockCall(dvp, abi.encodeWithSelector(IDvp.depositEnygma.selector), abi.encode(true));

        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * 2 + 3);
        proof.public_signal[8 * 2 + 2] = HASH_COMMITMENT;

        vm.expectCall(verifier, abi.encodeWithSelector(IEnygmaDepositToDvpVerifierk2.verifyProof.selector));
        vm.expectCall(dvp, abi.encodeWithSelector(IDvp.depositEnygma.selector, uint256(1), HASH_COMMITMENT));
        vm.expectEmit(true, false, false, true, address(integration));
        emit IEnygmaDvpIntegration.DepositToDvpSuccesful(HASH_COMMITMENT, enygmaV1);

        assertTrue(integration.depositToDvp(proof, new bytes[](0), ""));
    }

    /// @notice A zero hashCommitment would insert a trivially known note into the vault.
    function test_SECURITY_depositToDvp_zeroHashCommitment_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * 2 + 3);

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__ZeroHashCommitment.selector);
        integration.depositToDvp(proof, new bytes[](0), "");
    }

    function test_depositToDvp_tokenFrozen_reverts() public {
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(true));
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](8 * 2 + 3);

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__TokenFrozen.selector);
        integration.depositToDvp(proof, new bytes[](0), "");
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
        proof.public_signal[8 * 2 + 11] = HASH_COMMITMENT;

        vm.expectRevert(abi.encodeWithSelector(EnygmaDvpIntegration.EnygmaDvpIntegration__InvalidPublicSignalLength.selector, 8 * 2 + 11));
        integration.depositToDvp(proof, new bytes[](0), "");
    }

    /// @notice A proof carrying only hashCommitment leaves no transfer signals.
    function test_depositToDvp_onlyHashCommitmentSignal_reverts() public {
        IEnygmaDvpIntegration.WithdrawOrDepositProof memory proof;
        proof.public_signal = new uint256[](1);
        proof.public_signal[0] = HASH_COMMITMENT;

        vm.expectRevert(abi.encodeWithSelector(EnygmaDvpIntegration.EnygmaDvpIntegration__InvalidPublicSignalLength.selector, 0));
        integration.depositToDvp(proof, new bytes[](0), "");
    }
}

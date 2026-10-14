// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaDvpIntegration.sol";

/// @dev DvP stand-in whose mixFunds calls back into the integration.
contract ReenteringDvp {
    EnygmaDvpIntegration public integration;

    function setIntegration(EnygmaDvpIntegration _integration) external {
        integration = _integration;
    }

    function mixFunds(uint256, IDvp.ProofReceipt memory receipt) external returns (bool) {
        return integration.consolidateFunds(receipt);
    }
}

/**
 * @title consolidateFunds: permissionless relay, guarded against reentrancy
 * @notice Authorisation comes from the receipt, which the DvP vault verifies, so any caller may
 *         relay it. A nested call back into the integration must still revert.
 */
contract EnygmaDvpIntegrationConsolidateFundsTest is Test {
    EnygmaDvpIntegration public integration;

    address public factory;
    address public enygmaV1;
    address public dvp;
    address public tokenRegistry;

    uint256 constant VAULT_ID = 1;

    function setUp() public {
        factory = makeAddr("factory");
        enygmaV1 = makeAddr("enygmaV1");
        dvp = makeAddr("dvp");
        tokenRegistry = makeAddr("tokenRegistry");
        vm.etch(dvp, hex"fe");
        vm.etch(enygmaV1, hex"fe");
        vm.etch(tokenRegistry, hex"fe");

        // checkFreeze: token not frozen unless a test overrides it
        vm.mockCall(enygmaV1, abi.encodeWithSignature("tokenRegistryContract()"), abi.encode(tokenRegistry));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("resourceId()"), abi.encode(bytes32("resource")));
        vm.mockCall(enygmaV1, abi.encodeWithSignature("ownerChainId()"), abi.encode(uint256(1)));
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(false));

        integration = new EnygmaDvpIntegration(enygmaV1, factory);
        vm.startPrank(factory);
        integration.addDvp(dvp);
        integration.setVaultId(VAULT_ID);
        vm.stopPrank();
    }

    function test_consolidateFunds_anyCaller_forwardsToDvp() public {
        IDvp.ProofReceipt memory receipt;
        vm.mockCall(dvp, abi.encodeWithSelector(IDvp.mixFunds.selector), abi.encode(true));
        vm.expectCall(dvp, abi.encodeWithSelector(IDvp.mixFunds.selector, VAULT_ID, receipt));

        vm.prank(makeAddr("relayer"));
        assertTrue(integration.consolidateFunds(receipt));
    }

    /// @notice A join-split can pay notes to other keys, so consolidation must respect a freeze.
    function test_SECURITY_consolidateFunds_tokenFrozen_reverts() public {
        IDvp.ProofReceipt memory receipt;
        vm.mockCall(tokenRegistry, abi.encodeWithSelector(TokenRegistryV1.isTokenFrozenForParticipant.selector), abi.encode(true));

        vm.expectCall(dvp, abi.encodeWithSelector(IDvp.mixFunds.selector), 0);
        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__TokenFrozen.selector);
        integration.consolidateFunds(receipt);
    }

    /// @notice A false return from the DvP is surfaced as a revert, like deposit and withdraw.
    function test_consolidateFunds_dvpReturnsFalse_reverts() public {
        IDvp.ProofReceipt memory receipt;
        vm.mockCall(dvp, abi.encodeWithSelector(IDvp.mixFunds.selector), abi.encode(false));

        vm.expectRevert(EnygmaDvpIntegration.EnygmaDvpIntegration__DvpCallFailed.selector);
        integration.consolidateFunds(receipt);
    }

    function test_SECURITY_consolidateFunds_reentry_reverts() public {
        ReenteringDvp reentrant = new ReenteringDvp();
        EnygmaDvpIntegration target = new EnygmaDvpIntegration(enygmaV1, factory);
        reentrant.setIntegration(target);
        vm.startPrank(factory);
        target.addDvp(address(reentrant));
        target.setVaultId(VAULT_ID);
        vm.stopPrank();

        IDvp.ProofReceipt memory receipt;
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        target.consolidateFunds(receipt);
    }
}

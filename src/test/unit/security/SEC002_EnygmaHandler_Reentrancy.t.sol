// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SharedObjects} from "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsEnygmaHandler} from "../../../rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol";
import {ProgrammabilityExecutorV1} from "../../../rayls-protocol/ProgrammabilityExecutor/ProgrammabilityExecutorV1.sol";
import {EnygmaTokenExample} from "../../../rayls-protocol/test-contracts/EnygmaTokenExample.sol";
import {ArbitraryCallable} from "../../../rayls-protocol/test-contracts/ArbitraryCallable.sol";
import {SEC002_CrossMintExploit} from "../../security/SEC002_CrossMintExploit.sol";
import {SEC002_SingleTxExfil} from "../../security/SEC002_SingleTxExfil.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";
import "../mocks/MockEndpointForSecurityTest.sol";

/// @dev Accepts all IEnygmaPNEvents calls without reverting.
contract MockEnygmaPNEventsSEC002 {
    fallback() external {}
}

/// @dev Replica gate stub: approves `(codehash, selector)`. The executor gates via `check` only
///      (origin is conveyed by a trusted calldata tail, so no param count is needed).
contract _SEC002Replica {
    mapping(bytes32 => bool) public approved;

    function approve(address target, bytes4 selector) external {
        approved[keccak256(abi.encode(target.codehash, selector))] = true;
    }

    function check(address target, bytes4 selector) external view returns (bool) {
        return approved[keccak256(abi.encode(target.codehash, selector))];
    }

    function checkWithParamCount(address target, bytes4 selector) external view returns (bool, uint256) {
        return (approved[keccak256(abi.encode(target.codehash, selector))], 0);
    }
}

/**
 * @title SEC-002 (adapted): reentrancy is blocked in the programmability flow
 * @notice The original SEC-002 attacked the OLD callable model, where
 *         `crossMint(to, value, refId, EnygmaCrossTransferCallable[])` minted and then executed
 *         callables IN-HANDLER via `.call(payload)` — a malicious callable could re-enter
 *         `crossMint` to mint counterfeit tokens (CEI + reentrancy).
 *
 *         That signature no longer exists. Programmability now runs through
 *         `ProgrammabilityExecutorV1.executeProgramData(EnygmaProgramData[], uint256, address)`,
 *         which `target.call`s each gated step. A malicious step target re-entering the token's
 *         settlement mint (`crossMintStandard`) or the executor is defended by TWO independent
 *         gates: `restricted` (caller must hold RELAYER) and `nonReentrant`. These tests prove both
 *         the realistic attack (non-relayer target) and the `nonReentrant` guard in isolation.
 */
contract SEC002_EnygmaHandler_ReentrancyTest is Test {
    bytes4 constant SEL_CROSS_MINT_STANDARD = bytes4(keccak256("crossMintStandard(address,uint256,bytes32)"));
    bytes4 constant SEL_REENTER = ArbitraryCallable.reenter.selector; // reenter()

    uint256 constant CHAIN_ID = 12345;
    uint256 constant PRIVATE_HUB_ID = 99999;

    bytes32 constant RID_TOKEN = keccak256("resource.token");
    bytes32 constant RID_ATTACKER = keccak256("resource.attacker");

    address owner;
    address relayer = makeAddr("relayer");

    RaylsAccessManagerV1 manager;
    MockEndpointForSecurityTest endpoint;
    MockEnygmaPNEventsSEC002 pnEvents;
    _SEC002Replica replica;
    ProgrammabilityExecutorV1 executor;
    EnygmaTokenExample token;
    ArbitraryCallable attacker;

    uint64 relayerRoleId;

    function setUp() public {
        owner = address(this);

        endpoint = new MockEndpointForSecurityTest(CHAIN_ID, PRIVATE_HUB_ID);
        endpoint.setTrustedExecutor(owner);

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.grantRole(manager.ADMIN(), address(manager), 0);
        relayerRoleId = manager.registerRole("RELAYER");
        manager.registerRole("MESSAGE_EXECUTOR");
        manager.grantRole(relayerRoleId, relayer, 0);
        endpoint.setAuthority(address(manager));

        pnEvents = new MockEnygmaPNEventsSEC002();
        endpoint.registerResourceId(Constants.RESOURCE_ID_ENYGMA_PN_EVENTS, address(pnEvents));

        replica = new _SEC002Replica();

        ProgrammabilityExecutorV1 eImpl = new ProgrammabilityExecutorV1();
        executor = ProgrammabilityExecutorV1(address(new ERC1967Proxy(
            address(eImpl),
            abi.encodeCall(ProgrammabilityExecutorV1.initialize, (address(endpoint), address(replica), address(manager)))
        )));
        // The executor holds RELAYER so its target.call into the token's restricted crossMintStandard
        // is admitted — exactly the production wiring.
        manager.grantRole(relayerRoleId, address(executor), 0);
        // The relayer key is allowed to call executeProgramData.
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = bytes4(keccak256("executeProgramData((bytes32,address,bytes4,bytes)[],uint256,address)"));
        uint64[] memory roles = new uint64[](1);
        roles[0] = relayerRoleId;
        manager.addFunctionAllowedRoles(address(executor), sels, roles);

        token = new EnygmaTokenExample("TestEnygma", "TENYG", address(endpoint));
        endpoint.registerResourceId(RID_TOKEN, address(token));

        // Activate the token so `crossMintStandard`'s `_requireHubActive` gate passes:
        // register the PN token registry and assign the token a non-zero resourceId.
        MockRaylsAppTokenRegistry appRegistry = new MockRaylsAppTokenRegistry();
        endpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(appRegistry));
        vm.prank(address(appRegistry));
        token.setResourceId(RID_TOKEN);

        attacker = new ArbitraryCallable();
        endpoint.registerResourceId(RID_ATTACKER, address(attacker));

        // Gate-approve the settlement mint and the attacker's reenter() probe.
        replica.approve(address(token), SEL_CROSS_MINT_STANDARD);
        replica.approve(address(attacker), SEL_REENTER); // reenter()
    }

    /// @dev Build a step targeting a resourceId.
    function _step(bytes32 rid, bytes4 selector, bytes memory args)
        internal
        pure
        returns (SharedObjects.EnygmaProgramData memory)
    {
        return SharedObjects.EnygmaProgramData({
            resourceId: rid,
            contractAddress: address(0),
            selector: selector,
            args: args
        });
    }

    // =========================================================================
    // Realistic attack: a non-relayer step target cannot re-enter the mint.
    // =========================================================================

    /// @notice A composed transfer dispatches [mintStep, reenterStep]. The attacker's reenter()
    ///         tries to call crossMintStandard directly to mint counterfeit tokens. It is NOT a
    ///         relayer, so the token's `restricted` modifier rejects the re-entrant call. The probe
    ///         swallows the failure (as a real attacker contract would), so the dispatch completes —
    ///         but no counterfeit tokens were minted. This is the primary gate in the new flow:
    ///         crossMintStandard is RELAYER-gated, and an arbitrary userBlob target is not a relayer.
    function test_SEC002_nonRelayerTarget_cannot_remint() public {
        // Attacker re-entry payload: crossMintStandard(attacker, 1e24, ref) — counterfeit mint.
        bytes memory reentrantCall = abi.encodeWithSelector(
            SEL_CROSS_MINT_STANDARD, address(attacker), uint256(1_000_000 ether), keccak256("counterfeit")
        );
        attacker.setReenter(address(token), reentrantCall);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(0xBEEF), uint256(100 ether), keccak256("ref")));
        steps[1] = _step(RID_ATTACKER, SEL_REENTER, "");

        vm.prank(relayer);
        executor.executeProgramData(steps, 100 ether, relayer);

        assertTrue(attacker.reentrancyAttempted(), "probe should have attempted the re-entrant mint");
        assertFalse(attacker.reentrancySucceeded(), "restricted gate must reject the non-relayer re-entrant mint");
        assertEq(token.balanceOf(address(attacker)), 0, "no counterfeit tokens minted");
        assertEq(token.balanceOf(address(0xBEEF)), 100 ether, "legitimate settlement mint lands");
    }

    // =========================================================================
    // Executor-level reentrancy: re-entering executeProgramData is blocked by nonReentrant.
    // =========================================================================

    /// @notice The attacker target (granted RELAYER, so it clears `restricted`) re-enters
    ///         executeProgramData mid-dispatch to mint counterfeit tokens. executeProgramData is
    ///         `nonReentrant` and holds its lock for the whole frame, so the nested call reverts.
    ///         The probe swallows that revert; the outer dispatch completes with NO counterfeit
    ///         mint. This isolates the executor's reentrancy guard from the `restricted` gate.
    function test_SEC002_nonReentrant_blocks_executor_reentry() public {
        manager.grantRole(relayerRoleId, address(attacker), 0);

        SharedObjects.EnygmaProgramData[] memory inner = new SharedObjects.EnygmaProgramData[](1);
        inner[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(attacker), uint256(1_000_000 ether), keccak256("counterfeit")));
        bytes memory reentrantCall = abi.encodeWithSelector(
            bytes4(keccak256("executeProgramData((bytes32,address,bytes4,bytes)[],uint256,address)")),
            inner, uint256(1_000_000 ether), address(attacker)
        );
        attacker.setReenter(address(executor), reentrantCall);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(0xBEEF), uint256(100 ether), keccak256("ref")));
        steps[1] = _step(RID_ATTACKER, SEL_REENTER, "");

        vm.prank(relayer);
        executor.executeProgramData(steps, 100 ether, relayer);

        assertTrue(attacker.reentrancyAttempted(), "probe should have attempted the nested dispatch");
        assertFalse(attacker.reentrancySucceeded(), "executor nonReentrant must block the nested executeProgramData");
        assertEq(token.balanceOf(address(attacker)), 0, "no counterfeit tokens via nested dispatch");
        assertEq(token.balanceOf(address(0xBEEF)), 100 ether, "legitimate settlement mint lands");
    }

    // =========================================================================
    // Normal operation still works.
    // =========================================================================

    function test_SEC002_normal_dispatch_works() public {
        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](1);
        steps[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(0xBEEF), uint256(100 ether), keccak256("ref")));

        vm.prank(relayer);
        executor.executeProgramData(steps, 100 ether, relayer);

        assertEq(token.balanceOf(address(0xBEEF)), 100 ether, "settlement mint should land");
    }

    function test_SEC002_benign_userStep_works() public {
        // receiveMsgA(string): the origin arrives as the executor-appended tail, not an arg.
        bytes4 selReceive = ArbitraryCallable.receiveMsgA.selector;
        replica.approve(address(attacker), selReceive);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(0xBEEF), uint256(100 ether), keccak256("ref")));
        steps[1] = _step(RID_ATTACKER, selReceive, abi.encode(string("hello")));

        vm.prank(relayer);
        executor.executeProgramData(steps, 100 ether, relayer);

        assertEq(token.balanceOf(address(0xBEEF)), 100 ether, "mint should land");
        assertEq(attacker.message(), "hello", "benign userStep should execute");
    }

    // =========================================================================
    // Standalone exploit contracts (SEC002_CrossMintExploit / SEC002_SingleTxExfil),
    // dispatched as malicious userBlob targets through the real executor.
    // =========================================================================

    /// @notice The SEC002_CrossMintExploit.attack() target re-enters crossMintStandard; the
    ///         `restricted` gate (target is not a relayer) defeats it — no counterfeit mint.
    function test_SEC002_crossMintExploit_contract_is_defeated() public {
        address evilBeneficiary = makeAddr("evilBeneficiary");
        SEC002_CrossMintExploit exploit = new SEC002_CrossMintExploit(
            address(token), address(executor), evilBeneficiary, 1_000_000 ether
        );
        bytes32 ridExploit = keccak256("resource.exploit");
        endpoint.registerResourceId(ridExploit, address(exploit));
        bytes4 selAttack = SEC002_CrossMintExploit.attack.selector;
        replica.approve(address(exploit), selAttack);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(0xBEEF), uint256(100 ether), keccak256("ref")));
        steps[1] = _step(ridExploit, selAttack, "");

        vm.prank(relayer);
        executor.executeProgramData(steps, 100 ether, relayer);

        assertTrue(exploit.reentrancyAttempted(), "exploit should have attempted re-entry");
        assertFalse(exploit.reentrancySucceeded(), "restricted gate must defeat the counterfeit mint");
        assertEq(token.balanceOf(evilBeneficiary), 0, "no counterfeit tokens minted to beneficiary");
    }

    /// @notice The SEC002_SingleTxExfil.attack() target tries to mint-to-self then exfil in one tx.
    ///         The mint re-entry is rejected by `restricted`, so nothing is minted or exfiltrated.
    function test_SEC002_singleTxExfil_contract_is_defeated() public {
        SEC002_SingleTxExfil exploit = new SEC002_SingleTxExfil(
            address(token), 1_000_000 ether, address(0xDe57), 67890
        );
        bytes32 ridExploit = keccak256("resource.exfil");
        endpoint.registerResourceId(ridExploit, address(exploit));
        bytes4 selAttack = SEC002_SingleTxExfil.attack.selector;
        replica.approve(address(exploit), selAttack);

        SharedObjects.EnygmaProgramData[] memory steps = new SharedObjects.EnygmaProgramData[](2);
        steps[0] = _step(RID_TOKEN, SEL_CROSS_MINT_STANDARD, abi.encode(address(0xBEEF), uint256(100 ether), keccak256("ref")));
        steps[1] = _step(ridExploit, selAttack, "");

        vm.prank(relayer);
        executor.executeProgramData(steps, 100 ether, relayer);

        assertTrue(exploit.reentrancyAttempted(), "exploit should have attempted the counterfeit mint");
        assertFalse(exploit.reentrancySucceeded(), "restricted gate must defeat the counterfeit mint");
        assertFalse(exploit.exfiltrationInitiated(), "nothing to exfiltrate when the mint is blocked");
        assertEq(token.balanceOf(address(exploit)), 0, "no counterfeit tokens held by exploit");
    }
}

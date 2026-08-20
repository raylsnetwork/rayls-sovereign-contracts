// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {TokenExample} from "../../../rayls-protocol/test-contracts/TokenExample.sol";
import {RaylsErc20Handler} from "../../../rayls-protocol-sdk/tokens/RaylsErc20Handler.sol";
import "../mocks/MockEndpointForSecurityTest.sol";
import {MockRaylsAppTokenRegistry} from "../mocks/MockRaylsAppTokenRegistry.sol";
import {Constants} from "../../../rayls-protocol-sdk/Constants.sol";

/**
 * @title LockedAmount Accounting Invariants for Teleport Paths
 * @notice Asserts cross-chain token accounting across all paths where
 *         `lockedAmount[user]` is populated. The mapping is incremented in two
 *         structurally different contexts that share the same storage slot:
 *
 *     Bucket (a) - `teleportToPublicChain` / `_lock(user, X)`:
 *         X is transferred from the user to `address(this)` (user balance is
 *         debited), `lockedAmount[user] += X`. Tokens backing the lock sit at
 *         the contract.
 *
 *     Bucket (b) - `receiveTeleportAtomic(user, X)` / `_lockInternal(to, X, false)`:
 *         X is minted to `address(this)` (user balance unchanged),
 *         `lockedAmount[user] += X`. Tokens backing the lock sit at the
 *         contract; the mapping records the user's entitlement to receive X
 *         when `unlock()` fires.
 *
 *   In both buckets the contract holds the backing tokens. Soundness of
 *   teleport() / teleportFrom() / teleportAtomic() / teleportAtomicFrom() burns
 *   is enforced by the ERC20 _burn invariant on the caller's raw balance. The
 *   tests below assert that burns within raw balance do not affect the lock or
 *   the contract-held backing, and that unlock() / revertTeleportBurn() /
 *   receiveTeleportFromPublicChain() close out the lock correctly without
 *   double-counting tokens.
 *
 * PROPERTIES UNDER TEST:
 *   test_B1 - receiveTeleportAtomic state shape (mint to contract, balance untouched).
 *   test_B2 - user can teleport their own balance with pending inbound atomic lock;
 *             the subsequent unlock releases exactly the locked amount.
 *   test_B3 - same property via the third-party teleportFrom path.
 *   test_B4 - teleportAtomic sender never has lockedAmount on the source chain.
 *   test_B5 - revertTeleportBurn drains the contract exactly and does not touch
 *             the user's remaining balance.
 *   test_B6 - teleportToPublicChain(lockAmount) followed by teleport beyond
 *             (balance - lockedAmount) but within raw balance: supply and
 *             accounting invariants hold after the public-chain return path.
 *   test_B7 - a user's ability to teleport their own raw ERC20 balance is not
 *             contingent on the magnitude of `lockedAmount[user]`.
 *   test_B8 - user simultaneously holding both bucket (a) and bucket (b) locks;
 *             global supply and balance invariants hold after teleport + unlocks.
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract LockedAmount_TeleportBurn is Test {
    RaylsAccessManagerV1 public manager;
    TokenExample public token;
    MockEndpointForSecurityTest public mockEndpoint;

    address public owner;
    address public alice; // inbound atomic recipient
    address public bob;   // teleport destination

    uint256 constant CURRENT_CHAIN = 1001;
    uint256 constant DEST_CHAIN    = 3003;
    uint256 constant PH_HUB_CHAIN  = 9999;

    function setUp() public {
        owner = address(this);
        alice = makeAddr("alice");
        bob   = makeAddr("bob");

        // ---- Auth manager ----
        // Test contract is the ADMIN on the manager → admin bypasses all selector
        // role mappings, so we can call `restricted` functions (receiveTeleportAtomic,
        // unlock, revertTeleportBurn, receiveTeleportFromPublicChain) directly.
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));
        manager.registerRole("MESSAGE_EXECUTOR");
        manager.registerRole("RELAYER");

        // ---- ERC20 token ----
        mockEndpoint = new MockEndpointForSecurityTest(CURRENT_CHAIN, PH_HUB_CHAIN);
        mockEndpoint.setAuthority(address(manager));
        mockEndpoint.setTrustedExecutor(owner);

        token = new TokenExample(
            "Tok", "TOK",
            address(mockEndpoint),
            address(0),
            address(0)
        );

        // Register a resourceId so sendTeleport's "Token not registered." guard passes.
        MockRaylsAppTokenRegistry mockRegistry = new MockRaylsAppTokenRegistry();
        mockEndpoint.registerResourceId(Constants.RESOURCE_ID_TOKEN_REGISTRY, address(mockRegistry));
        vm.prank(address(mockRegistry));
        token.setResourceId(keccak256("TOK-resource"));

        // Sanity-check the hardcoded storage slot assumption used by
        // _forceLockedAmountErc20. If any base contract adds a new state variable,
        // the slot shifts and this assertion catches it before tests silently pass.
        address sentinel = address(uint160(uint256(keccak256("slot-sanity"))));
        _forceLockedAmountErc20(sentinel, 1 ether);
        assertEq(
            token.getLockedAmount(sentinel),
            1 ether,
            "lockedAmount slot assumption invalid - update _forceLockedAmountErc20"
        );
        _forceLockedAmountErc20(sentinel, 0);
    }

    /// @notice Baseline: after receiveTeleportAtomic, user has lockedAmount > 0 and
    ///         the contract (address(this)) holds the minted tokens; user balance unchanged.
    function test_B1_inboundAtomicMintsToContract_userBalanceUnchanged() public {
        uint256 lockValue = 100 ether;

        uint256 userBalBefore = token.balanceOf(alice);
        uint256 ctBalBefore   = token.balanceOf(address(token));

        token.receiveTeleportAtomic(alice, lockValue);

        assertEq(token.balanceOf(alice), userBalBefore, "user balance unchanged");
        assertEq(token.balanceOf(address(token)), ctBalBefore + lockValue, "contract holds minted tokens");
        assertEq(token.getLockedAmount(alice), lockValue, "lockedAmount set");
    }

    /// @notice A user with a pending inbound atomic lock teleports their own balance;
    ///         the subsequent unlock still releases the locked amount to the user.
    function test_B2_userCanTeleportOwnBalanceWithPendingInboundAtomic_noDoubleSpend() public {
        uint256 realBalance = 100 ether;
        uint256 pendingLock = 100 ether;

        token.fakeMint(alice, realBalance);
        token.receiveTeleportAtomic(alice, pendingLock);

        assertEq(token.balanceOf(alice), realBalance, "alice has real balance");
        assertEq(token.getLockedAmount(alice), pendingLock, "alice has pending lock");
        assertEq(token.balanceOf(address(token)), pendingLock, "contract holds locked tokens");

        vm.prank(alice);
        token.teleport(bob, realBalance, DEST_CHAIN);

        assertEq(token.balanceOf(alice), 0, "alice burned her own balance");
        assertEq(token.getLockedAmount(alice), pendingLock, "pending lock unchanged");
        assertEq(token.balanceOf(address(token)), pendingLock, "contract still holds the locked tokens");

        token.unlock(alice, pendingLock);

        assertEq(token.balanceOf(alice), pendingLock, "alice received unlocked tokens");
        assertEq(token.getLockedAmount(alice), 0, "lock cleared");
        assertEq(token.balanceOf(address(token)), 0, "contract balance drained exactly");
    }

    /// @notice Third-party teleportFrom variant. Same outcome expected.
    function test_B3_thirdPartyTeleportFrom_withPendingLock_noDoubleSpend() public {
        address spender = makeAddr("spender");
        uint256 realBalance = 100 ether;
        uint256 pendingLock = 50 ether;

        token.fakeMint(alice, realBalance);
        token.receiveTeleportAtomic(alice, pendingLock);

        vm.prank(alice);
        token.approve(spender, realBalance);

        vm.prank(spender);
        token.teleportFrom(alice, bob, realBalance, DEST_CHAIN);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.getLockedAmount(alice), pendingLock);
        assertEq(token.balanceOf(address(token)), pendingLock);

        token.unlock(alice, pendingLock);

        assertEq(token.balanceOf(alice), pendingLock);
        assertEq(token.getLockedAmount(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// @notice teleportAtomic path: burns from sender. lockedAmount for sender is NEVER set
    ///         by sending atomic (only by receiving). So no "committed tokens" exist for sender.
    function test_B4_atomicSenderNeverHasLockOnSourceChain() public {
        uint256 realBalance = 100 ether;
        token.fakeMint(alice, realBalance);

        assertEq(token.getLockedAmount(alice), 0, "no lock before atomic send");

        vm.prank(alice);
        token.teleportAtomic(bob, realBalance, DEST_CHAIN);

        assertEq(token.balanceOf(alice), 0, "alice burned");
        assertEq(token.getLockedAmount(alice), 0, "sender has no lock on source");
    }

    /// @notice Revert-on-atomic path: sender's tokens are re-minted on revert.
    ///         Verifies that the removed check does not interact badly with revert flow.
    function test_B5_revertTeleportBurn_afterUserBurnedOwnBalance_clearsContractCorrectly() public {
        uint256 realBalance = 100 ether;
        uint256 pendingLock = 40 ether;

        token.fakeMint(alice, realBalance);
        token.receiveTeleportAtomic(alice, pendingLock);

        vm.prank(alice);
        token.teleport(bob, realBalance, DEST_CHAIN);

        uint256 supplyBeforeRevert = token.totalSupply();

        // Atomic fails on origin chain → revertTeleportBurn fires here:
        // _unlock then _burn(address(this), value)
        token.revertTeleportBurn(alice, pendingLock);

        assertEq(token.getLockedAmount(alice), 0, "lock cleared");
        assertEq(token.balanceOf(address(token)), 0, "contract drained");
        assertEq(token.balanceOf(alice), 0, "alice still 0 (she spent her real balance)");
        assertEq(token.totalSupply(), supplyBeforeRevert - pendingLock, "supply burned atomically");
    }

    /// @notice teleportToPublicChain establishes a bucket (a) lock, then a teleport
    ///         larger than (balance - locked) but still within raw balance is issued.
    ///         Asserts global supply invariant after the public-chain return path unlocks.
    /// @dev Scenario:
    ///         1. alice starts with `origBalance`.
    ///         2. teleportToPublicChain(lockAmount) simulated via storage write +
    ///            transfer(alice, address(token), lockAmount). End state:
    ///              alice.balance  = origBalance - lockAmount
    ///              alice.locked   = lockAmount
    ///              contract       = lockAmount
    ///         3. teleportAmount = (balance - locked) + 1 ether, which is <= raw balance.
    ///         4. alice teleports teleportAmount to a second chain.
    ///         5. receiveTeleportFromPublicChain(alice, lockAmount) releases the lock.
    ///         6. Assert supply invariant: supply delta matches the mint and burn deltas.
    function test_B6_teleportToPublicChainThenTeleportBeyondAvailable() public {
        uint256 origBalance = 90 ether;
        uint256 lockAmount  = 30 ether;

        uint256 supplyPre = token.totalSupply();
        token.fakeMint(alice, origBalance);

        _forceLockedAmountErc20(alice, lockAmount);
        vm.prank(alice);
        token.transfer(address(token), lockAmount);

        uint256 newBalance = token.balanceOf(alice);
        uint256 newLocked  = token.getLockedAmount(alice);
        uint256 newAvailable = newBalance - newLocked;

        assertEq(newBalance, origBalance - lockAmount, "balance reduced by lock");
        assertEq(newLocked, lockAmount, "locked == lockAmount");
        assertEq(newAvailable, origBalance - 2 * lockAmount, "available == balance - locked");
        assertEq(token.balanceOf(address(token)), lockAmount, "contract holds locked tokens");

        uint256 teleportAmount = newAvailable + 1 ether;
        assertTrue(teleportAmount <= newBalance, "teleport amount must be within raw balance");

        vm.prank(alice);
        token.teleport(bob, teleportAmount, DEST_CHAIN);

        assertEq(token.balanceOf(alice), newBalance - teleportAmount, "origin balance reduced by teleport");
        assertEq(token.getLockedAmount(alice), lockAmount, "lock unchanged by user teleport");
        assertEq(token.balanceOf(address(token)), lockAmount, "contract-held backing unchanged");

        // Public-chain return path: simulate receiveTeleportFromPublicChain for lockAmount.
        token.receiveTeleportFromPublicChain(alice, lockAmount);

        assertEq(token.getLockedAmount(alice), 0, "lock released");
        assertEq(token.balanceOf(address(token)), 0, "contract fully drained");

        uint256 aliceFinalOrigin = token.balanceOf(alice);
        assertEq(aliceFinalOrigin, origBalance - teleportAmount, "origin balance matches expected");

        // Global accounting across all chains:
        //   alice.origin = origBalance - teleportAmount
        //   alice.dest   = teleportAmount (virtually; not tracked in this mock)
        //   alice.public = 0 (burned to trigger return)
        //   Sum = origBalance ✓
        //
        // Supply invariant on this contract: fakeMint added origBalance, then teleport
        // burned teleportAmount from alice. Contract-held lock tokens were transferred
        // out (not burned). Net supply delta = origBalance - teleportAmount.
        assertEq(
            token.totalSupply(),
            supplyPre + origBalance - teleportAmount,
            "supply invariant: fakeMint(origBalance) - teleport burn(teleportAmount)"
        );
    }

    /// @notice A user's ability to teleport their own raw ERC20 balance must not be
    ///         contingent on the value of `lockedAmount[user]`. This test asserts the
    ///         property against an arbitrarily large lockedAmount value.
    function test_B7_largeLockedAmountDoesNotBlockTeleportOfOwnBalance() public {
        uint256 victimBal = 100 ether;
        uint256 largeLock = 10_000 ether;

        token.fakeMint(alice, victimBal);
        token.receiveTeleportAtomic(alice, largeLock);

        vm.prank(alice);
        token.teleport(bob, victimBal, DEST_CHAIN);

        assertEq(token.balanceOf(alice), 0, "user can teleport their own balance regardless of lockedAmount size");
    }

    /// @notice Exercises a user simultaneously holding both bucket (a) (balance-debiting)
    ///         and bucket (b) (atomic entitlement) locks. Asserts balance, lock, contract,
    ///         and global supply invariants after unlock paths close both locks.
    function test_B8_combinedLockSources_accountingHolds() public {
        uint256 initial = 100 ether;
        uint256 publicChainLock = 30 ether;   // bucket (a): teleportToPublicChain
        uint256 atomicInbound   = 70 ether;   // bucket (b): receiveTeleportAtomic

        uint256 supplyPre = token.totalSupply();  // TokenExample constructor pre-mints to deployer
        token.fakeMint(alice, initial);

        // Bucket (a) simulation: teleportToPublicChain is onlyRegisteredUsers and not wired
        // in this mock, so simulate its end state with a storage write + explicit transfer:
        //    1. Set lockedAmount[alice] = publicChainLock via vm.store
        //    2. Transfer publicChainLock from alice to address(token) (mirroring _lock's transfer)
        _forceLockedAmountErc20(alice, publicChainLock);
        vm.prank(alice);
        token.transfer(address(token), publicChainLock);

        // Bucket (b): atomic inbound (real path).
        token.receiveTeleportAtomic(alice, atomicInbound);

        uint256 expectedAliceBal = initial - publicChainLock;
        uint256 expectedLock = publicChainLock + atomicInbound;
        uint256 expectedCtBal = publicChainLock + atomicInbound;
        assertEq(token.balanceOf(alice), expectedAliceBal);
        assertEq(token.getLockedAmount(alice), expectedLock);
        assertEq(token.balanceOf(address(token)), expectedCtBal);

        vm.prank(alice);
        token.teleport(bob, expectedAliceBal, DEST_CHAIN);
        assertEq(token.balanceOf(alice), 0);

        // Unlocks: each source path uses _unlock independently.
        token.receiveTeleportFromPublicChain(alice, publicChainLock); // bucket (a) return
        token.unlock(alice, atomicInbound);                           // bucket (b) unlock

        assertEq(token.balanceOf(alice), publicChainLock + atomicInbound);
        assertEq(token.getLockedAmount(alice), 0);
        assertEq(token.balanceOf(address(token)), 0);

        // Global supply invariant:
        //   supply delta = fakeMint(initial) + atomicInbound mint - alice teleport burn
        //                = initial + atomicInbound - expectedAliceBal
        //   (constructor pre-mint captured in supplyPre)
        assertEq(
            token.totalSupply(),
            supplyPre + initial + atomicInbound - expectedAliceBal,
            "global supply invariant holds"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev TokenExample `lockedAmount` mapping sits at base slot 12 per `forge inspect`.
    function _forceLockedAmountErc20(address account, uint256 amount) internal {
        bytes32 slot = keccak256(abi.encode(account, uint256(12)));
        vm.store(address(token), slot, bytes32(amount));
    }
}

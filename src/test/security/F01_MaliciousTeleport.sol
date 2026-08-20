// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title F01_MaliciousTeleport
 * @notice ATTACKER-CONTROLLED IMPLEMENTATION used by the F01
 *         catastrophic-upgrade E2E reproduction. Demonstrates that once an
 *         attacker can swap a UUPS proxy's implementation via the
 *         schedule+execute bypass, they can install ARBITRARY logic that
 *         hijacks every selector the proxy was deployed to expose.
 *
 * KEY PROPERTIES (designed for the test):
 *   - contractVersion() returns the sentinel POISONED_VERSION (0x4ADDABBA). The
 *     legitimate TeleportV1 returns 1; this contract overrides that with a
 *     same-shape function that returns the sentinel. A successful upgrade is
 *     therefore observable by reading contractVersion() on the proxy.
 *   - _authorizeUpgrade is PERMISSIVE so the test's `after` hook (or any
 *     caller) can restore the original TeleportV1 implementation without
 *     needing to bypass anything. This keeps the test reentrant and avoids
 *     leaving the live network in a broken state if the test fails halfway.
 *   - constructor calls _disableInitializers() — required for any UUPS
 *     implementation contract.
 *
 * STORAGE LAYOUT NOTES:
 *   The legitimate TeleportV1 has the following storage tail in slot order:
 *     headers (mapping)       — slot 0
 *     singleHeader (mapping)  — slot 1
 *     atomicTeleportMessages  — slot 2
 *     AtomicStatus            — slot 3
 *   This malicious impl declares NO storage of its own, so the proxy's
 *   pre-upgrade storage is preserved and not corrupted by the upgrade.
 *   When the proxy is later restored to the original TeleportV1 impl, the
 *   storage layout is again correctly interpreted by the original code.
 *   (RaylsAccessManaged uses ERC-7201 namespaced storage and is therefore
 *   collision-free; we simply do not interact with it here.)
 *
 * SECURITY FLAGS:
 *   - This file MUST live under src/test/security/ so it is visible to the
 *     contracts-repo Foundry suite and gets rsync'd into the e2e repo's
 *     contracts/remote/ via scripts/sync-contracts-local.sh. It is NOT a
 *     production contract.
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
contract F01_MaliciousTeleport is Initializable, UUPSUpgradeable {
    uint256 public constant POISONED_VERSION = 0x4ADDABBA;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Hijacked getter — replaces TeleportV1's `contractVersion()` (legit returns 1).
    function contractVersion() external pure returns (uint256) {
        return POISONED_VERSION;
    }

    /// Permissive — anyone can swap the implementation again. This is by
    /// design so the test can restore the legitimate impl in `after`.
    function _authorizeUpgrade(address /*newImplementation*/) internal pure override {
        // intentionally empty
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRaylsAccessManager} from "./interfaces/IRaylsAccessManager.sol";
import {IRaylsAccessManaged} from "./interfaces/IRaylsAccessManaged.sol";

/// @title RaylsAccessManaged
/// @notice Abstract mixin that consumer contracts inherit to integrate with RaylsAccessManagerV1.
///
///         Replaces scattered `onlyOwner` guards with a single `restricted` modifier.
///         The modifier calls `canCall(msg.sender, address(this), msg.sig)` on the authority
///         and reverts if the call is denied or requires a delay (scheduled execution path).
///
/// @dev Storage isolation: uses its own ERC-7201 namespace so it can be safely composed
///      with any existing contract storage layout without collision.
///
///      Bootstrap (Phase 2): call `_initializeAuthority(manager)` inside a `reinitializer`
///      function on the consumer contract, invoked atomically via `upgradeToAndCall`.
///      After initialization, future authority changes require ADMIN on the manager.
abstract contract RaylsAccessManaged is IRaylsAccessManaged {
    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────

    /// @notice Emitted when `restricted` denies a call.
    error RaylsAccessManaged__Unauthorized(address caller);

    /// @notice Emitted when an authority address fails validation.
    error RaylsAccessManaged__InvalidAuthority(address authority);

    /// @notice Emitted when a caller with a non-zero execution delay tries to call
    ///         directly instead of going through schedule/execute.
    error RaylsAccessManaged__MustSchedule(address caller, uint32 delay);

    /// @notice The managed contract is emergency-paused. All restricted calls are blocked.
    error RaylsAccessManaged__ContractPaused();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────

    event AuthorityUpdated(address indexed oldAuthority, address indexed newAuthority);

    // ─────────────────────────────────────────────────────────────
    //  ERC-7201 Storage
    // ─────────────────────────────────────────────────────────────

    /// @custom:storage-location erc7201:rayls.storage.RaylsAccessManaged
    struct AccessManagedStorage {
        address _authority;
    }

    bytes32 private constant ACCESS_MANAGED_STORAGE =
        keccak256(abi.encode(uint256(keccak256("erc7201:rayls.storage.RaylsAccessManaged")) - 1))
        & ~bytes32(uint256(0xff));

    function _getManagedStorage() private pure returns (AccessManagedStorage storage $) {
        bytes32 slot = ACCESS_MANAGED_STORAGE;
        /// @solidity memory-safe-assembly
        assembly {
            $.slot := slot
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Modifier
    // ─────────────────────────────────────────────────────────────

    /// @notice Gate for governance functions. Delegates authorization to the authority.
    ///         - Reverts with `RaylsAccessManaged__Unauthorized` if denied.
    ///         - Reverts with `RaylsAccessManaged__MustSchedule` if the role requires a delay.
    modifier restricted() {
        _checkCanCall(msg.sender, msg.sig);
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  External View
    // ─────────────────────────────────────────────────────────────

    /// @inheritdoc IRaylsAccessManaged
    function authority() public view virtual returns (address) {
        return _getManagedStorage()._authority;
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────────────────────

    /// @dev One-time authority initializer. Should be called from a `reinitializer` on
    ///      the consumer contract to atomically set the authority after a UUPS upgrade.
    ///      Reverts if an authority is already set.
    function _initializeAuthority(address authority_) internal {
        AccessManagedStorage storage $ = _getManagedStorage();
        if ($._authority != address(0)) revert RaylsAccessManaged__InvalidAuthority(authority_);
        _setAuthority(authority_);
    }

    /// @dev Unconditionally update the authority. Emits AuthorityUpdated.
    function _setAuthority(address newAuthority) internal {
        if (newAuthority == address(0)) revert RaylsAccessManaged__InvalidAuthority(newAuthority);
        AccessManagedStorage storage $ = _getManagedStorage();
        emit AuthorityUpdated($._authority, newAuthority);
        $._authority = newAuthority;
    }

    /// @dev Core authorization check. Calls `canCall` on the authority.
    function _checkCanCall(address caller, bytes4 selector) internal view {
        AccessManagedStorage storage $ = _getManagedStorage();
        address auth = $._authority;
        if (auth == address(0)) revert RaylsAccessManaged__InvalidAuthority(address(0));

        (bool allowed, uint32 delay, bool paused) = IRaylsAccessManager(auth).canCall(
            caller,
            address(this),
            selector
        );

        if (!allowed) {
            if (paused) revert RaylsAccessManaged__ContractPaused();
            if (delay != 0) revert RaylsAccessManaged__MustSchedule(caller, delay);
            revert RaylsAccessManaged__Unauthorized(caller);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IRaylsAccessManager} from "../interfaces/IRaylsAccessManager.sol";
import {
    AccessManagerStorage,
    MemberData,
    RoleData,
    ManagedContractConfig,
    ADMIN,
    PUBLIC,
    TOKEN_OWNER,
    _getStorage,
    _roleIdToBitmap,
    _checkIsContractAuthority,
    RaylsAccessManagerV1__ZeroAddress,
    RaylsAccessManagerV1__ContractAlreadyRegistered,
    RaylsAccessManagerV1__ContractNotRegistered,
    RaylsAccessManagerV1__RoleNotRegistered,
    RaylsAccessManagerV1__PublicRoleCannotBeGranted,
    RaylsAccessManagerV1__AdminRoleCannotBeScoped
} from "../AccessManagerTypes.sol";

/// @title AccessManagerContractScopedLib
/// @notice External library for contract-scoped grant management.
///         Called via delegatecall — shares the facade's storage context.
library AccessManagerContractScopedLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    event FunctionAllowedRoleAdded(address indexed managedContract, bytes4 indexed selector, uint64 indexed roleId);
    event ManagedContractRegistered(address indexed managedContract, address indexed contractAuthority);
    event ContractScopedRoleGranted(
        uint64 indexed roleId, address indexed account, address indexed managedContract,
        uint32 executionDelay, uint48 activeSince, address grantor
    );
    event ContractScopedRoleRevoked(
        uint64 indexed roleId, address indexed account, address indexed managedContract, address revoker
    );

    function selfRegisterManagedContract(
        address deployer,
        bytes4[] calldata ownerSelectors,
        IRaylsAccessManager.SelectorRoleMapping[] calldata roleMappings
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        if (deployer == address(0)) revert RaylsAccessManagerV1__ZeroAddress();
        address token = msg.sender;

        if ($._managedContracts[token].selfRegistered) {
            revert RaylsAccessManagerV1__ContractAlreadyRegistered(token);
        }
        $._managedContracts[token].selfRegistered = true;

        ManagedContractConfig storage mc = $._managedContracts[token];

        // Map owner selectors to TOKEN_OWNER.
        {
            (uint256 toSegIdx, uint256 toBitMask) = _roleIdToBitmap(TOKEN_OWNER);
            for (uint256 i; i < ownerSelectors.length; ++i) {
                bytes4 sel = ownerSelectors[i];
                mc.allowedRoleSummary[sel] |= (1 << toSegIdx);
                mc.allowedRoleSegments[sel][toSegIdx] |= toBitMask;
                emit FunctionAllowedRoleAdded(token, sel, TOKEN_OWNER);
            }
        }

        // Map additional role selectors — each entry looked up by name from the registry.
        for (uint256 r; r < roleMappings.length; ++r) {
            bytes32 nameHash = keccak256(bytes(roleMappings[r].roleName));
            uint64 roleId = $._roleNameToId[nameHash];
            if (roleId == 0) revert RaylsAccessManagerV1__RoleNotRegistered(roleMappings[r].roleName);

            (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
            for (uint256 i; i < roleMappings[r].selectors.length; ++i) {
                bytes4 sel = roleMappings[r].selectors[i];
                mc.allowedRoleSummary[sel] |= (1 << segIdx);
                mc.allowedRoleSegments[sel][segIdx] |= bitMask;
                emit FunctionAllowedRoleAdded(token, sel, roleId);
            }
        }

        // Set deployer as contract authority.
        mc.contractAuthority = deployer;

        // Grant deployer TOKEN_OWNER scoped to this token.
        _grantTokenOwnerScoped($, deployer, token);

        emit ManagedContractRegistered(token, deployer);
    }

    /// @notice Grant TOKEN_OWNER scoped to `msg.sender` for `account`, callable only by an
    ///         already self-registered managed contract. Does NOT change the contract authority.
    /// @dev Lets a token instance hand TOKEN_OWNER to an additional address (e.g. the deployer
    ///      EOA when it differs from the configured owner) after `selfRegisterManagedContract`,
    ///      without altering the shared registration signature or the authority wallet.
    /// @param account The address receiving TOKEN_OWNER scoped to the calling contract.
    function grantSelfTokenOwner(address account) external {
        AccessManagerStorage storage $ = _getStorage();
        if (account == address(0)) revert RaylsAccessManagerV1__ZeroAddress();
        address token = msg.sender;
        if (!$._managedContracts[token].selfRegistered) {
            revert RaylsAccessManagerV1__ContractNotRegistered(token);
        }
        _grantTokenOwnerScoped($, account, token);
    }

    /// @dev Grant TOKEN_OWNER to `account` scoped to `token`: writes the member grant, sets the
    ///      contract-scoped bitmap, adds to the member set, and emits {ContractScopedRoleGranted}.
    ///      Shared by {selfRegisterManagedContract} and {grantSelfTokenOwner}. Idempotent —
    ///      re-granting an existing member is a harmless no-op write.
    function _grantTokenOwnerScoped(
        AccessManagerStorage storage $,
        address account,
        address token
    ) private {
        $._roles[TOKEN_OWNER].contractScopedGrants[account][token] = MemberData({
            activeSince: uint48(block.timestamp),
            executionDelay: 0
        });

        (uint256 toSegIdx, uint256 toBitMask) = _roleIdToBitmap(TOKEN_OWNER);
        $._contractScopedGrantSummary[account][token] |= (1 << toSegIdx);
        $._contractScopedGrantSegments[account][token][toSegIdx] |= toBitMask;

        $._contractScopedRoleMembers[TOKEN_OWNER][token].add(account);

        emit ContractScopedRoleGranted(TOKEN_OWNER, account, token, 0, uint48(block.timestamp), token);
    }

    function grantContractScopedRole(
        uint64 roleId,
        address account,
        address managedContract,
        uint32 executionDelay
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        if (roleId == PUBLIC) revert RaylsAccessManagerV1__PublicRoleCannotBeGranted();
        if (roleId == ADMIN) revert RaylsAccessManagerV1__AdminRoleCannotBeScoped();
        _checkIsContractAuthority($, msg.sender, managedContract);

        RoleData storage role = $._roles[roleId];
        uint48 activeSince = uint48(block.timestamp) + role.grantDelay;

        role.contractScopedGrants[account][managedContract] = MemberData({
            activeSince: activeSince,
            executionDelay: executionDelay
        });

        (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
        $._contractScopedGrantSummary[account][managedContract] |= (1 << segIdx);
        $._contractScopedGrantSegments[account][managedContract][segIdx] |= bitMask;

        $._contractScopedRoleMembers[roleId][managedContract].add(account);

        emit ContractScopedRoleGranted(roleId, account, managedContract, executionDelay, activeSince, msg.sender);
    }

    function revokeContractScopedRole(
        uint64 roleId,
        address account,
        address managedContract
    ) external {
        AccessManagerStorage storage $ = _getStorage();
        _checkIsContractAuthority($, msg.sender, managedContract);

        delete $._roles[roleId].contractScopedGrants[account][managedContract];

        (uint256 segIdx, uint256 bitMask) = _roleIdToBitmap(roleId);
        uint256 newSegment = $._contractScopedGrantSegments[account][managedContract][segIdx] & ~bitMask;
        $._contractScopedGrantSegments[account][managedContract][segIdx] = newSegment;
        if (newSegment == 0) {
            $._contractScopedGrantSummary[account][managedContract] &= ~(1 << segIdx);
        }

        $._contractScopedRoleMembers[roleId][managedContract].remove(account);

        emit ContractScopedRoleRevoked(roleId, account, managedContract, msg.sender);
    }

    function hasContractScopedRole(
        uint64 roleId,
        address account,
        address managedContract
    ) external view returns (bool isMember, uint32 executionDelay) {
        AccessManagerStorage storage $ = _getStorage();
        MemberData storage m = $._roles[roleId].contractScopedGrants[account][managedContract];
        if (m.activeSince == 0 || m.activeSince > block.timestamp) return (false, 0);
        return (true, m.executionDelay);
    }

    function getContractAuthority(
        address managedContract
    ) external view returns (address) {
        AccessManagerStorage storage $ = _getStorage();
        return $._managedContracts[managedContract].contractAuthority;
    }
}

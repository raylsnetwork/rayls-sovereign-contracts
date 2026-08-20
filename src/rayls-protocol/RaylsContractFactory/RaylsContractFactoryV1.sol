// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IRaylsEndpoint} from "../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol";
import {IRaylsAccessManager} from "../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import {RaylsTrustedInit} from "../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {AbstractContractFactoryV1} from "./AbstractContractFactoryV1.sol";
import {IRaylsContractFactoryV1} from "./interfaces/IRaylsContractFactoryV1.sol";

/**
 * @title RaylsContractFactoryV1
 * @notice Hub CREATE2 factory for Rayls handlers.
 * @dev Deploy logic, the open bytecode registry, and the typed deploy functions all live in
 *      {AbstractContractFactoryV1}. This subclass specialises trusted-init (sourcing
 *      `userGovernance` from the endpoint via {IRaylsEndpoint} and `raylsNodeEndpoint` from state) and grants the
 *      ENDPOINT_SENDER role to every deployed contract in `_afterDeploy`.
 */
contract RaylsContractFactoryV1 is AbstractContractFactoryV1, IRaylsContractFactoryV1 {
    /// @notice Thrown when `getRoleIdByName(...)` returns 0 (PUBLIC_ROLE) — usually means the
    ///         role wasn't registered on the AccessManager. Granting role 0 would silently
    ///         broaden access to everyone.
    /// @param roleName The role name that resolved to 0.
    error RaylsContractFactoryV1__RoleNotRegistered(string roleName);

    /// @notice Privacy-node endpoint address injected into trusted-init.
    /// @dev Sits after the base contract's reserved `__gap` — never reorder existing base/child slots.
    address public raylsNodeEndpoint;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the hub factory.
     * @param _endpoint Trusted Rayls endpoint address (non-zero).
     * @param _raylsNodeEndpoint Privacy-node endpoint address.
     * @param _owner Factory owner injected into trusted-init (non-zero).
     * @param authority_ AccessManager address used for `restricted` gating.
     */
    function initialize(address _endpoint, address _raylsNodeEndpoint, address _owner, address authority_)
        public
        initializer
    {
        if (_raylsNodeEndpoint == address(0)) revert FactoryV1__ZeroAddress();
        __AbstractFactory_init(_endpoint, _owner, authority_);
        raylsNodeEndpoint = _raylsNodeEndpoint;
    }

    /// @inheritdoc IRaylsContractFactoryV1
    function setRaylsNodeEndpoint(address newEndpoint) external override restricted {
        if (newEndpoint == address(0)) revert FactoryV1__ZeroAddress();
        emit RaylsNodeEndpointUpdated(raylsNodeEndpoint, newEndpoint);
        raylsNodeEndpoint = newEndpoint;
    }

    /// @inheritdoc IRaylsContractFactoryV1
    function getRaylsNodeEndpoint() external view override returns (address) {
        return raylsNodeEndpoint;
    }

    /// @inheritdoc AbstractContractFactoryV1
    function _buildTrustedInit(bytes32 resourceId)
        internal
        view
        override
        returns (RaylsTrustedInit memory)
    {
        return RaylsTrustedInit({
            endpoint: endpoint,
            raylsNodeEndpoint: raylsNodeEndpoint,
            userGovernance: IRaylsEndpoint(endpoint).getUserGovernanceAddress(),
            owner: factoryOwner,
            resourceId: resourceId,
            // msg.sender is preserved across the internal _deployContract -> _buildTrustedInit
            // calls (no external hop), so this is the original factory caller — never user-forged.
            caller: msg.sender
        });
    }

    /// @inheritdoc AbstractContractFactoryV1
    /// @dev Auto-grant ENDPOINT_SENDER to the deployed contract so it can call restricted
    ///      send functions on the endpoint. Factory holds FACTORY_ADMIN, the admin of
    ///      ENDPOINT_SENDER. Removal would require an alternative grant path for every
    ///      consumer flow (notably cross-chain auto-deploy which has no other grant site
    ///      for receiver-side instances).
    function _afterDeploy(address deployed) internal override {
        address manager = IRaylsEndpoint(endpoint).authority();
        uint64 roleId = IRaylsAccessManager(manager).getRoleIdByName("ENDPOINT_SENDER");
        if (roleId == 0) revert RaylsContractFactoryV1__RoleNotRegistered("ENDPOINT_SENDER");
        IRaylsAccessManager(manager).grantRole(roleId, deployed, 0);
    }
}

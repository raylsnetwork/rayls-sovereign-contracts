// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IBaseContractFactory} from "../../../rayls-protocol/RaylsContractFactory/interfaces/IBaseContractFactory.sol";

/**
 * @title IRNContractFactoryV1
 * @notice Privacy-node contract factory interface.
 * @dev Extends {IBaseContractFactory} with the owner-attested deploy entrypoint used by the
 *      registry-driven FACTORY-mode activation path, and with the `raylsNodeEndpoint` reference
 *      (the RNEndpointV1) stamped into trusted-init so deployed handlers can dispatch
 *      `teleportToPublicChain`.
 */
interface IRNContractFactoryV1 is IBaseContractFactory {
    /// @notice A receiver-side deploy produced a Rayls token that must be recorded as a hub mirror,
    ///         but no PN TokenRegistry is wired (`setTokenRegistry` never called). Fail-loud: leaving
    ///         the mirror unregistered would break its hub authorization.
    error FactoryV1__TokenRegistryNotSet();

    /**
     * @notice Deploy a seeded standard with an explicit owner override.
     * @dev Sets the next deploy's owner (TOKEN_OWNER + owner-gated selectors such as mint/burn)
     *      to `ownerEOA` instead of the factory owner. Used by the receiver-side teleport
     *      auto-deploy so the attested source-chain owner is mirrored.
     * @param resourceId Resource id the deployed instance binds to.
     * @param factoryKey Seeded factory bytecode key for the standard.
     * @param ownerEOA   Address that becomes the deployed instance's owner.
     * @param userArgs   ABI-encoded init args for the standard's `initialize`.
     * @return deployed Address of the freshly deployed instance.
     */
    function deployFromTeleport(bytes32 resourceId, bytes32 factoryKey, address ownerEOA, bytes calldata userArgs)
        external
        returns (address deployed);

    /// @notice Set the PN TokenRegistry the factory records receiver-side mirrors in.
    /// @param tokenRegistry PN TokenRegistry facade address (non-zero).
    function setTokenRegistry(address tokenRegistry) external;

    /// @notice Emitted when the privacy-node endpoint injected into trusted-init is updated.
    /// @param oldEndpoint Previous privacy-node endpoint address.
    /// @param newEndpoint New privacy-node endpoint address.
    event RaylsNodeEndpointUpdated(address indexed oldEndpoint, address indexed newEndpoint);

    /// @notice Emitted when the PN TokenRegistry reference is updated.
    /// @param oldRegistry Previous TokenRegistry address.
    /// @param newRegistry New TokenRegistry address.
    event TokenRegistrySet(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Update the privacy-node endpoint injected into trusted-init.
    /// @param newEndpoint New privacy-node endpoint address (non-zero).
    function setRaylsNodeEndpoint(address newEndpoint) external;

    /// @notice The privacy-node endpoint address injected into trusted-init.
    function getRaylsNodeEndpoint() external view returns (address);
}

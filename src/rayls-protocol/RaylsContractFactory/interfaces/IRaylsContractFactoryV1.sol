// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IBaseContractFactory} from "./IBaseContractFactory.sol";

/**
 * @title IRaylsContractFactoryV1
 * @notice Hub contract factory interface.
 * @dev Extends {IBaseContractFactory} with the hub-only `raylsNodeEndpoint` reference used
 *      when assembling trusted-init.
 */
interface IRaylsContractFactoryV1 is IBaseContractFactory {
    /// @notice Emitted when the privacy-node endpoint injected into trusted-init is updated.
    /// @param oldEndpoint Previous privacy-node endpoint address.
    /// @param newEndpoint New privacy-node endpoint address.
    event RaylsNodeEndpointUpdated(address indexed oldEndpoint, address indexed newEndpoint);

    /// @notice Update the privacy-node endpoint injected into trusted-init.
    /// @param newEndpoint New privacy-node endpoint address (non-zero).
    function setRaylsNodeEndpoint(address newEndpoint) external;

    /// @notice The privacy-node endpoint address injected into trusted-init.
    function getRaylsNodeEndpoint() external view returns (address);
}

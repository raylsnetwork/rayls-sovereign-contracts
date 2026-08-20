// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @notice Trusted addresses + resourceId injected by the contract factory at deploy time.
 * @dev Populated by the factory from on-chain state; never user-controlled.
 *      `raylsNodeEndpoint` is the privacy-node `RNEndpointV1` (stamped by `RNContractFactoryV1`);
 *      handlers dispatch `teleportToPublicChain` through it.
 *      `caller` is the `msg.sender` of the factory `deploy*()` call (the address that
 *      requested the deploy); it is set by the factory, never from `userArgs`, so it
 *      cannot be forged. Handlers grant it `TOKEN_OWNER` in addition to `owner`.
 */
struct RaylsTrustedInit {
    address endpoint;
    address raylsNodeEndpoint;
    address userGovernance;
    address owner;
    bytes32 resourceId;
    // The external caller that triggered this deploy (factory's `msg.sender`). Used by handlers
    // to additionally grant TOKEN_OWNER to the deployer when it differs from `owner`. Factory-set,
    // never user-controlled. `address(0)` on the constructor (non-factory) path.
    address caller;
}

/**
 * @title IRaylsInitializer
 * @notice Canonical init entrypoint for every contract deployable via the Rayls factories.
 *
 * @dev `userArgs` is opaque ABI-encoded bytes. Each handler decodes the shape it expects
 *      (e.g. ERC20 decodes `(string,string,uint8)`; ERC721 decodes `(string,string,string)`;
 *      a future ERC4626 vault could decode `(address,uint256,bytes32)` — no factory or
 *      interface change needed). The factory dispatches the same fixed selector regardless
 *      of standard.
 */
interface IRaylsInitializer {
    /**
     * @notice Initialize a freshly deployed Rayls handler.
     * @param userArgs Handler-specific ABI-encoded user arguments. Decoded by the handler
     *                 itself (e.g. `abi.decode(userArgs, (string,string,uint8))` for ERC20).
     *                 Caller-supplied — never trust without decoding.
     * @param trusted  Trusted addresses + resourceId set by the factory at deploy time
     *                 (see {RaylsTrustedInit}). Caller cannot forge these fields.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) external;
}

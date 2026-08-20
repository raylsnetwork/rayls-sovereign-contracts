// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IBaseContractFactory
 * @notice Shared surface for the Rayls contract factories (privacy-node and hub).
 *
 * @dev Both {RNContractFactoryV1} and {RaylsContractFactoryV1} expose this interface via
 *      their concrete interfaces. It defines three deploy paths that all converge on the
 *      canonical `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)` entrypoint:
 *
 *        - `deploy`            raw bytecode supplied by the caller
 *        - `deployRegistered`  bytecode pre-registered under a `bytes32` key
 *        - typed sugar         `deployErc20` … `deployErc1155Dvp` over `deployRegistered`
 *
 *      The bytecode registry is an open `bytes32 => bytes` map: any restricted caller may
 *      register any bytecode under any key, so a new standard needs no upgrade — just
 *      `setBytecode(key, bytecode)` followed by `deployRegistered(key, …)`. The well-known
 *      protocol standards use the predefined `*_KEY` constants below.
 */
interface IBaseContractFactory {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The deployed contract's `initialize` call reverted with no return data.
    error FactoryV1__InitializationFailed();

    /// @notice `deploy` was called with empty bytecode.
    error FactoryV1__EmptyBytecode();

    /// @notice `deployRegistered` was called for a key with no registered bytecode.
    /// @param key The unregistered key.
    error FactoryV1__BytecodeNotRegistered(bytes32 key);

    /// @notice A zero address was supplied where a non-zero address is required.
    error FactoryV1__ZeroAddress();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on `deploy` — the raw-bytecode path.
    /// @param deployedAddress Address of the contract that was created.
    /// @param resourceId Resource identifier passed into trusted-init (`bytes32(0)` if unassigned).
    event ContractDeployed(address indexed deployedAddress, bytes32 indexed resourceId);

    /// @notice Emitted on `deployRegistered` and every typed deploy function.
    /// @param key The registry key whose bytecode was deployed.
    /// @param deployedAddress Address of the contract that was created.
    /// @param resourceId Resource identifier passed into trusted-init (`bytes32(0)` if unassigned).
    event RegisteredContractDeployed(
        bytes32 indexed key,
        address indexed deployedAddress,
        bytes32 indexed resourceId
    );

    /// @notice Emitted when a bytecode is registered, updated, or cleared.
    /// @param key The registry key.
    /// @param bytecodeHash `keccak256` of the stored bytecode (`bytes32(0)` when cleared).
    event BytecodeSet(bytes32 indexed key, bytes32 bytecodeHash);

    /// @notice Emitted when `factoryOwner` changes.
    /// @param oldOwner Previous owner.
    /// @param newOwner New owner.
    event FactoryOwnerUpdated(address indexed oldOwner, address indexed newOwner);

    /// @notice Emitted when `endpoint` changes.
    /// @param oldEndpoint Previous endpoint.
    /// @param newEndpoint New endpoint.
    event EndpointUpdated(address indexed oldEndpoint, address indexed newEndpoint);

    /*//////////////////////////////////////////////////////////////
                        WELL-KNOWN KEY CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /* solhint-disable func-name-mixedcase */
    function RAYLS_ERC20_KEY() external view returns (bytes32);
    function RAYLS_ERC721_KEY() external view returns (bytes32);
    function RAYLS_ERC1155_KEY() external view returns (bytes32);
    function RAYLS_ENYGMA_KEY() external view returns (bytes32);
    function RAYLS_ERC721_DVP_KEY() external view returns (bytes32);
    function RAYLS_ERC1155_DVP_KEY() external view returns (bytes32);
    function RAYLS_STABLECOIN_KEY() external view returns (bytes32);
    /* solhint-enable func-name-mixedcase */

    /*//////////////////////////////////////////////////////////////
                            DEPLOY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a contract from caller-supplied runtime bytecode.
    /// @param bytecode Runtime bytecode to deploy (must be non-empty).
    /// @param userArgs ABI-encoded handler-specific init args (no selector prefix).
    /// @param resourceId Resource identifier; `bytes32(0)` means "unassigned".
    /// @return deployedAddress Address of the newly deployed contract.
    function deploy(bytes calldata bytecode, bytes calldata userArgs, bytes32 resourceId)
        external
        returns (address deployedAddress);

    /// @notice Protocol-facing variant of `deploy`. Same behaviour on the base factory; exposed as a
    ///         distinct selector so the receiver-side auto-deploy path can be gated independently and
    ///         so concrete factories may record the deploy in a resource registry.
    /// @param bytecode Runtime bytecode to deploy (must be non-empty).
    /// @param userArgs ABI-encoded handler-specific init args (no selector prefix).
    /// @param resourceId Resource identifier; `bytes32(0)` means "unassigned".
    /// @return deployedAddress Address of the newly deployed contract.
    function deployExternal(bytes calldata bytecode, bytes calldata userArgs, bytes32 resourceId)
        external
        returns (address deployedAddress);

    /// @notice Deploy a contract from bytecode previously registered under `key`.
    /// @param key Registry key (well-known constant or a custom `bytes32`).
    /// @param userArgs ABI-encoded handler-specific init args (no selector prefix).
    /// @param resourceId Resource identifier; `bytes32(0)` means "unassigned".
    /// @return deployedAddress Address of the newly deployed contract.
    function deployRegistered(bytes32 key, bytes calldata userArgs, bytes32 resourceId)
        external
        returns (address deployedAddress);

    /// @notice Protocol-facing variant of `deployRegistered`. Same behaviour on the base factory;
    ///         exposed as a distinct selector so the receiver-side auto-deploy path can be gated
    ///         independently and so concrete factories may record the deploy in a resource registry.
    /// @param key Registry key (well-known constant or a custom `bytes32`).
    /// @param userArgs ABI-encoded handler-specific init args (no selector prefix).
    /// @param resourceId Resource identifier; `bytes32(0)` means "unassigned".
    /// @return deployedAddress Address of the newly deployed contract.
    function deployRegisteredExternal(bytes32 key, bytes calldata userArgs, bytes32 resourceId)
        external
        returns (address deployedAddress);

    /// @notice Typed sugar over `deployRegistered(RAYLS_ERC20_KEY, abi.encode(name, symbol, decimals), …)`.
    function deployErc20(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId)
        external
        returns (address);

    /// @notice Typed sugar over `deployRegistered(RAYLS_ERC721_KEY, abi.encode(uri, name, symbol), …)`.
    function deployErc721(string calldata uri, string calldata name, string calldata symbol, bytes32 resourceId)
        external
        returns (address);

    /// @notice Typed sugar over `deployRegistered(RAYLS_ERC1155_KEY, abi.encode(uri, name), …)`.
    function deployErc1155(string calldata uri, string calldata name, bytes32 resourceId)
        external
        returns (address);

    /// @notice Typed sugar over `deployRegistered(RAYLS_ENYGMA_KEY, abi.encode(name, symbol, decimals), …)`.
    function deployEnygma(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId)
        external
        returns (address);

    /// @notice Typed sugar over `deployRegistered(RAYLS_STABLECOIN_KEY, abi.encode(name, symbol, decimals), …)`.
    function deployStableCoin(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId)
        external
        returns (address);

    /// @notice Typed sugar over `deployRegistered(RAYLS_ERC721_DVP_KEY, abi.encode(uri, name, symbol), …)`.
    function deployErc721Dvp(string calldata uri, string calldata name, string calldata symbol, bytes32 resourceId)
        external
        returns (address);

    /// @notice Typed sugar over `deployRegistered(RAYLS_ERC1155_DVP_KEY, abi.encode(uri, name), …)`.
    function deployErc1155Dvp(string calldata uri, string calldata name, bytes32 resourceId)
        external
        returns (address);

    /*//////////////////////////////////////////////////////////////
                        REGISTRY & ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register, update, or clear (empty bytes) the bytecode stored under `key`.
    /// @param key Registry key.
    /// @param bytecode Runtime bytecode; pass empty to clear the key.
    function setBytecode(bytes32 key, bytes calldata bytecode) external;

    /// @notice Update the factory owner injected into trusted-init.
    /// @param newOwner New owner (non-zero).
    function setFactoryOwner(address newOwner) external;

    /// @notice Update the endpoint injected into trusted-init.
    /// @param newEndpoint New endpoint (non-zero).
    function setEndpoint(address newEndpoint) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice `keccak256` of the bytecode registered under `key`, or `bytes32(0)` if unset.
    function getBytecodeHash(bytes32 key) external view returns (bytes32);

    /// @notice The endpoint address injected into trusted-init.
    function getEndpoint() external view returns (address);

    /// @notice The factory owner address injected into trusted-init.
    function getFactoryOwner() external view returns (address);

    /// @notice Contract version.
    function contractVersion() external pure returns (uint256);
}

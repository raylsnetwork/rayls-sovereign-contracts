// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../interfaces/IEnygmaTokenManager.sol';
import '../../interfaces/ITokenRegistry.sol';
import '../../../../rayls-protocol-sdk/RaylsAppV1.sol';
import '../../../../rayls-protocol-sdk/Constants.sol';
import '../../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '../../../../rayls-protocol/Enygma/Enygma-Payments/EnygmaFactory.sol';

/**
 * @title EnygmaTokenManagerV1
 * @dev Module responsible for managing Enygma-specific token functionality in the Rayls protocol.
 *
 * This contract handles the specialized operations for Enygma tokens, which are privacy-focused
 * tokens with advanced cryptographic features. It manages Enygma token registration, freezing,
 * and integration with the Enygma factory system.
 *
 * Key features:
 * - Enygma token registration and lifecycle management
 * - Enygma token freezing/unfreezing functionality
 * - Integration with Enygma factory for token creation
 * - Cross-chain communication for Enygma token operations
 * - DVP integration management
 *
 * The contract works in conjunction with the Enygma factory to create and manage
 * privacy-enhanced tokens with zero-knowledge proof capabilities.
 *
 */
contract EnygmaTokenManagerV1 is Initializable, IEnygmaTokenManager, UUPSUpgradeable, RaylsAccessManaged {
    // ========== Storage Variables ==========

    /// @notice Address of the main TokenRegistry contract
    address public tokenRegistryAddress;

    /// @notice Address of the main TokenCore contract
    address public tokenCoreAddress;

    /// @notice Address of the endpoint contract
    IRaylsEndpoint public endpoint;

    /// @notice Address of the Enygma factory contract
    address public enygmaFactory;

    /// @notice Resource ID for this contract
    bytes32 public resourceId;

    // ========== Events ==========

    /**
     * @notice Emitted when the Enygma factory address is updated
     * @param oldFactory The previous Enygma factory address
     * @param newFactory The new Enygma factory address
     */
    event EnygmaFactoryUpdated(address indexed oldFactory, address indexed newFactory);

    /**
     * @notice Emitted when an Enygma token is registered
     * @param resourceId The resource ID of the registered Enygma token
     * @param issuerChainId The chain ID of the token issuer
     * @param blockNumber The block number when the token was registered
     * @param name The name of the Enygma token
     * @param initialSupply The initial supply of the Enygma token
     */
    event EnygmaTokenRegistered(bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256 initialSupply);

    // ========== Modifiers ==========

    /// @notice Thrown when a non-TokenRegistry / non-TokenCore caller invokes a guarded function.
    /// @param caller Calling address.
    error EnygmaTokenManagerV1__UnauthorizedCaller(address caller);

    /// @notice Thrown when a setter receives the zero address.
    error EnygmaTokenManagerV1__ZeroAddress();

    /**
     * @notice Restrict a function to the TokenRegistry contract.
     * @dev Reverts with `EnygmaTokenManagerV1__UnauthorizedCaller(msg.sender)` otherwise.
     */
    modifier onlyTokenRegistry() {
        if (msg.sender != tokenRegistryAddress) {
            revert EnygmaTokenManagerV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /**
     * @notice Restrict a function to the TokenCore contract.
     * @dev Reverts with `EnygmaTokenManagerV1__UnauthorizedCaller(msg.sender)` otherwise.
     */
    modifier onlyTokenCore() {
        if (msg.sender != tokenCoreAddress) {
            revert EnygmaTokenManagerV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ========== Initialization ==========

    /**
     * @notice Initializes the EnygmaTokenManager contract
     * @dev This function can only be called once during contract deployment
     * @param _endpoint The address of the Rayls endpoint for cross-chain communication
     * @param _tokenRegistryAddress The address of the TokenRegistry contract
     * @param _enygmaFactory The address of the Enygma factory contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _endpoint, address _tokenRegistryAddress, address _enygmaFactory, address authority_) public initializer {
        __UUPSUpgradeable_init();
        endpoint = IRaylsEndpoint(_endpoint);
        tokenRegistryAddress = _tokenRegistryAddress;
        enygmaFactory = _enygmaFactory;
        _initializeAuthority(authority_);
    }

    /**
     * @notice OZ UUPS upgrade authorization hook.
     * @dev Required by the OZ UUPS module. Parameter `newImplementation` is intentionally
     *      anonymous — gating is selector-based via `_checkCanCall(msg.sender, msg.sig)`,
     *      so the implementation address is unused.
     */
    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }

    // ========== Module Configuration ==========

    /**
     * @notice Sets the TokenRegistry address
     * @dev Access-controlled via RaylsAccessManager
     * @param _tokenRegistryAddress The address of the TokenRegistry contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _tokenRegistryAddress must be non-zero
     */
    function setTokenRegistryAddress(address _tokenRegistryAddress) external virtual restricted {
        if (_tokenRegistryAddress == address(0)) revert EnygmaTokenManagerV1__ZeroAddress();
        tokenRegistryAddress = _tokenRegistryAddress;
    }

    /**
     * @notice Sets the TokenCore address
     * @dev Access-controlled via RaylsAccessManager
     * @param _tokenCoreAddress The address of the TokenCore contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _tokenCoreAddress must be non-zero
     */
    function setTokenCoreAddress(address _tokenCoreAddress) external virtual restricted {
        if (_tokenCoreAddress == address(0)) revert EnygmaTokenManagerV1__ZeroAddress();
        tokenCoreAddress = _tokenCoreAddress;
    }

    // ========== Enygma Token Management ==========

    /**
     * @notice Updates the Enygma factory address
     * @dev Updates the reference to the Enygma factory and emits an event
     * @param _enygmaFactory The new address of the Enygma factory
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     * - _enygmaFactory must be non-zero
     */
    function setEnygmaFactory(address _enygmaFactory) external virtual onlyTokenRegistry {
        if (_enygmaFactory == address(0)) revert EnygmaTokenManagerV1__ZeroAddress();
        address oldFactory = enygmaFactory;
        enygmaFactory = _enygmaFactory;
        emit EnygmaFactoryUpdated(oldFactory, _enygmaFactory);
    }

    /**
     * @notice Sets the endpoint address
     * @dev Access-controlled via RaylsAccessManager
     * @param _endpoint The address of the Rayls endpoint
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _endpoint must be non-zero
     */
    function setEndpoint(address _endpoint) external virtual restricted {
        if (_endpoint == address(0)) revert EnygmaTokenManagerV1__ZeroAddress();
        endpoint = IRaylsEndpoint(_endpoint);
    }

    /**
     * @notice Gets the Enygma factory address
     * @dev Returns the current address of the Enygma factory contract
     * @return The address of the Enygma factory
     */
    function getEnygmaFactory() external view virtual returns (address) {
        return enygmaFactory;
    }

    /**
     * @notice Registers a new Enygma token
     * @dev Creates a new Enygma token through the factory, sets up DVP integration,
     *      adds verifiers, and registers the token with the endpoint. Restricted to
     *      TokenCore via the `onlyTokenCore` modifier.
     *
     *      The third parameter (`totalSupply`) is intentionally anonymous — initial
     *      supply is not used during Enygma creation; the actual decoded supply is
     *      taken from `tokenData.totalSupply` at emit time.
     *
     * @param _resourceId The resource ID for the new Enygma token.
     * @param tokenData The token registration data containing all necessary information.
     * @param owner The address of the token owner.
     * @param participantStorage The address of the participant storage contract.
     *
     * Requirements:
     * - Caller must be the TokenCore contract.
     * - All parameters must be valid.
     * - Enygma factory must be properly configured.
     */
    function registerEnygmaToken(
        bytes32 _resourceId,
        SharedObjects.TokenRegistrationData calldata tokenData,
        uint256 /* totalSupply */,
        address owner,
        address participantStorage
    ) external virtual onlyTokenCore {
        EnygmaFactory enygmaFactoryInstance = EnygmaFactory(enygmaFactory);

        // Step 1: Create the Enygma token and register it.
        // `initializerParams` is bare ABI-encoded `(string name, string symbol, uint8 decimals)`
        // produced by the PN `TokenCoreV1._buildInitializerParams` — no selector prefix
        // (canonical `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)` dispatch).
        (, , uint8 _tokenDecimals) = abi.decode(tokenData.initializerParams, (string, string, uint8));
        EnygmaInitParams memory params = EnygmaInitParams({
            name: tokenData.name,
            symbol: tokenData.symbol,
            decimals: _tokenDecimals,
            resourceId: _resourceId,
            owner: owner,
            ownerChainId: tokenData.issuerChainId,
            participantStorageAddress: participantStorage,
            endpoint: address(endpoint),
            tokenRegistry: tokenRegistryAddress,
            treeDepth: Constants.DVP_MERKLE_TREE_DEPTH
        });

        enygmaFactoryInstance.initiateEnygmaCreation(params);

        // Get the final Enygma address and register it
        address enygmaAddress = enygmaFactoryInstance.getEnygmaAddress(_resourceId);

        endpoint.registerResourceId(_resourceId, enygmaAddress);

        emit EnygmaTokenRegistered(_resourceId, tokenData.issuerChainId, block.number, tokenData.name, abi.decode(tokenData.totalSupply, (uint256)));
    }
}

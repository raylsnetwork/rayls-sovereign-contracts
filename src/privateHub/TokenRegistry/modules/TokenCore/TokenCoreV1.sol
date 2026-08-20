// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/ITokenCore.sol";
import "../../interfaces/ITokenRegistry.sol";
import "../../interfaces/ITokenFreezeManager.sol";
import "../../interfaces/IEnygmaTokenManager.sol";
import "../../libraries/TokenStructs.sol";
import "../../../ParticipantStorage/libraries/ParticipantStructs.sol";
import "../../../ParticipantStorage/interfaces/IParticipantStorage.sol";
import "../../../ResourceRegistry/ResourceRegistryV1.sol";
import "../../../../rayls-protocol-sdk/RaylsAppV1.sol";
import "../../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import "../../../../rayls-protocol-sdk/Constants.sol";
import "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "../../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc721PNH.sol";
import "../../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc1155PNH.sol";
import "../../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc721Factory.sol";
import "../../../../rayls-protocol/Enygma/Enygma-DVP/DvpErc1155Factory.sol";

/**
 * @title TokenCoreV1
 * @dev Module responsible for core token management functionality in the Rayls protocol.
 *
 * This contract handles the fundamental operations for token registration, management,
 * and lifecycle within the Rayls ecosystem. It serves as the central registry for all
 * tokens and manages their status, metadata, and balance updates.
 *
 * Key features:
 * - Token registration and lifecycle management
 * - Token status updates (NEW, ACTIVE, INACTIVE)
 * - Balance update tracking and broadcasting
 * - Integration with Enygma token management
 * - Participant validation and authorization
 *
 * The contract maintains a comprehensive registry of all tokens with their associated
 * metadata and provides cross-chain communication capabilities for token operations.
 *
 */
contract TokenCoreV1 is Initializable, ITokenCore, UUPSUpgradeable, RaylsAccessManaged, ReentrancyGuardUpgradeable {
    // ========== Storage Variables ==========

    /// @notice Mapping from resource ID to token index in the registered tokens list
    mapping(bytes32 => uint256) internal tokenIndexByResourceId;

    /// @notice Mapping to track registered token names to prevent duplicates
    mapping(string => bool) internal isTokenNameRegistered;

    // ========== External Contract References ==========

    /// @notice Address of the main TokenRegistry contract
    address public tokenRegistryAddress;

    /// @notice Array containing all registered tokens
    TokenStructs.Token[] internal registeredTokensList;

    /// @notice Address of the ParticipantStorage contract
    IParticipantStorage public participantStorage;

    /// @notice Reference to the ResourceRegistry contract
    ResourceRegistryV1 public resourceRegistry;

    /// @notice Address of the EnygmaTokenManager contract
    IEnygmaTokenManager public enygmaTokenManager;

    /// @notice Reference to the Rayls endpoint for cross-chain communication
    IRaylsEndpoint public endpoint;

    /// @notice Resource ID for this contract
    bytes32 public resourceId;

    /// @notice Address of the EnygmaFactorySettings contract
    address public enygmaFactorySettingsAddress;

    /// @notice Address of the DvpSettings contract
    address public dvpSettingsAddress;

    /// @notice Address of the DvpErc721Factory contract
    address public dvpErc721FactoryAddress;

    /// @notice Address of the DvpErc1155Factory contract
    address public dvpErc1155FactoryAddress;

    // ========== Custom Errors ==========

    /// @notice Error thrown when attempting to register a token with a duplicate name
    error TokenNameDuplicate();

    /// @notice Error thrown when a token is not found in the registry
    error TokenNotFound();

    /// @notice Error thrown when attempting to set a token status to its current value
    error TokenStatusAlreadySet();

    /// @notice Error thrown when an unauthorized participant attempts to perform an action
    error UnauthorizedParticipant();

    // ========== Events ==========

    /**
     * @notice Emitted when an ERC20 token is registered
     * @param resourceId The unique resource identifier of the token
     * @param issuerChainId The chain ID of the token issuer
     * @param blockNumber The block number when the token was registered
     * @param name The name of the token
     * @param initialSupply The initial supply of the token
     */
    event Erc20TokenRegistered(
        bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256 initialSupply
    );

    /**
     * @notice Emitted when an ERC721 token is registered
     * @param resourceId The unique resource identifier of the token
     * @param issuerChainId The chain ID of the token issuer
     * @param blockNumber The block number when the token was registered
     * @param name The name of the token
     * @param initialSupply Array of initial token IDs
     */
    event Erc721TokenRegistered(
        bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256[] initialSupply
    );

    /**
     * @notice Emitted when a Dvp ERC721 token is registered
     * @param resourceId The unique resource identifier of the token
     * @param issuerChainId The chain ID of the token issuer
     * @param blockNumber The block number when the token was registered
     * @param name The name of the token
     * @param initialSupply Array of initial token IDs
     */
    event DvpErc721TokenRegistered(
        bytes32 resourceId, uint256 indexed issuerChainId, uint256 blockNumber, string name, uint256[] initialSupply
    );
    /**
     * @notice Emitted when an ERC1155 token is registered
     * @param resourceId The unique resource identifier of the token
     * @param issuerChainId The chain ID of the token issuer
     * @param blockNumber The block number when the token was registered
     * @param name The name of the token
     * @param initialSupply Array of initial supply data for each token ID
     */
    event Erc1155TokenRegistered(
        bytes32 resourceId,
        uint256 indexed issuerChainId,
        uint256 blockNumber,
        string name,
        SharedObjects.ERC1155Supply[] initialSupply
    );

    /**
     * @notice Emitted when a Dvp ERC1155 token is registered
     * @param resourceId The unique resource identifier of the token
     * @param issuerChainId The chain ID of the token issuer
     * @param blockNumber The block number when the token was registered
     * @param name The name of the token
     * @param initialSupply Array of initial supply data for each token ID
     */
    event DvpErc1155TokenRegistered(
        bytes32 resourceId,
        uint256 indexed issuerChainId,
        uint256 blockNumber,
        string name,
        SharedObjects.ERC1155Supply[] initialSupply
    );

    /**
     * @notice Emitted when a token status is updated
     * @param issuerChainId The chain ID of the token issuer
     * @param name The name of the token
     * @param status The new status of the token
     */
    event TokenStatusUpdated(uint256 issuerChainId, string name, TokenStructs.TokenStatus status);

    /**
     * @notice Emitted when a token balance is updated
     * @param resourceId The unique resource identifier of the token
     * @param issuerChainId The chain ID of the token issuer
     * @param updateType The type of balance update (mint, burn, etc.)
     * @param payload The balance update payload containing amount and ERC ID
     */
    event TokenBalanceUpdated(
        bytes32 resourceId,
        uint256 issuerChainId,
        SharedObjects.BalanceUpdateType updateType,
        TokenStructs.BalanceUpdate payload
    );

    // ========== Modifiers ==========

    /// @notice Thrown when a non-TokenRegistry caller invokes a guarded function.
    /// @param caller Calling address.
    error TokenCoreV1__UnauthorizedCaller(address caller);

    /**
     * @notice Restrict a function to the TokenRegistry contract.
     * @dev Reverts with `TokenCoreV1__UnauthorizedCaller(msg.sender)` otherwise.
     */
    modifier onlyTokenRegistry() {
        if (msg.sender != tokenRegistryAddress) {
            revert TokenCoreV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    // ========== Initialization ==========

    /**
     * @notice Initializes the TokenCore contract
     * @dev This function can only be called once during contract deployment
     * @param _tokenRegistryAddress The address of the TokenRegistry contract
     * @param _participantStorage The address of the ParticipantStorage contract
     * @param _resourceRegistry The address of the ResourceRegistry contract
     * @param _enygmaTokenManager The address of the EnygmaTokenManager contract
     * @param _endpoint The address of the Rayls endpoint
     * @param _enygmaFactorySettingsAddress The address of the EnygmaFactorySettings contract
     * @param _dvpSettingsAddress The address of the DvpSettings contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(
        address _tokenRegistryAddress,
        address _participantStorage,
        address _resourceRegistry,
        address _enygmaTokenManager,
        address _endpoint,
        address _enygmaFactorySettingsAddress,
        address _dvpSettingsAddress,
        address authority_
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        tokenRegistryAddress = _tokenRegistryAddress;
        participantStorage = IParticipantStorage(_participantStorage);
        resourceRegistry = ResourceRegistryV1(_resourceRegistry);
        enygmaTokenManager = IEnygmaTokenManager(_enygmaTokenManager);
        endpoint = IRaylsEndpoint(_endpoint);
        enygmaFactorySettingsAddress = _enygmaFactorySettingsAddress;
        dvpSettingsAddress = _dvpSettingsAddress;
        resourceId = Constants.RESOURCE_ID_TOKEN_REGISTRY;
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
        require(_tokenRegistryAddress != address(0), "TokenCore: TokenRegistry address cannot be zero");
        tokenRegistryAddress = _tokenRegistryAddress;
    }

    /**
     * @notice Sets the ParticipantStorage address
     * @dev Access-controlled via RaylsAccessManager
     * @param _participantStorage The address of the ParticipantStorage contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _participantStorage must be non-zero
     */
    function setParticipantStorage(address _participantStorage) external virtual restricted {
        require(_participantStorage != address(0), "TokenCore: ParticipantStorage address cannot be zero");
        participantStorage = IParticipantStorage(_participantStorage);
    }

    /**
     * @notice Sets the ResourceRegistry address
     * @dev Access-controlled via RaylsAccessManager
     * @param _resourceRegistry The address of the ResourceRegistry contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _resourceRegistry must be non-zero
     */
    function setResourceRegistry(address _resourceRegistry) external virtual restricted {
        require(_resourceRegistry != address(0), "TokenCore: ResourceRegistry address cannot be zero");
        resourceRegistry = ResourceRegistryV1(_resourceRegistry);
    }

    /**
     * @notice Sets the EnygmaTokenManager address
     * @dev Access-controlled via RaylsAccessManager
     * @param _enygmaTokenManager The address of the EnygmaTokenManager contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _enygmaTokenManager must be non-zero
     */
    function setEnygmaTokenManager(address _enygmaTokenManager) external virtual restricted {
        require(_enygmaTokenManager != address(0), "TokenCore: EnygmaTokenManager address cannot be zero");
        enygmaTokenManager = IEnygmaTokenManager(_enygmaTokenManager);
    }

    /**
     * @notice Sets the EnygmaFactorySettings address
     * @dev Access-controlled via RaylsAccessManager
     * @param _enygmaFactorySettingsAddress The address of the EnygmaFactorySettings contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _enygmaFactorySettingsAddress must be non-zero
     */
    function setEnygmaFactorySettingsAddress(address _enygmaFactorySettingsAddress) external virtual restricted {
        require(_enygmaFactorySettingsAddress != address(0), "TokenCore: EnygmaFactorySettings address cannot be zero");
        enygmaFactorySettingsAddress = _enygmaFactorySettingsAddress;
    }

    /**
     * @notice Sets the DvpSettings address
     * @dev Access-controlled via RaylsAccessManager
     * @param _dvpSettingsAddress The address of the DvpSettings contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _dvpSettingsAddress must be non-zero
     */
    function setDvpSettingsAddress(address _dvpSettingsAddress) external virtual restricted {
        require(_dvpSettingsAddress != address(0), "TokenCore: DvpSettings address cannot be zero");
        dvpSettingsAddress = _dvpSettingsAddress;
    }

    /**
     * @notice Sets the endpoint address
     * @dev Access-controlled via RaylsAccessManager. Also sets the resource ID.
     * @param _endpoint The address of the Rayls endpoint
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _endpoint must be non-zero
     */
    function setEndpoint(address _endpoint) external virtual restricted {
        require(_endpoint != address(0), "TokenCore: Endpoint address cannot be zero");
        endpoint = IRaylsEndpoint(_endpoint);
        resourceId = Constants.RESOURCE_ID_TOKEN_REGISTRY;
    }

    /**
     * @notice Sets the DvpErc721Factory address
     * @dev Access-controlled via RaylsAccessManager
     * @param _dvpErc721FactoryAddress The address of the DvpErc721Factory contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _dvpErc721FactoryAddress must be non-zero
     */
    function setDvpErc721FactoryAddress(address _dvpErc721FactoryAddress) external virtual restricted {
        require(_dvpErc721FactoryAddress != address(0), "TokenCore: DvpErc721Factory address cannot be zero");
        dvpErc721FactoryAddress = _dvpErc721FactoryAddress;
    }

    /**
     * @notice Sets the DvpErc1155Factory address
     * @dev Access-controlled via RaylsAccessManager
     * @param _dvpErc1155FactoryAddress The address of the DvpErc1155Factory contract
     *
     * Requirements:
     * - Caller must have the appropriate role in the access manager
     * - _dvpErc1155FactoryAddress must be non-zero
     */
    function setDvpErc1155FactoryAddress(address _dvpErc1155FactoryAddress) external virtual restricted {
        require(_dvpErc1155FactoryAddress != address(0), "TokenCore: DvpErc1155Factory address cannot be zero");
        dvpErc1155FactoryAddress = _dvpErc1155FactoryAddress;
    }

    // ========== Token Management ==========

    /**
     * @notice Registers a new token in the registry
     * @dev Validates the issuer participant, checks for duplicate names, registers the resource,
     * initializes token data, and finalizes the registration process
     * @param tokenData The token registration data containing all necessary information
     * @param owner The address of the token owner
     * @return The resource ID of the newly registered token
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     * - Issuer must be an active participant
     * - Token name must not be duplicate
     */
    function addToken(SharedObjects.TokenRegistrationData calldata tokenData, address owner)
        external
        virtual
        onlyTokenRegistry
        nonReentrant
        returns (bytes32)
    {
        if (!isActiveIssuerParticipant(tokenData.issuerChainId)) {
            revert UnauthorizedParticipant();
        }

        if (isTokenNameRegistered[tokenData.name] != false) {
            revert TokenNameDuplicate();
        }

        bytes32 _resourceId =
            resourceRegistry.registerResource(tokenData.ercStandard, tokenData.bytecode, tokenData.initializerParams);

        _initializeTokenData(tokenData, _resourceId, owner);
        _finalizeTokenRegistration(tokenData, _resourceId, owner);

        return _resourceId;
    }

    /**
     * @notice Retrieves token information by its resource ID
     * @dev Searches for the token in the registry and returns its complete information
     * @param _resourceId The unique resource identifier of the token
     * @return The complete token information
     *
     * Requirements:
     * - Token must exist in the registry
     */
    function getTokenByResourceId(bytes32 _resourceId) external view virtual returns (TokenStructs.Token memory) {
        return _getTokenByResourceId(_resourceId);
    }

    /**
     * @notice Retrieves all registered tokens
     * @dev Returns the complete list of all tokens in the registry
     * @return Array of all registered tokens
     */
    function getAllTokens() external view virtual returns (TokenStructs.Token[] memory) {
        return registeredTokensList;
    }

    /**
     * @notice Updates the status of a registered token
     * @dev Changes the token status and emits an event. If status is set to ACTIVE,
     * sends a cross-chain message to the issuer
     * @param _resourceId The resource ID of the token to update
     * @param status The new status to set for the token
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     * - Token must exist in the registry
     * - New status must be different from current status
     */
    function updateStatus(bytes32 _resourceId, TokenStructs.TokenStatus status) external virtual onlyTokenRegistry {
        TokenStructs.Token storage token = _getTokenByResourceId(_resourceId);
        if (token.status == status) {
            revert TokenStatusAlreadySet();
        }
        token.status = status;
        token.updatedAt = block.timestamp;
        emit TokenStatusUpdated(token.issuerChainId, token.name, status);
        if (token.status == TokenStructs.TokenStatus.ACTIVE) {
            // The activation callback targets the issuer PN's TokenRegistry facade
            // (`pnRegistryAddress`) in the modular PN architecture. Tokens carry a pre-deployed
            // issuer-side instance (`tokenAddress`), which the callback activates in place.
            endpoint.send(
                token.issuerChainId,
                token.pnRegistryAddress,
                abi.encodeWithSignature(
                    "activateToken(bytes32,address,uint8)",
                    token.resourceId,
                    token.tokenAddress,
                    uint8(token.ercStandard)
                )
            );
        }
    }

    /**
     * @notice Updates token balance and emits an event
     * @dev Decodes the metadata based on the token's ERC standard and emits
     * a balance update event with the decoded information
     * @param issuerChainId The chain ID of the token issuer
     * @param _resourceId The resource ID of the token
     * @param updateType The type of balance update (mint, burn, etc.)
     * @param metadata Additional metadata for the balance update
     *
     * Requirements:
     * - Caller must be the TokenRegistry contract
     * - Token must exist in the registry
     * - Token's ERC standard must be supported
     */
    function updateTokenBalance(
        uint256 issuerChainId,
        bytes32 _resourceId,
        SharedObjects.BalanceUpdateType updateType,
        bytes memory metadata
    ) external virtual onlyTokenRegistry {
        TokenStructs.Token storage token = _getTokenByResourceId(_resourceId);

        uint256 amount;
        uint256 ercId = 0;

        SharedObjects.ErcStandard standard = _baseStandard(token.ercStandard);
        if (standard == SharedObjects.ErcStandard.ERC20) {
            amount = abi.decode(metadata, (uint256));
        } else if (standard == SharedObjects.ErcStandard.ERC721) {
            ercId = abi.decode(metadata, (uint256));
            amount = 1;
        } else if (standard == SharedObjects.ErcStandard.ERC1155) {
            SharedObjects.ERC1155Supply memory supply = abi.decode(metadata, (SharedObjects.ERC1155Supply));
            amount = supply.amount;
            ercId = supply.id;
        } else if (standard == SharedObjects.ErcStandard.DvpERC721) {
            ercId = abi.decode(metadata, (uint256));
            amount = 1;
        } else if (standard == SharedObjects.ErcStandard.DvpERC1155) {
            SharedObjects.ERC1155Supply memory supply = abi.decode(metadata, (SharedObjects.ERC1155Supply));
            amount = supply.amount;
            ercId = supply.id;
        } else {
            revert("Unsupported ERC standard");
        }

        TokenStructs.BalanceUpdate memory payload = TokenStructs.BalanceUpdate({amount: amount, ercId: ercId});

        emit TokenBalanceUpdated(_resourceId, issuerChainId, updateType, payload);
    }

    /**
     * @notice Checks if a participant is an active issuer
     * @dev Queries the ParticipantStorage contract to verify if the given chain ID
     * corresponds to an active issuer participant
     * @param chainId The chain ID of the participant to check
     * @return True if the participant is an active issuer, false otherwise
     */
    function isActiveIssuerParticipant(uint256 chainId) public view virtual returns (bool) {
        ParticipantStructs.Participant memory participant = participantStorage.getParticipant(chainId);
        return
            participant.role == ParticipantStructs.Role.ISSUER && participant.status == ParticipantStructs.Status.ACTIVE;
    }

    // ========== Internal Functions ==========

    /**
     * @notice Initializes token data in the registry, decoding metadata from initializerParams.
     * @dev Decodes URI/decimals from `initializerParams` per ercStandard, pushes the token
     *      record, and sets the duplicate-name + index lookups.
     * @param tokenData The token registration data.
     * @param _resourceId The resource ID assigned to the token.
     * @param _issuerImplementationAddress The address of the issuer implementation on its chain.
     */
    function _initializeTokenData(
        SharedObjects.TokenRegistrationData calldata tokenData,
        bytes32 _resourceId,
        address _issuerImplementationAddress
    ) internal {
        string memory url = "";
        uint8 decimals = 0;

        if (!tokenData.isCustom) {
            // `initializerParams` is bare ABI-encoded handler args (no leading selector
            // prefix) — see the PN `TokenCoreV1._buildInitializerParams` and the
            // canonical `IRaylsInitializer.initialize(bytes,RaylsTrustedInit)` dispatch
            // in RaylsContractFactoryV1 / RNContractFactoryV1.
            SharedObjects.ErcStandard standard = _baseStandard(tokenData.ercStandard);
            if (
                standard == SharedObjects.ErcStandard.ERC1155 || standard == SharedObjects.ErcStandard.ERC721
            ) {
                (string memory urlFrominitializerParams,) = abi.decode(tokenData.initializerParams, (string, string));
                url = urlFrominitializerParams;
            } else if (
                standard == SharedObjects.ErcStandard.ERC20 || standard == SharedObjects.ErcStandard.Enygma
            ) {
                (,, uint8 tokenDecimals) = abi.decode(tokenData.initializerParams, (string, string, uint8));
                decimals = tokenDecimals;
            }
        }

        registeredTokensList.push(
            TokenStructs.Token({
                resourceId: _resourceId,
                status: TokenStructs.TokenStatus.NEW,
                name: tokenData.name,
                issuerChainId: tokenData.issuerChainId,
                symbol: tokenData.symbol,
                isFungible: tokenData.isFungible,
                issuerImplementationAddress: _issuerImplementationAddress,
                pnRegistryAddress: tokenData.pnRegistryAddress,
                tokenAddress: tokenData.tokenAddress,
                createdAt: block.timestamp,
                updatedAt: block.timestamp,
                metadata: TokenStructs.TokenMetadata({url: url, decimals: decimals}),
                ercStandard: tokenData.ercStandard
            })
        );
        isTokenNameRegistered[tokenData.name] = true;
        tokenIndexByResourceId[_resourceId] = registeredTokensList.length;
    }

    /**
     * @notice Finalize token registration: emit per-standard registered events and route
     *         non-trivial standards (DvpERC721/DvpERC1155 via factory creation; Enygma via
     *         the EnygmaTokenManager) to their downstream init.
     * @dev Reverts on unsupported ERC standards.
     * @param tokenData The token registration data.
     * @param _resourceId The resource ID assigned to the token.
     * @param owner The address of the token owner.
     */
    function _finalizeTokenRegistration(
        SharedObjects.TokenRegistrationData calldata tokenData,
        bytes32 _resourceId,
        address owner
    ) internal {
        // Normalize *Test variants to their base so a test token registers exactly like its base
        // standard (same event + totalSupply decode). The stored token.ercStandard keeps the Test
        // value so the receiver redeploys the *Example bytecode; only the shape decision normalizes.
        SharedObjects.ErcStandard standard = _baseStandard(tokenData.ercStandard);
        if (standard == SharedObjects.ErcStandard.ERC20) {
            emit Erc20TokenRegistered(
                _resourceId,
                tokenData.issuerChainId,
                block.number,
                tokenData.name,
                abi.decode(tokenData.totalSupply, (uint256))
            );
        } else if (standard == SharedObjects.ErcStandard.ERC721) {
            emit Erc721TokenRegistered(
                _resourceId,
                tokenData.issuerChainId,
                block.number,
                tokenData.name,
                abi.decode(tokenData.totalSupply, (uint256[]))
            );
        } else if (standard == SharedObjects.ErcStandard.ERC1155) {
            emit Erc1155TokenRegistered(
                _resourceId,
                tokenData.issuerChainId,
                block.number,
                tokenData.name,
                abi.decode(tokenData.totalSupply, (SharedObjects.ERC1155Supply[]))
            );
        } else if (standard == SharedObjects.ErcStandard.DvpERC721) {
            require(dvpErc721FactoryAddress != address(0), "TokenCore: DvpErc721Factory not set");

            DvpErc721Factory factory = DvpErc721Factory(dvpErc721FactoryAddress);
            address erc721TokenAddress = factory.createDvpErc721(
                tokenData.uri, tokenData.name, tokenData.symbol, owner, Constants.DVP_MERKLE_TREE_DEPTH
            );

            endpoint.registerResourceId(_resourceId, erc721TokenAddress);

            emit DvpErc721TokenRegistered(
                _resourceId,
                tokenData.issuerChainId,
                block.number,
                tokenData.name,
                abi.decode(tokenData.totalSupply, (uint256[]))
            );
        } else if (standard == SharedObjects.ErcStandard.DvpERC1155) {
            require(dvpErc1155FactoryAddress != address(0), "TokenCore: DvpErc1155Factory not set");

            DvpErc1155Factory factory = DvpErc1155Factory(dvpErc1155FactoryAddress);
            address erc1155TokenAddress =
                factory.createDvpErc1155(tokenData.uri, tokenData.name, owner, Constants.DVP_MERKLE_TREE_DEPTH);

            endpoint.registerResourceId(_resourceId, erc1155TokenAddress);

            emit DvpErc1155TokenRegistered(
                _resourceId,
                tokenData.issuerChainId,
                block.number,
                tokenData.name,
                abi.decode(tokenData.totalSupply, (SharedObjects.ERC1155Supply[]))
            );
        } else if (standard == SharedObjects.ErcStandard.Enygma) {
            IEnygmaTokenManager enygmaTokenManagerInstance = IEnygmaTokenManager(enygmaTokenManager);
            enygmaTokenManagerInstance.registerEnygmaToken(
                _resourceId, tokenData, abi.decode(tokenData.totalSupply, (uint256)), owner, address(participantStorage)
            );
        } else {
            revert("Unsupported ERC standard");
        }
    }

    /**
     * @notice Normalize a `*Test` standard to its base standard for shape/decode decisions.
     * @dev The Test variants are byte-identical to their base standard on the wire — same
     *      totalSupply/initializerParams shape, same registered-event semantics. They differ only in
     *      which PN factory bytecode key the receiver resolves (carried by the stored ercStandard,
     *      which is NOT normalized away). Routing every PNH switch through this keeps the base
     *      standard's branches authoritative so a Test token decodes exactly like its base.
     * @param ercStandard Standard to normalize.
     * @return base The base standard a Test variant mirrors (or `ercStandard` itself if not Test).
     */
    function _baseStandard(SharedObjects.ErcStandard ercStandard) internal pure returns (SharedObjects.ErcStandard base) {
        if (ercStandard == SharedObjects.ErcStandard.ERC20Test) return SharedObjects.ErcStandard.ERC20;
        if (ercStandard == SharedObjects.ErcStandard.ERC721Test) return SharedObjects.ErcStandard.ERC721;
        if (ercStandard == SharedObjects.ErcStandard.ERC1155Test) return SharedObjects.ErcStandard.ERC1155;
        if (ercStandard == SharedObjects.ErcStandard.EnygmaTest) return SharedObjects.ErcStandard.Enygma;
        if (ercStandard == SharedObjects.ErcStandard.DvpERC721Test) return SharedObjects.ErcStandard.DvpERC721;
        if (ercStandard == SharedObjects.ErcStandard.DvpERC1155Test) return SharedObjects.ErcStandard.DvpERC1155;
        return ercStandard;
    }

    /**
     * @notice Retrieve a token storage reference by its resource ID.
     * @dev Reverts with `TokenNotFound` when the resource id is unknown.
     * @param _resourceId Resource id under inspection.
     * @return Storage reference to the token record.
     */
    function _getTokenByResourceId(bytes32 _resourceId) internal view returns (TokenStructs.Token storage) {
        uint256 index = tokenIndexByResourceId[_resourceId];
        if (index == 0) {
            revert TokenNotFound();
        }
        return registeredTokensList[index - 1];
    }
}

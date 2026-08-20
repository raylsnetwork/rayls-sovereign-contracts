// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {RaylsAccessManaged} from "../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsInitializer, RaylsTrustedInit} from "../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {InitCodeStub} from "../../rayls-protocol-sdk/libraries/InitCodeStub.sol";
import {IBaseContractFactory} from "./interfaces/IBaseContractFactory.sol";
import {FactoryKeys} from "./FactoryKeys.sol";

/**
 * @title AbstractContractFactoryV1
 * @notice Shared deploy logic for the Rayls contract factories.
 *
 * @dev Holds the open `bytes32 => bytes` bytecode registry, the CREATE2 deploy + canonical
 *      `IRaylsInitializer.initialize` dispatch, and the three deploy paths (raw, registered,
 *      typed). The two factory-specific behaviours are isolated behind virtual hooks:
 *
 *        - `_buildTrustedInit` — how {RaylsTrustedInit} is assembled (endpoint cast and the
 *          `raylsNodeEndpoint` source differ between hub and privacy node).
 *        - `_afterDeploy`      — post-deploy side effects (hub grants ENDPOINT_SENDER; the
 *          privacy node is a no-op).
 *
 *      Storage layout note: this contract uses plain sequential storage. The OZ upgradeable
 *      mixins and {RaylsAccessManaged} all use namespaced (ERC-7201 / OZ-namespaced) slots,
 *      so there is no collision with the variables declared here. Variables must never be
 *      reordered or removed across upgrades — append only.
 */
abstract contract AbstractContractFactoryV1 is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    RaylsAccessManaged,
    IBaseContractFactory
{
    /*//////////////////////////////////////////////////////////////
                        WELL-KNOWN KEY CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant RAYLS_ERC20_KEY = FactoryKeys.RAYLS_ERC20_KEY;
    bytes32 public constant RAYLS_ERC721_KEY = FactoryKeys.RAYLS_ERC721_KEY;
    bytes32 public constant RAYLS_ERC1155_KEY = FactoryKeys.RAYLS_ERC1155_KEY;
    bytes32 public constant RAYLS_ENYGMA_KEY = FactoryKeys.RAYLS_ENYGMA_KEY;
    bytes32 public constant RAYLS_ERC721_DVP_KEY = FactoryKeys.RAYLS_ERC721_DVP_KEY;
    bytes32 public constant RAYLS_ERC1155_DVP_KEY = FactoryKeys.RAYLS_ERC1155_DVP_KEY;
    bytes32 public constant RAYLS_STABLECOIN_KEY = FactoryKeys.RAYLS_STABLECOIN_KEY;

    // Test-only template keys (seeded with the *Example runtime). Public so the deploy task can read
    // the canonical key via the auto-generated getter when seeding setBytecode(<key>, exampleRuntime).
    bytes32 public constant RAYLS_ERC20_TEST_KEY = FactoryKeys.RAYLS_ERC20_TEST_KEY;
    bytes32 public constant RAYLS_ERC721_TEST_KEY = FactoryKeys.RAYLS_ERC721_TEST_KEY;
    bytes32 public constant RAYLS_ERC1155_TEST_KEY = FactoryKeys.RAYLS_ERC1155_TEST_KEY;
    bytes32 public constant RAYLS_ENYGMA_TEST_KEY = FactoryKeys.RAYLS_ENYGMA_TEST_KEY;
    bytes32 public constant RAYLS_ERC721_DVP_TEST_KEY = FactoryKeys.RAYLS_ERC721_DVP_TEST_KEY;
    bytes32 public constant RAYLS_ERC1155_DVP_TEST_KEY = FactoryKeys.RAYLS_ERC1155_DVP_TEST_KEY;
    bytes32 public constant RAYLS_STABLECOIN_TEST_KEY = FactoryKeys.RAYLS_STABLECOIN_TEST_KEY;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @dev Monotonic counter feeding the CREATE2 salt. First deploy uses salt = 1.
    uint256 private saltCounter;

    /// @notice Endpoint address injected into trusted-init.
    address public endpoint;

    /// @notice Owner injected into trusted-init.
    address public factoryOwner;

    /// @dev Open bytecode registry: any restricted caller may register any bytecode.
    mapping(bytes32 => bytes) private bytecodes;

    /// @dev Owner override applied to the NEXT deploy only. Set by the user-facing deploy entry
    ///      points (e.g. {RNContractFactoryV1.deployErc20AsUser}) right before invoking the
    ///      internal deploy path, and cleared immediately after. Subclass {_buildTrustedInit}
    ///      reads this and substitutes it for {factoryOwner} when non-zero.
    ///
    ///      Reentrant safety: the deploy path is `nonReentrant`, so no other invocation can read
    ///      a stale value. The clear-after-use pattern keeps the storage slot zeroed between
    ///      deploys, so the read in {_buildTrustedInit} is a single cold SLOAD per deploy.
    ///
    ///      Slot consumed from `__gap` below (one fewer reserved slot).
    address internal _pendingOwnerOverride;

    /// @dev Reserved storage to allow future base-class state additions without shifting the
    ///      storage layout of derived contracts (e.g. {RaylsContractFactoryV1.raylsNodeEndpoint}).
    ///      Append base-class variables by shrinking this gap; never reorder existing slots.
    uint256[49] private __gap;

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev Shared init body. Subclasses call this from their own `initializer` function.
    /// @param _endpoint Endpoint address (non-zero).
    /// @param _owner Factory owner (non-zero).
    /// @param authority_ AccessManager address used for `restricted` gating.
    function __AbstractFactory_init(address _endpoint, address _owner, address authority_)
        internal
        onlyInitializing
    {
        if (_endpoint == address(0) || _owner == address(0)) revert FactoryV1__ZeroAddress();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        endpoint = _endpoint;
        factoryOwner = _owner;
        // saltCounter starts at 0 implicitly — first deploy uses salt = 1 via `++saltCounter`.
        _initializeAuthority(authority_);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL DEPLOY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBaseContractFactory
    function deploy(bytes calldata bytecode, bytes calldata userArgs, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address deployedAddress)
    {
        if (bytecode.length == 0) revert FactoryV1__EmptyBytecode();
        deployedAddress = _deployContract(bytecode, userArgs, resourceId);
        emit ContractDeployed(deployedAddress, resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployRegistered(bytes32 key, bytes calldata userArgs, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address deployedAddress)
    {
        return _deployRegistered(key, userArgs, resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    /// @dev Base behaviour mirrors {deploy}. Exposed as a distinct selector so the protocol
    ///      auto-deploy path (e.g. {ResourceManager}) can be gated independently and so subclasses
    ///      may record the deploy in a resource registry. The base performs no registry work.
    function deployExternal(bytes calldata bytecode, bytes calldata userArgs, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address deployedAddress)
    {
        if (bytecode.length == 0) revert FactoryV1__EmptyBytecode();
        deployedAddress = _deployContract(bytecode, userArgs, resourceId);
        emit ContractDeployed(deployedAddress, resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    /// @dev Base behaviour mirrors {deployRegistered}. Exposed as a distinct selector so the protocol
    ///      auto-deploy path (e.g. {ResourceManager}) can be gated independently and so subclasses
    ///      may record the deploy in a resource registry. The base performs no registry work.
    function deployRegisteredExternal(bytes32 key, bytes calldata userArgs, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address deployedAddress)
    {
        return _deployRegistered(key, userArgs, resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployErc20(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_ERC20_KEY, abi.encode(name, symbol, decimals), resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployErc721(string calldata uri, string calldata name, string calldata symbol, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_ERC721_KEY, abi.encode(uri, name, symbol), resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployErc1155(string calldata uri, string calldata name, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_ERC1155_KEY, abi.encode(uri, name), resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployEnygma(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_ENYGMA_KEY, abi.encode(name, symbol, decimals), resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployStableCoin(string calldata name, string calldata symbol, uint8 decimals, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_STABLECOIN_KEY, abi.encode(name, symbol, decimals), resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployErc721Dvp(string calldata uri, string calldata name, string calldata symbol, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_ERC721_DVP_KEY, abi.encode(uri, name, symbol), resourceId);
    }

    /// @inheritdoc IBaseContractFactory
    function deployErc1155Dvp(string calldata uri, string calldata name, bytes32 resourceId)
        external
        virtual
        restricted
        nonReentrant
        returns (address)
    {
        return _deployRegistered(RAYLS_ERC1155_DVP_KEY, abi.encode(uri, name), resourceId);
    }

    /*//////////////////////////////////////////////////////////////
                        REGISTRY & ADMIN SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBaseContractFactory
    function setBytecode(bytes32 key, bytes calldata bytecode) external virtual restricted {
        bytecodes[key] = bytecode;
        // Emit bytes32(0) on a clear so off-chain consumers see the same value as getBytecodeHash,
        // rather than keccak256("").
        emit BytecodeSet(key, bytecode.length == 0 ? bytes32(0) : keccak256(bytecode));
    }

    /// @inheritdoc IBaseContractFactory
    function setFactoryOwner(address newOwner) external virtual restricted {
        if (newOwner == address(0)) revert FactoryV1__ZeroAddress();
        emit FactoryOwnerUpdated(factoryOwner, newOwner);
        factoryOwner = newOwner;
    }

    /// @inheritdoc IBaseContractFactory
    function setEndpoint(address newEndpoint) external virtual restricted {
        if (newEndpoint == address(0)) revert FactoryV1__ZeroAddress();
        emit EndpointUpdated(endpoint, newEndpoint);
        endpoint = newEndpoint;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBaseContractFactory
    function getBytecodeHash(bytes32 key) external view virtual returns (bytes32) {
        bytes storage bytecode = bytecodes[key];
        if (bytecode.length == 0) return bytes32(0);
        return keccak256(bytecode);
    }

    /// @inheritdoc IBaseContractFactory
    function getEndpoint() external view virtual returns (address) {
        return endpoint;
    }

    /// @inheritdoc IBaseContractFactory
    function getFactoryOwner() external view virtual returns (address) {
        return factoryOwner;
    }

    /// @inheritdoc IBaseContractFactory
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }

    /*//////////////////////////////////////////////////////////////
                            VIRTUAL HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Build the trusted-init struct for a deploy. Subclasses provide the correct
    ///      `raylsNodeEndpoint` source and endpoint cast.
    /// @param resourceId Resource identifier passed through to the deployed contract.
    function _buildTrustedInit(bytes32 resourceId)
        internal
        view
        virtual
        returns (RaylsTrustedInit memory);

    /// @dev Post-deploy hook. Runs after CREATE2 + `initialize()`. Default: no-op.
    /// @param deployed Address of the freshly deployed and initialized contract.
    function _afterDeploy(address deployed) internal virtual {}

    /*//////////////////////////////////////////////////////////////
                        INTERNAL CORE FLOW
    //////////////////////////////////////////////////////////////*/

    /// @dev Shared body for `deployRegistered` and every typed deploy function: looks up the
    ///      bytecode registered under `key`, deploys it, and emits {RegisteredContractDeployed}.
    ///      Access gating + reentrancy guard live on the external callers, so this is unguarded.
    /// @param key Registry key.
    /// @param userArgs ABI-encoded handler-specific init args.
    /// @param resourceId Resource identifier injected into trusted-init.
    /// @return deployed Address of the deployed contract.
    function _deployRegistered(bytes32 key, bytes memory userArgs, bytes32 resourceId)
        internal
        returns (address deployed)
    {
        bytes memory bytecode = bytecodes[key];
        if (bytecode.length == 0) revert FactoryV1__BytecodeNotRegistered(key);
        deployed = _deployContract(bytecode, userArgs, resourceId);
        emit RegisteredContractDeployed(key, deployed, resourceId);
    }

    /// @dev All three deploy paths converge here. Deploys via CREATE2, builds trusted-init
    ///      from on-chain state (never user-controlled), dispatches the canonical
    ///      `IRaylsInitializer.initialize` selector, then runs the subclass post-deploy hook.
    /// @param bytecode Runtime bytecode to deploy.
    /// @param userArgs ABI-encoded handler-specific init args (decoded by the handler itself).
    /// @param resourceId Resource identifier injected into trusted-init.
    /// @return deployed Address of the deployed contract.
    function _deployContract(bytes memory bytecode, bytes memory userArgs, bytes32 resourceId)
        internal
        returns (address deployed)
    {
        // The monotonic counter already guarantees a unique salt per factory instance, and the
        // factory address is implicit in CREATE2 — no keccak256 wrap is needed for uniqueness.
        bytes32 salt = bytes32(++saltCounter);
        deployed = Create2.deploy(0, salt, InitCodeStub.wrapRuntimeMemory(bytecode));

        RaylsTrustedInit memory trusted = _buildTrustedInit(resourceId);

        (bool success, ) = deployed.call(
            abi.encodeCall(IRaylsInitializer.initialize, (userArgs, trusted))
        );
        if (!success) {
            // Bubble up the inner revert data for debuggability — without this the typed
            // factory error swallows the underlying reason. Falls back to the typed error
            // when the init-call returned no revert data.
            assembly {
                let size := returndatasize()
                if gt(size, 0) {
                    let p := mload(0x40)
                    returndatacopy(p, 0, size)
                    revert(p, size)
                }
            }
            revert FactoryV1__InitializationFailed();
        }

        _afterDeploy(deployed);
    }

    /*//////////////////////////////////////////////////////////////
                                UUPS
    //////////////////////////////////////////////////////////////*/

    /// @notice OZ UUPS upgrade authorization hook.
    /// @dev Parameter is intentionally anonymous — gating is selector-based via
    ///      `_checkCanCall(msg.sender, msg.sig)`, so the implementation address is unused.
    function _authorizeUpgrade(address /*newImplementation*/) internal view override {
        _checkCanCall(msg.sender, msg.sig);
    }
}

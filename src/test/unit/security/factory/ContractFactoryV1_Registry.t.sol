// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RNContractFactoryV1} from "../../../../rayls-node/rayls-privacy-node/RNContractFactoryV1.sol";
import {RaylsAccessManagerV1} from "../../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {IRaylsInitializer} from "../../../../rayls-protocol-sdk/IRaylsInitializer.sol";
import {IBaseContractFactory} from "../../../../rayls-protocol/RaylsContractFactory/interfaces/IBaseContractFactory.sol";
import {InitSpy, MockNodeEndpoint} from "./FactoryTestUtils.sol";

/// @notice Behaviour contract for the V1 bytecode registry + typed deploy paths added in the
///         factory rewrite. Exercised against {RNContractFactoryV1}; the registry, typed
///         sugar, and `_deployContract` flow all live in the shared abstract base, so the
///         hub factory inherits identical behaviour. The test contract holds ADMIN (role 0),
///         which bypasses `restricted` — access wiring is covered separately in the
///         AccessControl suite; here we assert the factory's own logic.
contract ContractFactoryV1RegistryTest is Test {
    RNContractFactoryV1 internal factory;
    RaylsAccessManagerV1 internal manager;
    MockNodeEndpoint internal endpoint;

    address internal admin = address(this);
    address internal factoryOwner = makeAddr("factoryOwner");
    address internal userGov = makeAddr("userGovernance");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant CUSTOM_KEY = keccak256("MY_STANDARD");

    // Mirror of the events under test (re-declared so `vm.expectEmit` can match them).
    event RegisteredContractDeployed(
        bytes32 indexed key,
        address indexed deployedAddress,
        bytes32 indexed resourceId
    );
    event BytecodeSet(bytes32 indexed key, bytes32 bytecodeHash);

    function setUp() public {
        RaylsAccessManagerV1 mgrImpl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(mgrImpl.initialize, (admin))
        )));

        endpoint = new MockNodeEndpoint(userGov);

        RNContractFactoryV1 facImpl = new RNContractFactoryV1();
        factory = RNContractFactoryV1(address(new ERC1967Proxy(
            address(facImpl),
            abi.encodeCall(facImpl.initialize, (address(endpoint), address(endpoint), factoryOwner, address(manager)))
        )));
    }

    /// @dev The InitSpy runtime accepts any call via its fallback, so it stands in for any
    ///      registerable handler: the factory's `initialize` dispatch always "succeeds".
    function _spyRuntime() internal pure returns (bytes memory) {
        return type(InitSpy).runtimeCode;
    }

    // ─────────────────────────────────────────────────────────────────
    //  setBytecode / getBytecodeHash
    // ─────────────────────────────────────────────────────────────────

    function test_setBytecode_storesHashAndEmits() public {
        bytes memory runtime = _spyRuntime();
        vm.expectEmit(true, false, false, true, address(factory));
        emit BytecodeSet(factory.RAYLS_ERC20_KEY(), keccak256(runtime));
        factory.setBytecode(factory.RAYLS_ERC20_KEY(), runtime);

        assertEq(factory.getBytecodeHash(factory.RAYLS_ERC20_KEY()), keccak256(runtime),
            "getBytecodeHash must return keccak256 of the stored runtime");
    }

    function test_getBytecodeHash_zeroWhenUnset() public view {
        assertEq(factory.getBytecodeHash(keccak256("never-set")), bytes32(0),
            "unset key must hash to bytes32(0)");
    }

      function test_setBytecode_emptyClearsKey() public {
        factory.setBytecode(CUSTOM_KEY, _spyRuntime());
        assertTrue(factory.getBytecodeHash(CUSTOM_KEY) != bytes32(0), "precondition: key set");

        // Clearing must emit bytes32(0) — matching getBytecodeHash, not keccak256("").
        vm.expectEmit(true, false, false, true, address(factory));
        emit BytecodeSet(CUSTOM_KEY, bytes32(0));
        factory.setBytecode(CUSTOM_KEY, "");
        assertEq(factory.getBytecodeHash(CUSTOM_KEY), bytes32(0), "empty bytecode must clear the key");
    }

    function test_setBytecode_unauthorizedReverts() public {
        vm.prank(stranger);
        vm.expectRevert(); // RaylsAccessManaged__Unauthorized — stranger has no role
        factory.setBytecode(CUSTOM_KEY, _spyRuntime());
    }

    // ─────────────────────────────────────────────────────────────────
    //  deployRegistered
    // ─────────────────────────────────────────────────────────────────

    function test_deployRegistered_happyPath_emitsAndReturnsAddress() public {
        factory.setBytecode(factory.RAYLS_ERC20_KEY(), _spyRuntime());

        vm.expectEmit(true, false, true, false, address(factory));
        // deployedAddress (topic 2) is not predicted here; only key + resourceId asserted.
        emit RegisteredContractDeployed(factory.RAYLS_ERC20_KEY(), address(0), bytes32(uint256(0xBEEF)));
        address deployed = factory.deployRegistered(factory.RAYLS_ERC20_KEY(), "", bytes32(uint256(0xBEEF)));

        assertTrue(deployed != address(0), "deployRegistered must return a deployed address");
        assertTrue(deployed.code.length > 0, "deployed address must hold code");
    }

    function test_deployRegistered_revertsWhenKeyUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(IBaseContractFactory.FactoryV1__BytecodeNotRegistered.selector, CUSTOM_KEY));
        factory.deployRegistered(CUSTOM_KEY, "", bytes32(0));
    }

    function test_deployRegistered_advancesSaltCounter_distinctAddresses() public {
        factory.setBytecode(factory.RAYLS_ERC20_KEY(), _spyRuntime());
        address a = factory.deployRegistered(factory.RAYLS_ERC20_KEY(), "", bytes32(0));
        address b = factory.deployRegistered(factory.RAYLS_ERC20_KEY(), "", bytes32(0));
        assertTrue(a != b, "salt counter must advance so identical bytecode yields distinct addresses");
    }

    function test_deployRegistered_resourceIdZeroAccepted() public {
        factory.setBytecode(factory.RAYLS_ERC20_KEY(), _spyRuntime());
        address deployed = factory.deployRegistered(factory.RAYLS_ERC20_KEY(), "", bytes32(0));
        assertTrue(deployed != address(0), "resourceId == 0 must be accepted on the registered path");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Custom key (no upgrade required)
    // ─────────────────────────────────────────────────────────────────

    function test_customKey_registerThenDeploy_succeeds() public {
        factory.setBytecode(CUSTOM_KEY, _spyRuntime());
        address deployed = factory.deployRegistered(CUSTOM_KEY, hex"deadbeef", bytes32(uint256(0x1234)));
        assertTrue(deployed != address(0), "a custom key must deploy without any contract upgrade");
    }

    // ─────────────────────────────────────────────────────────────────
    //  Typed deploys — dispatch the canonical initializer with encoded userArgs
    // ─────────────────────────────────────────────────────────────────

    function test_deployErc20_dispatchesCanonicalInitializerWithEncodedArgs() public {
        factory.setBytecode(factory.RAYLS_ERC20_KEY(), _spyRuntime());

        address deployed = factory.deployErc20("Token", "TKN", 18, bytes32(uint256(0xC0DE)));
        InitSpy spy = InitSpy(payable(deployed));

        assertEq(spy.lastSelector(), IRaylsInitializer.initialize.selector,
            "typed deploy must dispatch the canonical IRaylsInitializer.initialize selector");

        // Decode the dispatched calldata: initialize(bytes userArgs, RaylsTrustedInit trusted).
        (bytes memory userArgs, ) = _splitInitCalldata(spy.lastCalldata());
        (string memory name, string memory symbol, uint8 decimals) = abi.decode(userArgs, (string, string, uint8));
        assertEq(name, "Token", "deployErc20 must abi.encode the name into userArgs");
        assertEq(symbol, "TKN", "deployErc20 must abi.encode the symbol into userArgs");
        assertEq(decimals, 18, "deployErc20 must abi.encode the decimals into userArgs");
    }

    function test_deployErc721_encodesUriNameSymbol() public {
        factory.setBytecode(factory.RAYLS_ERC721_KEY(), _spyRuntime());
        address deployed = factory.deployErc721("ipfs://x", "Name", "SYM", bytes32(0));
        InitSpy spy = InitSpy(payable(deployed));

        (bytes memory userArgs, ) = _splitInitCalldata(spy.lastCalldata());
        (string memory uri, string memory name, string memory symbol) = abi.decode(userArgs, (string, string, string));
        assertEq(uri, "ipfs://x");
        assertEq(name, "Name");
        assertEq(symbol, "SYM");
    }

    function test_deployErc1155_encodesUriName() public {
        factory.setBytecode(factory.RAYLS_ERC1155_KEY(), _spyRuntime());
        address deployed = factory.deployErc1155("ipfs://y", "Multi", bytes32(0));
        InitSpy spy = InitSpy(payable(deployed));

        (bytes memory userArgs, ) = _splitInitCalldata(spy.lastCalldata());
        (string memory uri, string memory name) = abi.decode(userArgs, (string, string));
        assertEq(uri, "ipfs://y");
        assertEq(name, "Multi");
    }

    function test_deployEnygma_encodesNameSymbolDecimals() public {
        factory.setBytecode(factory.RAYLS_ENYGMA_KEY(), _spyRuntime());
        address deployed = factory.deployEnygma("Eny", "ENY", 6, bytes32(0));
        InitSpy spy = InitSpy(payable(deployed));

        (bytes memory userArgs, ) = _splitInitCalldata(spy.lastCalldata());
        (string memory name, string memory symbol, uint8 decimals) = abi.decode(userArgs, (string, string, uint8));
        assertEq(name, "Eny");
        assertEq(symbol, "ENY");
        assertEq(decimals, 6);
    }

    function test_typedDeploy_revertsWhenStandardKeyUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(IBaseContractFactory.FactoryV1__BytecodeNotRegistered.selector, factory.RAYLS_ERC20_KEY()));
        factory.deployErc20("T", "T", 18, bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────
    //  StableCoin — registry + deployRegistered dispatch (the ops-api path)
    //  NOTE: this RNContractFactoryV1 harness uses MockNodeEndpoint, which has no `authority()`,
    //  so the REAL handler's _registerAccessControl cannot run here. Full real-handler init —
    //  roles, pause/blacklist/minter, and the RaylsStableCoinTokenCreated creation event — is
    //  covered in src/test/unit/tokens/RaylsStableCoinHandler.t.sol against a fully-wired mock.
    //  Here we assert only what this harness can prove: the key, and that the registered-deploy
    //  path dispatches the canonical initializer with the ops-api-encoded userArgs.
    // ─────────────────────────────────────────────────────────────────

    function test_stablecoin_keyMatchesKeccak() public view {
        assertEq(factory.RAYLS_STABLECOIN_KEY(), keccak256("RAYLS_STABLECOIN"),
            "factory key must equal keccak256(\"RAYLS_STABLECOIN\") so ops-api PackDeployRegistered targets it");
    }

    function test_stablecoin_deployRegistered_dispatchesCanonicalInitializerWithEncodedArgs() public {
        // Seed the spy runtime under the stablecoin key and deploy via the registered path with the
        // exact (name, symbol, decimals) userArgs ops-api ABI-encodes. Asserts the factory routes the
        // stablecoin key through the canonical IRaylsInitializer.initialize dispatch with those args.
        factory.setBytecode(factory.RAYLS_STABLECOIN_KEY(), _spyRuntime());

        bytes memory userArgs = abi.encode("Rayls USD", "rUSD", uint8(6));
        address deployed = factory.deployRegistered(factory.RAYLS_STABLECOIN_KEY(), userArgs, bytes32(0));
        InitSpy spy = InitSpy(payable(deployed));

        assertEq(spy.lastSelector(), IRaylsInitializer.initialize.selector,
            "stablecoin registered deploy must dispatch the canonical initialize selector");

        (bytes memory dispatched, ) = _splitInitCalldata(spy.lastCalldata());
        (string memory name, string memory symbol, uint8 decimals) = abi.decode(dispatched, (string, string, uint8));
        assertEq(name, "Rayls USD");
        assertEq(symbol, "rUSD");
        assertEq(decimals, 6);
    }

    function test_stablecoin_deployRegistered_emitsRegisteredContractDeployed() public {
        factory.setBytecode(factory.RAYLS_STABLECOIN_KEY(), _spyRuntime());

        // RegisteredContractDeployed keyed on RAYLS_STABLECOIN_KEY is what ops-api's
        // extractDeployedAddress unpacks to learn the token address.
        vm.expectEmit(true, false, true, false, address(factory));
        emit RegisteredContractDeployed(factory.RAYLS_STABLECOIN_KEY(), address(0), bytes32(0));
        factory.deployRegistered(factory.RAYLS_STABLECOIN_KEY(), abi.encode("Rayls USD", "rUSD", uint8(6)), bytes32(0));
    }

    // ─────────────────────────────────────────────────────────────────
    //  Helpers
    // ─────────────────────────────────────────────────────────────────

    /// @dev Split the recorded `initialize(bytes,RaylsTrustedInit)` calldata into its first
    ///      argument (`userArgs`) and ignores the trusted struct. Returns the trailing flag
    ///      unused so callers can keep a 2-tuple destructure shape.
    function _splitInitCalldata(bytes memory data) internal pure returns (bytes memory userArgs, bool) {
        bytes memory body = _stripSelector(data);
        // initialize(bytes userArgs, RaylsTrustedInit trusted): decode the head, follow the
        // offset to userArgs. abi.decode of (bytes) reads the first dynamic arg correctly.
        userArgs = abi.decode(body, (bytes));
        return (userArgs, true);
    }

    /// @dev Drop the leading 4-byte selector from ABI calldata.
    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length >= 4, "calldata too short");
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }
}

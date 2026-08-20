// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IRaylsAccessManager} from "../../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import {InitCodeStub} from "../../../../rayls-protocol-sdk/libraries/InitCodeStub.sol";
import {SharedObjects} from "../../../../rayls-protocol-sdk/libraries/SharedObjects.sol";

/// @notice Catch-all probe deployed via the contract factory under test. Records the
///         selector and full calldata of the first call it receives. Tests use this to
///         observe what message the factory dispatched on the freshly deployed contract.
contract InitSpy {
    bytes public lastCalldata;
    bytes4 public lastSelector;
    uint256 public initCallCount;

    fallback() external payable {
        initCallCount++;
        lastSelector = msg.sig;
        lastCalldata = msg.data;
    }

    /// @dev Companion to the payable fallback. Required for forge-lint; never invoked in
    ///      practice (no test sends ETH with empty calldata).
    receive() external payable {}
}

/// @notice ERC20-shaped probe that can be registered by the PN TokenRegistry after factory deployment.
contract RegistryReadyERC20 {
    bytes public lastCalldata;
    bytes4 public lastSelector;
    uint256 public initCallCount;

    /// @notice Returns the mock token name.
    /// @return Mock token name.
    function name() external pure returns (string memory) {
        return "FactoryToken";
    }

    /// @notice Returns the mock token symbol.
    /// @return Mock token symbol.
    function symbol() external pure returns (string memory) {
        return "FACT";
    }

    /// @notice Returns the mock token decimals.
    /// @return Mock token decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// @notice Returns the mock token supply.
    /// @return Mock token total supply.
    function totalSupply() external pure returns (uint256) {
        return 1_000_000e18;
    }

    /// @notice Returns the Rayls ERC standard used by this token.
    /// @return Encoded ERC20 standard.
    function GetERCStandard() external pure returns (uint8) {
        return uint8(SharedObjects.ErcStandard.ERC20);
    }

    fallback() external payable {
        initCallCount++;
        lastSelector = msg.sig;
        lastCalldata = msg.data;
    }

    /// @dev Companion to the payable fallback. Required for forge-lint; never invoked in
    ///      practice (no test sends ETH with empty calldata).
    receive() external payable {}
}

/// @notice Endpoint stub for `RNContractFactoryV1`. The factory only calls
///         `getUserGovernanceAddress()` from the endpoint during deploy.
contract MockNodeEndpoint {
    address public userGov;

    /// @notice Stores the mock user-governance address.
    /// @param _userGov User-governance address returned by the endpoint stub.
    constructor(address _userGov) { userGov = _userGov; }

    /// @notice Returns the configured user-governance address.
    /// @return Configured user-governance address.
    function getUserGovernanceAddress() external view returns (address) { return userGov; }
}

/// @notice Endpoint stub for `RaylsContractFactoryV1`. That factory calls
///         `getUserGovernanceAddress()` and `authority()` (to look up the AccessManager).
contract MockProtocolEndpoint {
    address public userGov;
    address public authorityAddr;
    uint256 public chainId = 100;
    mapping(bytes32 => address) public resourceIdToAddress;

    /// @notice Stores mock endpoint values used by the protocol factory tests.
    /// @param _userGov User-governance address returned by the endpoint stub.
    /// @param _authority AccessManager address returned as endpoint authority.
    constructor(address _userGov, address _authority) {
        userGov = _userGov;
        authorityAddr = _authority;
    }

    /// @notice Returns the configured user-governance address.
    /// @return Configured user-governance address.
    function getUserGovernanceAddress() external view returns (address) { return userGov; }

    /// @notice Returns the configured access authority address.
    /// @return Configured authority address.
    function authority() external view returns (address) { return authorityAddr; }

    /// @notice Returns the configured local chain id.
    /// @return Configured chain id.
    function getChainId() external view returns (uint256) { return chainId; }

    /// @notice Sets the local chain ID returned by the endpoint mock.
    /// @param newChainId Chain id to return.
    function setChainId(uint256 newChainId) external {
        chainId = newChainId;
    }

    /// @notice Configures a resource lookup result.
    /// @param resourceId Resource id being configured.
    /// @param implementation Address returned for the resource id.
    function setAddressByResourceId(bytes32 resourceId, address implementation) external {
        resourceIdToAddress[resourceId] = implementation;
    }

    /// @notice Returns the configured resource lookup result.
    /// @param resourceId Resource id being resolved.
    /// @return Address configured for the resource id.
    function getAddressByResourceId(bytes32 resourceId) external view returns (address) {
        return resourceIdToAddress[resourceId];
    }
}

/// @notice Lightweight PN TokenRegistry stub for factory behavior tests that use arbitrary runtimes.
contract MockFactoryTokenRegistry {
    uint256 public registerCalls;
    address public lastRegisteredToken;
    bool public lastRegisteredTokenHadEndpointSender;
    IRaylsAccessManager public roleProbe;
    uint64 public endpointSenderRoleId;

    /// @notice Configures the role probe used to verify factory grant/register ordering.
    /// @param manager Access manager queried during `registerToken`.
    /// @param roleId ENDPOINT_SENDER role id expected on the deployed token before registration.
    function configureEndpointSenderProbe(address manager, uint64 roleId) external {
        roleProbe = IRaylsAccessManager(manager);
        endpointSenderRoleId = roleId;
    }

    /// @notice Records a token registration from the factory.
    /// @param tokenAddress Token address registered by the factory.
    function registerToken(address tokenAddress) external {
        registerCalls++;
        lastRegisteredToken = tokenAddress;
        if (address(roleProbe) != address(0)) {
            (lastRegisteredTokenHadEndpointSender, ) = roleProbe.hasRole(endpointSenderRoleId, tokenAddress);
        }
    }
}

/// @notice Shared helpers for factory bytecode + CREATE2 prediction. Mirrors the factory's
///         private `_getInitCodeOfEmptyConstructor` so tests can reproduce the exact
///         deployment data the factory will use, then predict the CREATE2 address.
library FactoryStubLib {
    /// @dev Builds the full init-code (stub ‖ runtime) the factory will deploy via CREATE2.
    ///      Single source of truth: delegates to `InitCodeStub.wrapRuntimeMemory`.
    /// @param bytecode Runtime bytecode supplied to the factory.
    /// @return Full factory init-code payload.
    function factoryInitCode(bytes memory bytecode) internal pure returns (bytes memory) {
        return InitCodeStub.wrapRuntimeMemory(bytecode);
    }

    /// @dev CREATE2 address that the factory will produce for the next `deploy(bytecode, ...)`
    ///      call. `nextSaltCounter` must equal `current saltCounter + 1` (the factory does
    ///      `++saltCounter` before computing the salt).
    function predictCreate2(address factory, bytes memory bytecode, uint256 nextSaltCounter)
        internal
        pure
        returns (address)
    {
        bytes32 salt = bytes32(nextSaltCounter);
        bytes32 codeHash = keccak256(InitCodeStub.wrapRuntimeMemory(bytecode));
        return Create2.computeAddress(salt, codeHash, factory);
    }

    /// @dev Build a bytecode payload of the given length with two leading STOP opcodes
    ///      followed by a unique pattern (0x01..). Two STOPs let the factory's post-deploy
    ///      init-call halt cleanly even if the deployed runtime is shifted by one byte.
    ///      The unique tail makes any shift, truncation, or padding visible byte-for-byte
    ///      when comparing the on-chain runtime to the supplied bytes.
    /// @param length Runtime byte length to build.
    /// @return out Sentinel runtime bytecode.
    function buildSentinelRuntime(uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        if (length >= 1) out[0] = 0x00; // STOP
        if (length >= 2) out[1] = 0x00; // STOP backup
        for (uint256 i = 2; i < length; i++) {
            out[i] = bytes1(uint8(((i - 1) & 0xff)));
        }
    }
}

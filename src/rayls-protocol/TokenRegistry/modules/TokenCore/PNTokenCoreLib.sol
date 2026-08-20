// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import "../../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import {IEnygmaPNEvents} from "../../../../rayls-protocol-sdk/interfaces/IEnygmaPNEvents.sol";
import {IRaylsAccessManager} from "../../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

/// @notice Minimal token-standard surface exposed by Rayls token contracts.
interface IRaylsTokenStandard {
    /// @notice Returns the encoded token standard used by TokenCore metadata handling.
    function GetERCStandard() external pure returns (uint8);
}

/// @notice Minimal ERC1155 metadata surface exposed by Rayls ERC1155 handlers.
interface IRaylsErc1155Metadata {
    /// @notice Returns the token collection name.
    function name() external view returns (string memory);
}

/// @notice Minimal custom-token flag surface exposed by Rayls token contracts.
interface IRaylsCustomFlag {
    /// @notice Returns whether the token is a custom Rayls token implementation.
    function isCustom() external view returns (bool);
}

/**
 * @title PNTokenCoreLib
 * @notice Storage-free metadata, standard-mapping, and init/supply-encoding helpers for the
 *         PN `TokenCoreV1` module.
 * @dev Extracted from `TokenCoreV1` and deployed as an external (DELEGATECALL-linked) library
 *      so the module's implementation bytecode stays under the EIP-170 24,576-byte limit. Every
 *      function here reads only its arguments (or makes external staticcalls to the token
 *      contract); none touch `TokenCoreV1` storage, so linking adds no storage slots to the
 *      caller.
 */
library PNTokenCoreLib {
    /// @dev Reads the encoded Rayls ERC standard from a token contract.
    function getTokenStandard(address tokenAddress) public view returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard(IRaylsTokenStandard(tokenAddress).GetERCStandard());
    }

    /// @dev Reads token metadata and normalizes name, symbol, and URI values for registry storage.
    function readTokenMetadata(address tokenAddress, SharedObjects.ErcStandard ercStandard)
        public
        view
        returns (string memory tokenName, string memory tokenSymbol, string memory tokenUri)
    {
        ercStandard = baseStandard(ercStandard);
        if (ercStandard == SharedObjects.ErcStandard.ERC20 || ercStandard == SharedObjects.ErcStandard.Enygma) {
            IERC20Metadata token = IERC20Metadata(tokenAddress);
            tokenName = token.name();
            tokenSymbol = token.symbol();
            tokenUri = tokenSymbol;
        } else if (
            ercStandard == SharedObjects.ErcStandard.ERC721 || ercStandard == SharedObjects.ErcStandard.DvpERC721
        ) {
            IERC721Metadata token = IERC721Metadata(tokenAddress);
            tokenName = token.name();
            tokenSymbol = token.symbol();
            tokenUri = tokenSymbol;
        } else {
            IRaylsErc1155Metadata token = IRaylsErc1155Metadata(tokenAddress);
            tokenName = token.name();
            tokenSymbol = tokenName;
            tokenUri = tokenName;
        }
    }

    /// @dev Builds the full `addToken(...)` hub-registration calldata for a pre-deployed issuer token.
    ///      Consolidates the supply/init/fungibility/custom reads into one DELEGATECALL boundary so the
    ///      caller (`submitToHub`) does not inline the 12-field struct encoder. Returns the ready-to-send
    ///      encoded payload for `endpoint.send(...)`.
    function buildAddTokenPayload(
        address tokenAddress,
        SharedObjects.ErcStandard ercStandard,
        address pnRegistryAddress,
        uint256 issuerChainId,
        string memory name,
        string memory symbol,
        string memory uri
    ) public view returns (bytes memory) {
        SharedObjects.TokenRegistrationData memory data = SharedObjects.TokenRegistrationData({
            name: name,
            symbol: symbol,
            uri: uri,
            totalSupply: encodeTotalSupply(tokenAddress, ercStandard),
            issuerChainId: issuerChainId,
            pnRegistryAddress: pnRegistryAddress,
            bytecode: tokenAddress.code,
            initializerParams: buildInitializerParams(tokenAddress, ercStandard),
            isFungible: isFungible(ercStandard),
            ercStandard: ercStandard,
            isCustom: isCustomToken(tokenAddress),
            tokenAddress: tokenAddress
        });

        return abi.encodeWithSignature(
            "addToken((string,string,string,bytes,uint256,address,bytes,bytes,bool,uint8,bool,address))", data
        );
    }

    /// @dev Builds the bare (no selector) ABI-encoded init user-args consumed by the canonical
    ///      `IRaylsInitializer.initialize(bytes userArgs, RaylsTrustedInit)` entrypoint. The factory
    ///      dispatches the fixed init selector itself, and the PNH decodes these bytes by shape, so
    ///      the result MUST be a bare `abi.encode(...)` (not `abi.encodeWithSignature`).
    function buildInitializerParams(address tokenAddress, SharedObjects.ErcStandard ercStandard)
        internal
        view
        returns (bytes memory)
    {
        ercStandard = baseStandard(ercStandard);
        if (ercStandard == SharedObjects.ErcStandard.ERC20 || ercStandard == SharedObjects.ErcStandard.Enygma) {
            IERC20Metadata token = IERC20Metadata(tokenAddress);
            return abi.encode(token.name(), token.symbol(), token.decimals());
        } else if (
            ercStandard == SharedObjects.ErcStandard.ERC721 || ercStandard == SharedObjects.ErcStandard.DvpERC721
        ) {
            IERC721Metadata token = IERC721Metadata(tokenAddress);
            return abi.encode(token.symbol(), token.name(), token.symbol());
        } else if (
            ercStandard == SharedObjects.ErcStandard.ERC1155 || ercStandard == SharedObjects.ErcStandard.DvpERC1155
        ) {
            IRaylsErc1155Metadata token = IRaylsErc1155Metadata(tokenAddress);
            return abi.encode(token.name(), token.name());
        }

        return "";
    }

    /// @dev Encodes the token supply payload expected by the Private Hub registration flow.
    function encodeTotalSupply(address tokenAddress, SharedObjects.ErcStandard ercStandard)
        internal
        view
        returns (bytes memory)
    {
        ercStandard = baseStandard(ercStandard);
        if (ercStandard == SharedObjects.ErcStandard.ERC20 || ercStandard == SharedObjects.ErcStandard.Enygma) {
            return abi.encode(IERC20Metadata(tokenAddress).totalSupply());
        } else if (
            ercStandard == SharedObjects.ErcStandard.ERC721 || ercStandard == SharedObjects.ErcStandard.DvpERC721
        ) {
            uint256[] memory empty721Supply = new uint256[](0);
            return abi.encode(empty721Supply);
        } else if (
            ercStandard == SharedObjects.ErcStandard.ERC1155 || ercStandard == SharedObjects.ErcStandard.DvpERC1155
        ) {
            SharedObjects.ERC1155Supply[] memory empty1155Supply = new SharedObjects.ERC1155Supply[](0);
            return abi.encode(empty1155Supply);
        }

        return "";
    }

    /// @dev Reads the live fungible supply from a PN token. ERC20/Enygma → totalSupply();
    ///      NFT/DVP families report 0 (no single fungible supply). Test variants normalize to base.
    function readTotalSupply(address tokenAddress, SharedObjects.ErcStandard ercStandard)
        public
        view
        returns (uint256)
    {
        SharedObjects.ErcStandard base = baseStandard(ercStandard);
        if (base == SharedObjects.ErcStandard.ERC20 || base == SharedObjects.ErcStandard.Enygma) {
            return IERC20Metadata(tokenAddress).totalSupply();
        }
        return 0;
    }

    /// @dev Returns whether an ERC standard represents a fungible token family.
    function isFungible(SharedObjects.ErcStandard ercStandard) internal pure returns (bool) {
        SharedObjects.ErcStandard base = baseStandard(ercStandard);
        return base == SharedObjects.ErcStandard.ERC20 || base == SharedObjects.ErcStandard.Enygma;
    }

    /// @dev Emits activation side-effect events for Enygma and DVP token families. `enygmaPNEvents`
    ///      is the caller's configured events contract (`address(0)` skips emission). Invoked via the
    ///      DELEGATECALL library link, so the external event calls still originate from TokenCore.
    function emitCreationEvent(
        address enygmaPNEvents,
        bytes32 resourceId,
        SharedObjects.ErcStandard ercStandard,
        uint256 totalSupply
    ) public {
        if (enygmaPNEvents == address(0)) {
            return;
        }

        SharedObjects.ErcStandard base = baseStandard(ercStandard);
        IEnygmaPNEvents eventsContract = IEnygmaPNEvents(enygmaPNEvents);
        if (base == SharedObjects.ErcStandard.Enygma) {
            eventsContract.creation(resourceId, totalSupply);
        } else if (base == SharedObjects.ErcStandard.DvpERC721) {
            eventsContract.dvp721Creation(resourceId);
        } else if (base == SharedObjects.ErcStandard.DvpERC1155) {
            eventsContract.dvp1155Creation(resourceId);
        }
    }

    /// @dev Grants the endpoint sender role so an activated PN token can originate cross-chain
    ///      messages. `manager` is the caller's access-manager authority (`address(0)` is a no-op).
    ///      Invoked via the DELEGATECALL library link, so the grant still originates from TokenCore.
    function grantEndpointSenderRole(address manager, address tokenAddress) public {
        if (manager == address(0)) {
            return;
        }

        uint64 endpointSenderRoleId = IRaylsAccessManager(manager).getRoleIdByName("ENDPOINT_SENDER");
        IRaylsAccessManager(manager).grantRole(endpointSenderRoleId, tokenAddress, 0);
    }

    /// @dev Best-effort reads whether a token reports itself as a custom implementation.
    function isCustomToken(address tokenAddress) internal view returns (bool) {
        try IRaylsCustomFlag(tokenAddress).isCustom() returns (bool custom) {
            return custom;
        } catch {
            return false;
        }
    }

    /// @dev Normalizes a `*Test` standard to its base standard for shape decisions. The Test variants
    ///      share the base standard's metadata interface, init-arg tuple, totalSupply shape, and
    ///      fungibility; they differ only in which factory bytecode key they resolve to. Non-Test
    ///      standards pass through unchanged.
    function baseStandard(SharedObjects.ErcStandard ercStandard) public pure returns (SharedObjects.ErcStandard) {
        if (ercStandard == SharedObjects.ErcStandard.ERC20Test) return SharedObjects.ErcStandard.ERC20;
        if (ercStandard == SharedObjects.ErcStandard.ERC721Test) return SharedObjects.ErcStandard.ERC721;
        if (ercStandard == SharedObjects.ErcStandard.ERC1155Test) return SharedObjects.ErcStandard.ERC1155;
        if (ercStandard == SharedObjects.ErcStandard.EnygmaTest) return SharedObjects.ErcStandard.Enygma;
        if (ercStandard == SharedObjects.ErcStandard.DvpERC721Test) return SharedObjects.ErcStandard.DvpERC721;
        if (ercStandard == SharedObjects.ErcStandard.DvpERC1155Test) return SharedObjects.ErcStandard.DvpERC1155;
        return ercStandard;
    }
}

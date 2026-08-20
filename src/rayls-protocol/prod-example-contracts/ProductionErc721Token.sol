// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsErc721Handler.sol';

/**
 * @title ProductionErc721Token
 * @notice Production-grade concrete ERC721 token seeded as the canonical `RAYLS_ERC721_KEY` bytecode on
 *         `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime bytecode via
 *         `InitCodeStub`, so the runtime surface here is what ships to every deployed instance.
 * @dev    Replaces the former `RaylsErc721Example`, which carried an unrestricted public
 *         `awardItem` mint (anyone could mint arbitrary token IDs to any address) plus a
 *         constructor premint. This contract adds NO functions beyond the audited
 *         {RaylsErc721Handler} base. The base already implements `_baseURI()` from its `_uri`
 *         storage (set in {RaylsErc721Handler-initialize}), so no override is needed. The
 *         constructor is a thin passthrough required only so the artifact compiles to non-empty
 *         `deployedBytecode`; it does NOT run under `InitCodeStub`.
 */
contract ProductionErc721Token is RaylsErc721Handler {
    constructor(
        string memory baseUri,
        string memory name,
        string memory symbol,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    )
        RaylsErc721Handler(baseUri, name, symbol, _endpoint, _raylsNodeEndpoint, _userGovernance, msg.sender, false)
    {}
}

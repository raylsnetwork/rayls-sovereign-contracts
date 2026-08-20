// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsErc721DvpHandler.sol';

/**
 * @title ProductionErc721Dvp
 * @notice Production-grade concrete ERC721 DvP token seeded as the canonical `RAYLS_ERC721_DVP_KEY`
 *         bytecode on `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime
 *         bytecode via `InitCodeStub`, so the runtime surface here is what ships to every instance.
 * @dev    This contract adds NO functions beyond the audited {RaylsErc721DvpHandler} base. The
 *         base already implements `_baseURI()` from its `_uri` storage (set in
 *         {RaylsErc721DvpHandler-initialize}), so no override is needed. The constructor is a thin
 *         passthrough required only so the artifact compiles to non-empty `deployedBytecode`; it
 *         does NOT run under `InitCodeStub`. The `raylsNodeEndpoint`/`userGovernance` slots are
 *         `address(0)` to match the DvP base's deploy convention.
 */
contract ProductionErc721Dvp is RaylsErc721DvpHandler {
    constructor(
        string memory baseUri,
        string memory name,
        string memory symbol,
        address _endpoint
    ) RaylsErc721DvpHandler(baseUri, name, symbol, _endpoint, address(0), address(0), msg.sender, false) {}
}

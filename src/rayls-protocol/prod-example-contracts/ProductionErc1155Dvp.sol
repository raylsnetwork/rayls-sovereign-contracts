// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsErc1155DvpHandler.sol';

/**
 * @title ProductionErc1155Dvp
 * @notice Production-grade concrete ERC1155 DvP token seeded as the canonical `RAYLS_ERC1155_DVP_KEY`
 *         bytecode on `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime
 *         bytecode via `InitCodeStub`, so the runtime surface here is what ships to every instance.
 * @dev    This contract adds NO functions beyond the audited {RaylsErc1155DvpHandler} base. The
 *         constructor is a thin passthrough required only so the artifact compiles to non-empty
 *         `deployedBytecode`; it does NOT run under `InitCodeStub`. The
 *         `raylsNodeEndpoint`/`userGovernance` slots are `address(0)` to match the DvP base's
 *         deploy convention.
 */
contract ProductionErc1155Dvp is RaylsErc1155DvpHandler {
    constructor(
        string memory baseUri,
        string memory name,
        address _endpoint
    ) RaylsErc1155DvpHandler(baseUri, name, _endpoint, address(0), address(0), msg.sender, false) {}
}

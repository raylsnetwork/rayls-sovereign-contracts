// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsEnygmaHandler.sol';

/**
 * @title ProductionEnygmaToken
 * @notice Production-grade concrete Enygma token seeded as the canonical `RAYLS_ENYGMA_KEY` bytecode
 *         on `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime bytecode
 *         via `InitCodeStub`, so the runtime surface here is what ships to every deployed instance.
 * @dev    This contract adds NO functions beyond the audited {RaylsEnygmaHandler} base — no
 *         test-only mint hooks, revert traps, or unrestricted minting. The constructor is a thin
 *         passthrough required only so the artifact compiles to non-empty `deployedBytecode`; it
 *         does NOT run under `InitCodeStub` (the factory installs runtime bytecode directly and the
 *         instance is configured via {RaylsEnygmaHandler-initialize}).
 */
contract ProductionEnygmaToken is RaylsEnygmaHandler {
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint
    ) RaylsEnygmaHandler(_name, _symbol, _endpoint, msg.sender, 18, false) {}
}

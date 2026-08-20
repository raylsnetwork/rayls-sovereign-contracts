// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '../../rayls-protocol-sdk/tokens/RaylsStableCoinHandler.sol';

/**
 * @title ProductionStableCoin
 * @notice Production-grade concrete stablecoin seeded as the canonical `RAYLS_STABLECOIN_KEY` bytecode
 *         on `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime bytecode via
 *         `InitCodeStub`, so the runtime surface here is what ships to every deployed instance.
 * @dev    Adds NO functions beyond {RaylsStableCoinHandler}. The constructor is a thin passthrough
 *         required only so the artifact compiles to non-empty `deployedBytecode`; it does NOT run
 *         under `InitCodeStub` (the instance is configured via {RaylsErc20Handler-initialize}, which
 *         {RaylsStableCoinHandler} overrides).
 */
contract ProductionStableCoin is RaylsStableCoinHandler {
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    ) RaylsStableCoinHandler(_name, _symbol, _endpoint, _raylsNodeEndpoint, _userGovernance) {}
}

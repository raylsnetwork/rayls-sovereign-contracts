// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsErc20Handler.sol';

/**
 * @title ProductionErc20Token
 * @notice Production-grade concrete ERC20 token seeded as the canonical `RAYLS_ERC20_KEY` bytecode on
 *         `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime bytecode via
 *         `InitCodeStub`, so the runtime surface here is what ships to every deployed instance.
 * @dev    This contract adds NO functions beyond the audited {RaylsErc20Handler} base — no
 *         `fakeMint`, no test-only revert traps, no premint. The constructor is a thin passthrough
 *         required only so the artifact compiles to non-empty `deployedBytecode`; it does NOT run
 *         under `InitCodeStub` (the instance is configured via {RaylsErc20Handler-initialize}).
 */
contract ProductionErc20Token is RaylsErc20Handler {
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    )
        RaylsErc20Handler(
            _name,
            _symbol,
            _endpoint,
            _raylsNodeEndpoint,
            _userGovernance,
            msg.sender,
            false
        )
    {}
}

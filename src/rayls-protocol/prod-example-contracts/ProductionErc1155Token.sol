// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/tokens/RaylsErc1155Handler.sol';

/**
 * @title ProductionErc1155Token
 * @notice Production-grade concrete ERC1155 token seeded as the canonical `RAYLS_ERC1155_KEY` bytecode on
 *         `RNContractFactoryV1`. FACTORY-mode deploys reuse this contract's runtime bytecode via
 *         `InitCodeStub`, so the runtime surface here is what ships to every deployed instance.
 * @dev    Replaces the former `RaylsErc1155Example`, which carried a test-only revert trap and a
 *         constructor premint. This contract adds NO functions beyond the audited
 *         {RaylsErc1155Handler} base. The constructor is a thin passthrough required only so the
 *         artifact compiles to non-empty `deployedBytecode`; it does NOT run under `InitCodeStub`
 *         (the instance is configured via {RaylsErc1155Handler-initialize}).
 */
contract ProductionErc1155Token is RaylsErc1155Handler {
    constructor(
        string memory _url,
        string memory name,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    )
        RaylsErc1155Handler(_url, name, _endpoint, _raylsNodeEndpoint, _userGovernance, msg.sender, false)
    {}
}

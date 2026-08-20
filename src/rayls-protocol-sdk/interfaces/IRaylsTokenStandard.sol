// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {SharedObjects} from '../libraries/SharedObjects.sol';

/// @notice Minimal token-standard surface exposed by Rayls token contracts.
interface IRaylsTokenStandard {
    /// @notice Returns the token standard used by TokenCore metadata handling.
    /// @dev Implementers may override to report their own standard — e.g. the test `*Example`
    ///      contracts, including the `*Test` variants, which drive the receiver-side factory key
    ///      (`RAYLS_*_TEST_KEY`) on cross-chain auto-deploy.
    function GetERCStandard() external pure returns (SharedObjects.ErcStandard);
}
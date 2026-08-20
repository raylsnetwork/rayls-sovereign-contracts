// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './TestContractV1.sol';

/**
 * @title TestContractV2
 * @notice Test contract for UUPS upgradability - Version 2
 * @dev Extends V1 and adds storage variable _val2 with getter/setter
 * @dev CRITICAL: New storage variables must be appended, never reorder existing ones!
 */
contract TestContractV2 is TestContractV1 {
    /// @notice Storage variable added in V2
    /// @dev This MUST come after all V1 storage variables to preserve storage layout
    uint256 private _val2;

    /// @notice Emitted when _val2 is updated
    event Val2Updated(uint256 oldValue, uint256 newValue);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // NOTE: No initializer needed in V2 - V1's initialize() already ran via proxy

    /**
     * @notice Get the value of _val2 (new in V2)
     * @return Current value of _val2
     */
    function getVal2() external view returns (uint256) {
        return _val2;
    }

    /**
     * @notice Set the value of _val2 (new in V2)
     * @param newVal New value to set
     */
    function setVal2(uint256 newVal) external {
        uint256 oldVal = _val2;
        _val2 = newVal;
        emit Val2Updated(oldVal, newVal);
    }

    /**
     * @notice Get the contract version (overridden from V1)
     * @return Version identifier (2 for V2)
     */
    function version() external pure override returns (uint256) {
        return 2;
    }

    // _authorizeUpgrade is inherited from TestContractV1 (no changes needed)
}

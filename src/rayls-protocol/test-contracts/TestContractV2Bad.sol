// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title TestContractV2Bad
 * @notice INTENTIONALLY BROKEN test contract to verify storage layout validation
 * @dev This contract VIOLATES upgrade safety by changing storage variable type
 * @dev DO NOT USE - This is for testing validation only!
 *
 * BREAKING CHANGE: _val1 is changed from uint256 to uint128
 * This breaks storage layout compatibility with TestContractV1
 */
contract TestContractV2Bad is
    Initializable,
    RaylsAccessManaged,
    UUPSUpgradeable
{
    /// @notice UNSAFE: Changed from uint256 to uint128 (breaks upgrades!)
    uint128 private _val1;  // ❌ WRONG! Was uint256 in V1

    /// @notice New storage variable for V2
    uint256 private _val2;

    /// @notice Emitted when _val1 is updated
    event Val1Updated(uint128 oldValue, uint128 newValue);

    /// @notice Emitted when _val2 is updated
    event Val2Updated(uint256 oldValue, uint256 newValue);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract (called by proxy)
     * @param authority_ Address of the RaylsAccessManager
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        _initializeAuthority(authority_);
    }

    /**
     * @notice Get the value of _val1
     * @return Current value of _val1
     */
    function getVal1() external view returns (uint128) {
        return _val1;
    }

    /**
     * @notice Set the value of _val1
     * @param newVal New value to set
     */
    function setVal1(uint128 newVal) external {
        uint128 oldVal = _val1;
        _val1 = newVal;
        emit Val1Updated(oldVal, newVal);
    }

    /**
     * @notice Get the value of _val2
     * @return Current value of _val2
     */
    function getVal2() external view returns (uint256) {
        return _val2;
    }

    /**
     * @notice Set the value of _val2
     * @param newVal New value to set
     */
    function setVal2(uint256 newVal) external {
        uint256 oldVal = _val2;
        _val2 = newVal;
        emit Val2Updated(oldVal, newVal);
    }

    /**
     * @notice Get the contract version
     * @return Version identifier (2 for V2)
     */
    function version() external pure virtual returns (uint256) {
        return 2;
    }

    /**
     * @dev Required by UUPS pattern. Only authorized callers can upgrade.
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        restricted
    {}
}

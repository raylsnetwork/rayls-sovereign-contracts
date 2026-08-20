// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title TestContractV1
 * @notice Test contract for UUPS upgradability - Version 1
 * @dev Contains single storage variable _val1 with getter/setter
 */
contract TestContractV1 is
    Initializable,
    RaylsAccessManaged,
    UUPSUpgradeable
{
    /// @notice Storage variable for V1
    uint256 private _val1;

    /// @notice Emitted when _val1 is updated
    event Val1Updated(uint256 oldValue, uint256 newValue);

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
    function getVal1() external view returns (uint256) {
        return _val1;
    }

    /**
     * @notice Set the value of _val1
     * @param newVal New value to set
     */
    function setVal1(uint256 newVal) external {
        uint256 oldVal = _val1;
        _val1 = newVal;
        emit Val1Updated(oldVal, newVal);
    }

    /**
     * @notice Get the contract version
     * @return Version identifier (1 for V1)
     */
    function version() external pure virtual returns (uint256) {
        return 1;
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

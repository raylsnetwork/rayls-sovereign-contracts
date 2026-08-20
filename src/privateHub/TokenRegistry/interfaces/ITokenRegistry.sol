// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../rayls-protocol-sdk/libraries/SharedObjects.sol";
import "../libraries/TokenStructs.sol";
import "./ITokenCore.sol";
import "./ITokenFreezeManager.sol";
import "./IEnygmaTokenManager.sol";

/**
 * @title ITokenRegistry
 * @dev Interface for the TokenRegistryV1 contract that uses composition to delegate to modules
 */
interface ITokenRegistry {
    // ========== Module Getters ==========

    /**
     * @notice Gets the TokenCore module
     * @return The address of the TokenCore module
     */
    function getTokenCore() external view returns (ITokenCore);
    
    /**
     * @notice Gets the TokenFreezeManager module
     * @return The address of the TokenFreezeManager module
     */
    function getTokenFreezeManager() external view returns (ITokenFreezeManager);
    
    /**
     * @notice Gets the EnygmaTokenManager module
     * @return The address of the EnygmaTokenManager module
     */
    function getEnygmaTokenManager() external view returns (IEnygmaTokenManager);
    
    // ========== Module Configuration ==========

    /**
     * @notice Configures all modules in a single transaction
     * @param _tokenCore The address of the TokenCore module
     * @param _tokenFreezeManager The address of the TokenFreezeManager module
     * @param _enygmaTokenManager The address of the EnygmaTokenManager module
     */
    function configureModules(
        address _tokenCore,
        address _tokenFreezeManager,
        address _enygmaTokenManager
    ) external;
    
    /**
     * @notice Sets the TokenCore module
     * @param _tokenCore The address of the TokenCore module
     */
    function setTokenCore(address _tokenCore) external;
    
    /**
     * @notice Sets the TokenFreezeManager module
     * @param _tokenFreezeManager The address of the TokenFreezeManager module
     */
    function setTokenFreezeManager(address _tokenFreezeManager) external;
    
    /**
     * @notice Sets the EnygmaTokenManager module
     * @param _enygmaTokenManager The address of the EnygmaTokenManager module
     */
    function setEnygmaTokenManager(address _enygmaTokenManager) external;

    // ========== Contract Version ==========

    /**
     * @notice Gets the contract version
     * @return The contract version
     */
    function contractVersion() external pure returns (uint256);
} 
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RaylsPublicApp} from "../RaylsPublicApp.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RaylsNodeBridgedTransferMetadata, RaylsNodeBridgeableERC} from "../../rayls-privacy-node/RNMessageLib.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

/**
 * @title RaylsPublicERC20Handler
 * @notice Handles ERC20 token operations for cross-chain bridging in Rayls Network
 * @dev Abstract contract that manages token burning/minting for cross-chain transfers
 * @custom:deprecated Decommissioning Teleport (vanilla, atomic).
 */
abstract contract RaylsPublicERC20Handler is RaylsPublicApp, ERC20 {

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error RaylsPublicERC20Handler__DestinationIsZeroAddress();
    error RaylsPublicERC20Handler__AmountMustBeGreaterThanZero();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when this ERC20 public chain token contract is created
    /// @param tokenAddress The address of the newly created token contract
    event RaylsPublicErc20TokenCreated(address indexed tokenAddress);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    string private tokenName;
    string private tokenSymbol;
    address private privateAddress;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Rayls Public ERC20 Handler
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _raylsNodeEndpoint Address of the Rayls Node endpoint
     * @param _owner Owner address
     * @param _privateAddress Corresponding private chain address
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _raylsNodeEndpoint,
        address _owner,
        address _privateAddress
    )
        ERC20(_name, _symbol)
        RaylsPublicApp(_raylsNodeEndpoint)
    {
        tokenName = _name;
        tokenSymbol = _symbol;
        privateAddress = _privateAddress;
        _registerAccessControl(_owner);
        emit RaylsPublicErc20TokenCreated(address(this));
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burns tokens on public chain and initiates cross-chain unlock on private chain
     * @param to Recipient address on private chain
     * @param amount Amount of tokens to burn
     * @param chainId Destination chain ID
     * @return bool Success status
     */
    function teleportToPrivacyNode(address to, uint256 amount, uint256 chainId) external virtual returns (bool) {
        if (to == address(0)) {
            revert RaylsPublicERC20Handler__DestinationIsZeroAddress();
        }
        if (amount == 0) {
            revert RaylsPublicERC20Handler__AmountMustBeGreaterThanZero();
        }
        _burn(msg.sender, amount);

        RaylsNodeBridgedTransferMetadata memory transferMetadata = RaylsNodeBridgedTransferMetadata({
            assetType: RaylsNodeBridgeableERC.ERC20,
            id: 0,
            from: msg.sender,
            tokenAddress: address(this),
            to: to,
            amount: amount
        });

        publicRaylsNodeEndpoint.sendToAddress(
            chainId,
            privateAddress,
            abi.encodeWithSignature("receiveTeleportFromPublicChain(address,uint256)", to, amount),
            abi.encodeWithSignature("revertTeleportToPrivacyNode(address,uint256)", msg.sender, amount),
            transferMetadata
        );
        return true;
    }

    /**
     * @notice Mints tokens on public chain (called from private chain)
     * @dev If `to` is the zero address the mint cannot proceed; instead an explicit callback is sent
     *      back to the private chain via the public endpoint so the relayer can restore the locked tokens.
     *      This avoids relying on the public relayer's revert-callback mechanism, which cannot deliver
     *      transactions to the private chain.
     * @param from Original sender on the private chain (used to restore the lock on failure)
     * @param srcChainId Private chain ID (destination for the restore callback)
     * @param to Recipient address on the public chain
     * @param amount Amount of tokens to mint
     */
    function receiveTeleportFromPrivacyNode(address from, uint256 srcChainId, address to, uint256 amount) external virtual restricted {
        if (to == address(0)) {
            RaylsNodeBridgedTransferMetadata memory transferMetadata = RaylsNodeBridgedTransferMetadata({
                assetType: RaylsNodeBridgeableERC.ERC20,
                id: 0,
                from: from,
                tokenAddress: address(this),
                to: from,
                amount: amount
            });
            publicRaylsNodeEndpoint.sendToAddress(
                srcChainId,
                privateAddress,
                abi.encodeWithSignature("revertTeleportToPublicChain(address,uint256)", from, amount),
                bytes(""),
                transferMetadata
            );
            return;
        }
        _mint(to, amount);
    }

    /**
     * @notice Reverts a failed cross-chain burn by minting tokens back
     * @dev Called when cross-chain transaction fails on destination chain
     * @param to Address to mint tokens back to
     * @param amount Amount of tokens to mint
     */
    function revertTeleportToPrivacyNode(address to, uint256 amount) external virtual restricted {
        _mint(to, amount);
    }

    /**
     * @notice Mints tokens (owner only)
     * @param to Recipient address
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external virtual restricted {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens (owner only)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external virtual restricted {
        _burn(from, amount);
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the token name
     * @return Token name
     */
    function name() public view override returns (string memory) {
        return tokenName;
    }

    /**
     * @notice Returns the token symbol
     * @return Token symbol
     */
    function symbol() public view override returns (string memory) {
        return tokenSymbol;
    }

    /**
     * @notice Returns the corresponding private chain address
     * @return Private chain address
     */
    function privateChainAddress() external view returns (address) {
        return privateAddress;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Registers this token with the RaylsAccessManager via selfRegisterManagedContract.
     *      Maps receive/revert selectors to MESSAGE_EXECUTOR and mint/burn to TOKEN_OWNER.
     * @param _owner The deployer address that becomes the target authority
     */
    function _registerAccessControl(address _owner) internal {
        address mgr = authority();
        if (mgr == address(0)) return;

        bytes4[] memory ownerSelectors = new bytes4[](2);
        ownerSelectors[0] = this.mint.selector;
        ownerSelectors[1] = this.burn.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory roleMappings =
            new IRaylsAccessManager.SelectorRoleMapping[](1);

        bytes4[] memory executorSelectors = new bytes4[](2);
        executorSelectors[0] = this.receiveTeleportFromPrivacyNode.selector;
        executorSelectors[1] = this.revertTeleportToPrivacyNode.selector;

        roleMappings[0] = IRaylsAccessManager.SelectorRoleMapping({
            roleName: "MESSAGE_EXECUTOR",
            selectors: executorSelectors
        });

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSelectors, roleMappings);
    }

}
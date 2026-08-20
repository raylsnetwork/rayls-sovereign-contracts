pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol"; // SPDX-License-Identifier: MIT
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title RaylsDvpSettlement
 * @dev Contract to manage Delivery-versus-Payment (DvP) settlements between parties.
 *
 * This contract enables secure asset exchanges between two parties by:
 * - Creating settlement agreements with specific assets from both sides
 * - Guaranteeing atomic execution (both transfers happen or none)
 * - Supporting both ERC20 and ERC1155 token standards
 * - Enforcing time-based expirations for settlements
 * - Handling both designated counterparty and open settlement scenarios
 *
 * The DvP model ensures that assets are only transferred when both parties 
 * have committed their respective assets, eliminating counterparty risk.
 */
contract RaylsDvpSettlement {
    /**
     * @dev Enum representing the possible states of a settlement
     * NOT_EXISTS - Default state for non-existent settlements
     * INITIALIZED - Settlement created but not yet executed
     * EXECUTED - Settlement successfully completed
     * EXPIRED - Settlement expired without execution
     */
    enum SettlementStatus {
        NOT_EXISTS,
        INITIALIZED,
        EXECUTED,
        EXPIRED
    }

    /**
     * @dev Enum representing the supported asset types
     * ERC20 - Standard fungible tokens
     * ERC1155 - Multi-token standard for fungible and non-fungible tokens
     */
    enum AssetType {
        ERC20,
        ERC1155
    }

    /**
     * @dev Structure representing an asset to be exchanged
     * @param assetType Type of the asset (ERC20 or ERC1155)
     * @param tokenAddress Contract address of the token
     * @param amount Amount of tokens to be transferred
     * @param tokenId ID of the token (only used for ERC1155, ignored for ERC20)
     */
    struct Asset {
        AssetType assetType;
        address tokenAddress;
        uint256 amount;
        uint256 tokenId; // Relevant for ERC1155, can be ignored for ERC20
    }

    /**
     * @dev Structure representing a complete settlement agreement
     * @param creator Address that created the settlement
     * @param creatorAsset Asset offered by the creator
     * @param creatorBeneficiary Address that receives the counterparty's asset (if 0x0, creator receives)
     * @param counterparty Address of the designated counterparty (if 0x0, open to anyone)
     * @param counterpartyAsset Asset required from the counterparty
     * @param expirationDate Timestamp after which the settlement can no longer be executed
     * @param status Current status of the settlement
     */
    struct Settlement {
        address creator;
        Asset creatorAsset;
        address creatorBeneficiary;
        address counterparty;
        Asset counterpartyAsset;
        uint256 expirationDate;
        SettlementStatus status;
    }

    // ID of the most recently created settlement
    uint256 public lastSettlementId;
    
    // Mapping from settlement ID to Settlement struct
    mapping(uint256 => Settlement) public settlements;

    // Events
    /**
     * @dev Emitted when a new settlement is created
     * @param settlementId Unique identifier of the created settlement
     * @param settlement Complete settlement data structure
     */
    event SettlementInitialized(
        uint256 indexed settlementId,
        Settlement settlement
    );
    
    /**
     * @dev Emitted when a settlement is successfully executed
     * @param settlementId Unique identifier of the executed settlement
     * @param executor Address that executed the settlement
     */
    event SettlementExecuted(
        uint256 indexed settlementId,
        address indexed executor
    );
    
    /**
     * @dev Emitted when a settlement expires
     * @param settlementId Unique identifier of the expired settlement
     */
    event SettlementExpired(uint256 indexed settlementId);

    /**
     * @notice Creates a new settlement agreement
     * @dev Initializes a new settlement and verifies creator has sufficient balance and allowance
     * @param creatorAsset Asset the creator is offering in the settlement
     * @param creatorBeneficiary Address that will receive the counterparty's asset (if 0x0, creator receives)
     * @param counterparty Address of the designated counterparty (if 0x0, open to anyone)
     * @param counterpartyAsset Asset required from the counterparty
     * @param expirationDate Timestamp after which the settlement expires
     * 
     * Requirements:
     * - Expiration date must be in the future
     * - Creator must have sufficient balance of the offered asset
     * - Creator must have given sufficient allowance to this contract
     */
    function createSettlement(
        Asset memory creatorAsset,
        address creatorBeneficiary,
        address counterparty,
        Asset memory counterpartyAsset,
        uint256 expirationDate
    ) external {
        require(
            expirationDate > block.timestamp,
            "RaylsDvpSettlement: INVALID_EXPIRATION_DATE"
        );
        require(
            lastSettlementId < type(uint256).max,
            "RaylsDvpSettlement: INVALID_SETTLEMENT_ID"
        );

        // Increment the settlement ID for the new settlement
        lastSettlementId++;

        // Create and initialize the new settlement
        Settlement storage settlement = settlements[lastSettlementId];
        settlement.creator = msg.sender;
        settlement.creatorAsset = creatorAsset;
        settlement.creatorBeneficiary = creatorBeneficiary;
        settlement.counterparty = counterparty;
        settlement.counterpartyAsset = counterpartyAsset;
        settlement.expirationDate = expirationDate;
        settlement.status = SettlementStatus.INITIALIZED;

        // Check creator's allowance and balance based on asset type
        if (creatorAsset.assetType == AssetType.ERC20) {
            // For ERC20, verify allowance and balance
            require(
                IERC20(creatorAsset.tokenAddress).allowance(
                    settlement.creator,
                    address(this)
                ) >= creatorAsset.amount,
                "RaylsDvpSettlement: INSUFFICIENT_ALLOWANCE"
            );

            require(
                IERC20(creatorAsset.tokenAddress).balanceOf(
                    settlement.creator
                ) >= creatorAsset.amount,
                "RaylsDvpSettlement: INSUFFICIENT_BALANCE"
            );
        } else if (creatorAsset.assetType == AssetType.ERC1155) {
            // For ERC1155, verify approval for all and balance
            require(
                IERC1155(creatorAsset.tokenAddress).isApprovedForAll(
                    settlement.creator,
                    address(this)
                ),
                "RaylsDvpSettlement: NOT_APPROVED_FOR_ALL"
            );

            require(
                IERC1155(creatorAsset.tokenAddress).balanceOf(
                    settlement.creator,
                    creatorAsset.tokenId
                ) >= creatorAsset.amount,
                "RaylsDvpSettlement: INSUFFICIENT_BALANCE"
            );
        } else {
            revert("RaylsDvpSettlement: INVALID_ASSET_TYPE");
        }

        emit SettlementInitialized(lastSettlementId, settlement);
    }

    /**
     * @notice Executes an existing settlement by transferring assets between parties
     * @dev Performs atomic exchange of assets between creator and counterparty
     * @param settlementId ID of the settlement to execute
     * 
     * Requirements:
     * - Settlement must be in INITIALIZED status
     * - Settlement must not be expired
     * - Caller must be the designated counterparty (or anyone if counterparty is 0x0)
     * - Both parties must have sufficient balance and allowance for their respective assets
     * 
     * The function performs both transfers in a single transaction, ensuring atomicity.
     * If any part of the transaction fails, the entire operation is reverted.
     */
    function executeSettlement(uint256 settlementId) external {
        Settlement storage settlement = settlements[settlementId];

        // Verify settlement state and permissions
        require(
            settlement.status == SettlementStatus.INITIALIZED,
            "RaylsDvpSettlement: SETTLEMENT_NOT_INITIALIZED"
        );
        require(
            settlement.expirationDate > block.timestamp,
            "RaylsDvpSettlement: SETTLEMENT_EXPIRED"
        );
        require(
            // if empty (0x0) counterparty address, consider it an "open" settlement
            settlement.counterparty == address(0) ||
                settlement.counterparty == msg.sender,
            "RaylsDvpSettlement: UNAUTHORIZED_SENDER"
        );

        // Determine the final recipients for assets
        // if empty (0x0) creatorBeneficiary address, send funds to creator
        address creatorReceiver = (settlement.creatorBeneficiary == address(0))
            ? settlement.creator
            : settlement.creatorBeneficiary;

        // if empty (0x0) counterpartyReceiver address, send funds to msg.sender
        address counterpartyReceiver = (settlement.counterparty == address(0))
            ? msg.sender
            : settlement.counterparty;

        // Mark settlement as executed before transfers
        settlement.status = SettlementStatus.EXECUTED;

        // Transfer Creator Asset to Counterparty Receiver
        if (settlement.creatorAsset.assetType == AssetType.ERC20) {
            _erc20TransferFrom(
                settlement.creatorAsset.tokenAddress,
                settlement.creator,
                counterpartyReceiver,
                settlement.creatorAsset.amount
            );
        } else if (settlement.creatorAsset.assetType == AssetType.ERC1155) {
            _erc1155TransferFrom(
                settlement.creatorAsset.tokenAddress,
                settlement.creator,
                counterpartyReceiver,
                settlement.creatorAsset.tokenId,
                settlement.creatorAsset.amount
            );
        } else {
            revert(
                "RaylsDvpSettlement: INVALID_ASSET_TYPE for creator"
            );
        }

        // Transfer Counterparty Asset to Creator Receiver
        if (settlement.counterpartyAsset.assetType == AssetType.ERC20) {
            _erc20TransferFrom(
                settlement.counterpartyAsset.tokenAddress,
                counterpartyReceiver,
                creatorReceiver,
                settlement.counterpartyAsset.amount
            );
        } else if (
            settlement.counterpartyAsset.assetType == AssetType.ERC1155
        ) {
            _erc1155TransferFrom(
                settlement.counterpartyAsset.tokenAddress,
                counterpartyReceiver,
                creatorReceiver,
                settlement.counterpartyAsset.tokenId,
                settlement.counterpartyAsset.amount
            );
        } else {
            revert(
                "RaylsDvpSettlement: INVALID_ASSET_TYPE for counterparty"
            );
        }

        emit SettlementExecuted(settlementId, counterpartyReceiver);
    }

    /**
     * @dev Internal helper function to transfer ERC20 tokens
     * @param tokenAddress Address of the ERC20 token contract
     * @param from Address to transfer tokens from
     * @param to Address to transfer tokens to
     * @param amount Amount of tokens to transfer
     * 
     * Reverts if the transfer fails for any reason.
     */
    function _erc20TransferFrom(
        address tokenAddress,
        address from,
        address to,
        uint256 amount
    ) internal {
        require(
            IERC20(tokenAddress).transferFrom(from, to, amount),
            "RaylsDvpSettlement: TRANSFER_FAILED"
        );
    }

    /**
     * @dev Internal helper function to transfer ERC1155 tokens
     * @param tokenAddress Address of the ERC1155 token contract
     * @param from Address to transfer tokens from
     * @param to Address to transfer tokens to
     * @param tokenId ID of the token to transfer
     * @param amount Amount of tokens to transfer
     */
    function _erc1155TransferFrom(
        address tokenAddress,
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) internal {
        IERC1155(tokenAddress).safeTransferFrom(from, to, tokenId, amount, "");
    }

    /**
     * @notice Marks an expired settlement as EXPIRED
     * @dev Can be called by anyone once the expiration date has passed
     * @param settlementId ID of the settlement to expire
     * 
     * Requirements:
     * - Settlement must be in INITIALIZED status
     * - Current time must be past the settlement's expiration date
     */
    function expireSettlement(uint256 settlementId) external {
        Settlement storage settlement = settlements[settlementId];

        require(
            settlement.status == SettlementStatus.INITIALIZED,
            "RaylsDvpSettlement: SETTLEMENT_NOT_INITIALIZED"
        );
        require(
            settlement.expirationDate < block.timestamp,
            "RaylsDvpSettlement: SETTLEMENT_NOT_YET_EXPIRED"
        );

        settlement.status = SettlementStatus.EXPIRED;
        emit SettlementExpired(settlementId);
    }
}

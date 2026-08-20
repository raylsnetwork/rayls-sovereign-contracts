// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import '../../rayls-protocol-sdk/libraries/Utils.sol';
import {Initializable} from '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import {UUPSUpgradeable} from '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {RaylsAccessManaged} from '../AccessControl/RaylsAccessManaged.sol';

/**
 * @title TeleportV1
 * @dev Contract for storing privacy node data and related operations.
 *
 * All privileged functions are gated by RaylsAccessManagerV1 via the `restricted` modifier.
 * @dev Decommissioning Teleport (vanilla, atomic): the atomic-teleport members below are individually
 *      deprecated; the block-header members and the hybrid storeEncryptedDataBatch are retained.
 */
contract TeleportV1 is Initializable, UUPSUpgradeable, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    error TeleportV1__MessageAlreadyExecuted(string msgId);
    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    error TeleportV1__MessageAlreadyReverted(string msgId);

    /*//////////////////////////////////////////////////////////////
                           TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    struct AtomicTeleportMessage {
        Utils.MessageStatus status;
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    struct MessageStatusResult {
        string msgId;
        string status;
    }

    struct dataBatch {
        string batchId;
        string messageTag;
        bytes data;
        string[] sharedIds;
    }

    struct Header {
        string parentHash;
        string uncleHash;
        string coinbase;
        string stateRoot;
        string transactionsRoot;
        string receiptsRoot;
        bytes logsBloom;
        uint256 difficulty;
        uint256 number;
        uint64 gasLimit;
        uint64 gasUsed;
        uint64 timestamp;
        uint8[] extra;
        string mixHash;
        bytes8 nonce;
        string _hash;
    }

    struct TokenInfo {
        string name;
        string symbol;
    }

    /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES, EVENTS
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => Header[]) private headers;
    mapping(string => Header) private singleHeader;

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    mapping(string => AtomicTeleportMessage) public atomicTeleportMessages;

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    mapping(Utils.MessageStatus => string) public AtomicStatus;

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    event AtomicMessageStatusChangedBatch(string[] msgIds, Utils.MessageStatus status);
    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    event AtomicMessageTeleportStartedBatch(string[] msgIds);

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    event AtomicMessageAdditionalDataBatch(string[] msgIds, string encryptedData);

    event EncryptedDataBatchStored(string messageTag, bytes data, uint256 indexed blockNumber);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Teleport contract.
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        AtomicStatus[Utils.MessageStatus.Pending] = 'Pending';
        AtomicStatus[Utils.MessageStatus.Executed] = 'Executed';
        AtomicStatus[Utils.MessageStatus.Rejected] = 'Rejected';
        AtomicStatus[Utils.MessageStatus.Reverted] = 'Reverted';
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /// @dev HYBRID: the shared encrypted-data path (EncryptedDataBatchStored) is retained; the atomic
    ///      branch (batch.sharedIds → storeAtomicMessageBatch) is decommissioned.
    function storeEncryptedDataBatch(dataBatch calldata batch, uint256 blockNumber) public virtual restricted {
        if (batch.sharedIds.length > 0) {
            storeAtomicMessageBatch(batch.sharedIds);
        }
        emit EncryptedDataBatchStored(batch.messageTag, batch.data, blockNumber);
    }

    function addHeader(uint256 chainId, Header memory header) public virtual restricted {
        headers[chainId].push(header);
    }

    function getHeaders(uint256 chainId) public view virtual returns (Header[] memory header) {
        return headers[chainId];
    }

    function addSingleHeader(string calldata _hash, Header memory header) public virtual restricted {
        singleHeader[_hash] = header;
    }

    function getSingleHeader(string calldata _hash) public view virtual returns (Header memory header) {
        return singleHeader[_hash];
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function storeAtomicMessageBatch(string[] calldata msgIds) internal virtual {
        for (uint256 i = 0; i < msgIds.length; i++) {
            atomicTeleportMessages[msgIds[i]].status = Utils.MessageStatus.Pending;
        }

        emit AtomicMessageTeleportStartedBatch(msgIds);
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function executeAtomicMessageBatch(string[] calldata msgIds, string calldata encryptedData_) external virtual restricted {
        bool[] memory transitioned = new bool[](msgIds.length);
        uint256 transitionedCount = 0;
        for (uint256 i = 0; i < msgIds.length; i++) {
            AtomicTeleportMessage storage message = atomicTeleportMessages[msgIds[i]];
            if (message.status == Utils.MessageStatus.Executed) {
                // Idempotent: an at-least-once retry of the executed-notification must
                // NOT surface a "reverted" error, otherwise the relayer would treat the
                // message as race-lost and burn an already-executed mint, destroying funds.
                continue;
            }
            if (message.status != Utils.MessageStatus.Pending) {
                // Reverted (or Rejected): the message already lost the race to a revert and
                // can never be executed. Surface the correct error so the relayer burns its
                // orphan mint rather than releasing it.
                revert TeleportV1__MessageAlreadyReverted(msgIds[i]);
            }
            message.status = Utils.MessageStatus.Executed;
            transitioned[i] = true;
            transitionedCount++;
        }

        // Emit only for the messages that actually transitioned Pending->Executed in this call.
        // A pure idempotent retry transitions nothing and emits nothing; a (defensively-handled)
        // mixed batch never re-includes an already-terminal id, so the relayer never projects a
        // duplicate status row (atomic_status is keyed by msgId).
        if (transitionedCount > 0) {
            string[] memory changed = _filterTransitioned(msgIds, transitioned, transitionedCount);
            emit AtomicMessageStatusChangedBatch(changed, Utils.MessageStatus.Executed);
            emit AtomicMessageAdditionalDataBatch(changed, encryptedData_);
        }
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function EmitAdditionalAtomicDataBatchFor(string[] calldata msgIds, string calldata encryptedData_) external virtual restricted {
        emit AtomicMessageAdditionalDataBatch(msgIds, encryptedData_);
    }

    /// @notice Reverts a batch of pending atomic messages.
    /// @dev Reverts are gated solely by `status` and the `restricted` modifier; there is no
    ///      on-chain expiration/lock-time window (expiry is enforced off-chain by the relayer).
    ///      Idempotent on already-reverted messages; an executed message can NEVER be reverted
    ///      (the core double-spend guard).
    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function revertAtomicMessageBatch(string[] calldata msgIds, string calldata encryptedData_) external virtual restricted {
        bool[] memory transitioned = new bool[](msgIds.length);
        uint256 transitionedCount = 0;
        for (uint i = 0; i < msgIds.length; i++) {
            AtomicTeleportMessage storage message = atomicTeleportMessages[msgIds[i]];
            if (message.status == Utils.MessageStatus.Reverted) {
                // Idempotent: an at-least-once retry of the timeout-revert must succeed instead
                // of wedging the source row (which would leave the sender un-refunded forever).
                continue;
            }
            if (message.status != Utils.MessageStatus.Pending) {
                // Executed (or Rejected): an executed message must never be reverted — that is
                // the core double-spend guard. Surface the correct error so the source relayer
                // does not refund a sender whose transfer already executed.
                revert TeleportV1__MessageAlreadyExecuted(msgIds[i]);
            }
            message.status = Utils.MessageStatus.Reverted;
            transitioned[i] = true;
            transitionedCount++;
        }
        // Emit only for the messages that actually transitioned Pending->Reverted (see
        // executeAtomicMessageBatch for the rationale).
        if (transitionedCount > 0) {
            string[] memory changed = _filterTransitioned(msgIds, transitioned, transitionedCount);
            emit AtomicMessageStatusChangedBatch(changed, Utils.MessageStatus.Reverted);
            emit AtomicMessageAdditionalDataBatch(changed, encryptedData_);
        }
    }

    /// @dev Returns the `keepCount` entries of `msgIds` flagged in `keep`, preserving order.
    ///      Used so status/additional-data events carry only the messages that actually changed
    ///      state in this call — never an already-terminal id from a mixed batch.
    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function _filterTransitioned(
        string[] calldata msgIds,
        bool[] memory keep,
        uint256 keepCount
    ) private pure returns (string[] memory filtered) {
        filtered = new string[](keepCount);
        uint256 j = 0;
        for (uint256 i = 0; i < msgIds.length; i++) {
            if (keep[i]) {
                filtered[j] = msgIds[i];
                j++;
            }
        }
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function getAtomicMessage(string calldata msgId) external view virtual returns (AtomicTeleportMessage memory) {
        return atomicTeleportMessages[msgId];
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function getAtomicMessageStatus(string calldata msgId) external view virtual returns (string memory) {
        Utils.MessageStatus _status = atomicTeleportMessages[msgId].status;
        return AtomicStatus[_status];
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function getAtomicMessageStatuses(string[] calldata msgIds) external view virtual returns (MessageStatusResult[] memory) {
        MessageStatusResult[] memory results = new MessageStatusResult[](msgIds.length);

        for (uint256 i = 0; i < msgIds.length; i++) {
            Utils.MessageStatus _status = atomicTeleportMessages[msgIds[i]].status;
            results[i] = MessageStatusResult({
                msgId: msgIds[i],
                status: AtomicStatus[_status]
            });
        }

        return results;
    }

    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
}

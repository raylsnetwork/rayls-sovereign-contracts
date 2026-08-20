// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import './../utils/RaylsReentrancyGuardV1.sol';
import '../../rayls-protocol-sdk/libraries/MessageLib.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';

/**
 * @title RaylsMessageExecutorV1
 * @notice Executes cross-chain messages delivered by the authorized message receiver.
 *
 * All access control (governance and protocol functions) is gated by
 * RaylsAccessManagerV1 via the `restricted` modifier.
 */
contract RaylsMessageExecutorV1 is Initializable, IRaylsMessageExecutor, RaylsReentrancyGuardV1, UUPSUpgradeable, RaylsAccessManaged {
    uint256 public chainId;

    /// @notice Mapping to uniquely identify executed messages (replay protection).
    mapping(bytes32 => bool) public executed;

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the contract.
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address authority_) public initializer {
        __UUPSUpgradeable_init();
        // Initialize reentrancy guard state directly to avoid nested `initializer` conflict
        // (RaylsReentrancyGuardV1.initialize() uses `initializer`, which reverts when called
        // from within another `initializer` in OZ v5).
        _send_entered_state = _NOT_ENTERED;
        _receive_entered_state = _NOT_ENTERED;
        chainId = block.chainid;
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function executeMessage(address to, bytes calldata data, bytes32 messageId, uint256 fromChainId, address from) external virtual override restricted receiveNonReentrant {
        bool _executedMessageId = executed[messageId];
        executed[messageId] = true;

        MessageLib.executeMessage(to, data, messageId, fromChainId, from, _executedMessageId);

        emit MessageIdExecuted(fromChainId, messageId);
    }

    function executeMessageBatch(MessageLib.Message[] calldata messages, bytes32 messageId, uint256 fromChainId, address from) external virtual override restricted receiveNonReentrant {
        bool _executedMessageId = executed[messageId];
        executed[messageId] = true;

        MessageLib.executeMessageBatch(messages, messageId, fromChainId, from, _executedMessageId);

        emit MessageIdExecuted(fromChainId, messageId);
    }

    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
}

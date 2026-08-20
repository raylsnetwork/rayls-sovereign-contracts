// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./rayls-protocol-sdk/libraries/Utils.sol";
import {RaylsAccessManaged} from "./privateHub/AccessControl/RaylsAccessManaged.sol";

/**
 * @title SignatureStorage
 * @dev This contract handles the function signatures per message id. Signature/s would be executed
 * in the relayer once message is marked as executed.
 */
contract SignatureStorage is RaylsAccessManaged {
    struct Signature {
        Utils.MessageStatus status; // denotes the msg status that is related with the signature
        bytes signature;
        bytes32 resourceId;
        uint256 signatureExecuteChainId; // the chain id where the signature should be executed
        uint256 destinationChainId; // the destination chain id when the transaction is formed
    }

    mapping(string => Signature) private signatures;

    constructor(address _authority) {
        if (_authority != address(0)) _setAuthority(_authority);
    }

    function addSignature(string memory signatureKey, Signature calldata sig) external restricted {
        signatures[signatureKey] = sig;
    }

    function deleteSignature(string memory signatureKey) external restricted {
        delete signatures[signatureKey];
    }

    function getSignature(string memory signatureKey) external view returns (Signature memory) {
        return signatures[signatureKey];
    }
}

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import '../../rayls-protocol/utils/RLPEncode.sol';
import {RaylsAccessManaged} from "../AccessControl/RaylsAccessManaged.sol";

/**
 * @title PNHeader
 * @dev Contract for storing privacy node headers and verifications across multiple networks.
 */
contract Proofs is RaylsAccessManaged {
    constructor(address authority_) {
        _setAuthority(authority_);
    }

    event IncorrectParentHashEvent(uint256 chainId, uint256 blockNumber, bytes32 parentHash, bytes32 calculatedParentHash);
    
    // Emits only essential header data
    event HeaderProofSubmitted(
        uint256 indexed chainId,
        uint256 indexed blockNumber,
        bytes32 headerHash
    );

    /// @dev Header layout REQUIRES post-Prague (EIP-7685) block headers.
    ///      All 21 fields MUST be populated by the relayer. Pre-London /
    ///      pre-Shanghai / pre-Cancun / pre-Prague chains are NOT supported —
    ///      their canonical headers contain fewer RLP fields, so the
    ///      keccak256 produced by `getBlockRlpData` would not match the actual
    ///      block hash and `verifyHeaderHash` would silently fail.
    struct Header {
        bytes32 parentHash;
        bytes32 uncleHash; // ommersHash
        address coinbase; // beneficiary
        bytes32 root;
        bytes32 txHash;
        bytes32 receiptHash;
        bytes bloom;
        uint256 difficulty;
        uint256 number;
        uint256 gasLimit;
        uint256 gasUsed;
        uint256 time;
        bytes extra;
        bytes32 mixDigest;
        uint64 nonce;
        uint256 baseFeePerGas;         // London   EIP-1559
        bytes32 withdrawalsRoot;       // Shanghai EIP-4895
        uint64  blobGasUsed;           // Cancun   EIP-4844
        uint64  excessBlobGas;         // Cancun   EIP-4844
        bytes32 parentBeaconBlockRoot; // Cancun   EIP-4788
        bytes32 requestsHash;          // Prague   EIP-7685
    }

    // Store the 2 most recent Header structs onchain (private to avoid auto-generated getters that cause stack too deep)
    mapping(uint256 => Header) private currentHeader;
    mapping(uint256 => Header) private previousHeader;

    function addBatchHeaders(uint256 chainId, Header[] memory newHeaders) public restricted {
        for(uint i = 0; i < newHeaders.length; i++) {
            if (i != 0) {
                if (newHeaders[i].number != newHeaders[i-1].number + 1) {
                    revert('Batch headers not in sequential order');
                }
            }
            if (!tryAddHeader(chainId, newHeaders[i])) {
                return;
            }
        }
    }

    struct StorageProofBatch {
        string batchId;
        string messageTag;
        bytes data;
    }

    event EncryptedStorageProofsBatchReceived(string print, bytes data, uint256 indexed blockNumber);

    function tryAddHeader(uint256 chainId, Header memory header) public restricted returns (bool) {
        Header memory current = currentHeader[chainId];
        
        // Check sequential order
        require(header.number == current.number + 1 || current.number == 0,
            'Trying to insert a non-sequential block header'
        );

        // Verify parent hash if not genesis AND previous header exists
        if (header.number > 0 && current.number > 0) {
            bytes32 calculatedParentHash = calculateHeaderHash(current);

            if (calculatedParentHash != header.parentHash) {
                emit IncorrectParentHashEvent(chainId, header.number, header.parentHash, calculatedParentHash);
                return false;
            }
        }

        // Shift current to previous
        previousHeader[chainId] = currentHeader[chainId];
        
        // Store new current
        currentHeader[chainId] = header;
        
        // Emit only chainId, blockNumber, and headerHash
        emit HeaderProofSubmitted(
            chainId,
            header.number,
            calculateHeaderHash(header)
        );
        
        return true;
    }
    
    function getNextHeaderBlockNumber(uint256 chainId) public view returns (uint256) {
        // Return the next expected block number based on current header
        return currentHeader[chainId].number + 1;
    }

    function storeEncryptedStorageProofs(StorageProofBatch calldata batch, uint256 blockNumber) public virtual restricted {
        emit EncryptedStorageProofsBatchReceived(batch.messageTag, batch.data, blockNumber);
    }

    function calculateHeaderHash(Header memory header) public pure returns(bytes32) {
        return keccak256(getBlockRlpData(header));
    }

    function getCurrentHeader(uint256 chainId) public view returns (Header memory) {
        return currentHeader[chainId];
    }
    
    function getPreviousHeader(uint256 chainId) public view returns (Header memory) {
        return previousHeader[chainId];
    }

    function verifyHeaderHash(uint256 chainId, uint256 blockNumber, bytes32 blockHash) public view returns (bool) {
        Header memory current = currentHeader[chainId];
        Header memory previous = previousHeader[chainId];
        
        if (current.number == blockNumber) {
            return calculateHeaderHash(current) == blockHash;
        }
        if (previous.number == blockNumber) {
            return calculateHeaderHash(previous) == blockHash;
        }
        return false;
    }
    
    function uint2str(uint256 _i) internal pure returns (string memory _uintAsString) {
        if (_i == 0) {
            return '0';
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }

    function bytes32ToLiteralString(bytes32 data) public pure returns (string memory result) {
        bytes memory temp = new bytes(65);
        uint256 count;

        for (uint256 i = 0; i < 32; i++) {
            bytes1 currentByte = bytes1(data << (i * 8));

            uint8 c1 = uint8(bytes1((currentByte << 4) >> 4));

            uint8 c2 = uint8(bytes1((currentByte >> 4)));

            if (c2 >= 0 && c2 <= 9) temp[++count] = bytes1(c2 + 48);
            else temp[++count] = bytes1(c2 + 87);

            if (c1 >= 0 && c1 <= 9) temp[++count] = bytes1(c1 + 48);
            else temp[++count] = bytes1(c1 + 87);
        }

        result = string(temp);
    }

    function stringToBytes32(string memory source) public pure returns (bytes32 result) {
        bytes memory tempEmptyStringTest = bytes(source);
        if (tempEmptyStringTest.length == 0) {
            return 0x0;
        }

        assembly {
            result := mload(add(source, 32))
        }
    }

    /// @dev Emits a fixed 21-field RLP list matching post-Prague (EIP-7685)
    ///      canonical headers. Any pre-Prague chain feeding this contract will
    ///      produce a header hash that does NOT match its on-chain block hash.
    ///      See the `Header` struct for the full supported-chain contract.
    function getBlockRlpData(Header memory header) internal pure returns (bytes memory data) {
        bytes[] memory list = new bytes[](21);

        list[0]  = RLPEncode.encodeBytes(abi.encodePacked(header.parentHash));
        list[1]  = RLPEncode.encodeBytes(abi.encodePacked(header.uncleHash));
        list[2]  = RLPEncode.encodeAddress(header.coinbase);
        list[3]  = RLPEncode.encodeBytes(abi.encodePacked(header.root));
        list[4]  = RLPEncode.encodeBytes(abi.encodePacked(header.txHash));
        list[5]  = RLPEncode.encodeBytes(abi.encodePacked(header.receiptHash));
        list[6]  = RLPEncode.encodeBytes(header.bloom);
        list[7]  = RLPEncode.encodeUint(header.difficulty);
        list[8]  = RLPEncode.encodeUint(header.number);
        list[9]  = RLPEncode.encodeUint(header.gasLimit);
        list[10] = RLPEncode.encodeUint(header.gasUsed);
        list[11] = RLPEncode.encodeUint(header.time);
        list[12] = RLPEncode.encodeBytes(header.extra);
        list[13] = RLPEncode.encodeBytes(abi.encodePacked(header.mixDigest));
        list[14] = RLPEncode.encodeBytes(abi.encodePacked(header.nonce));
        list[15] = RLPEncode.encodeUint(header.baseFeePerGas);
        list[16] = RLPEncode.encodeBytes(abi.encodePacked(header.withdrawalsRoot));
        list[17] = RLPEncode.encodeUint(header.blobGasUsed);
        list[18] = RLPEncode.encodeUint(header.excessBlobGas);
        list[19] = RLPEncode.encodeBytes(abi.encodePacked(header.parentBeaconBlockRoot));
        list[20] = RLPEncode.encodeBytes(abi.encodePacked(header.requestsHash));

        data = RLPEncode.encodeList(list);
    }
}

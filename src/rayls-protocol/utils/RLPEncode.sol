// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/**
 * @title RLPEncode
 * @notice Minimal RLP (Recursive Length Prefix) encoder implementing the encoding
 *         rules defined in the Ethereum Yellow Paper (Appendix B). This is an
 *         independent implementation written against that public specification; it
 *         shares no code with any third-party RLP library.
 * @dev Item encoding:
 *      - a single byte in [0x00, 0x7f] encodes to itself;
 *      - a byte string of length L <= 55 encodes to (0x80 + L) followed by the string;
 *      - a longer byte string encodes to (0xb7 + len(L)), then L big-endian, then the string;
 *      - lists use the same rules with the 0xc0 / 0xf7 offsets over the concatenated items.
 *      Integers are encoded as their minimal big-endian byte representation (0 -> empty
 *      string -> 0x80), matching canonical Ethereum RLP.
 */
library RLPEncode {
    /// @dev RLP-encodes a byte string.
    function encodeBytes(bytes memory self) internal pure returns (bytes memory) {
        if (self.length == 1 && uint8(self[0]) < 0x80) {
            return self;
        }
        return bytes.concat(_encodeLength(self.length, 0x80), self);
    }

    /// @dev RLP-encodes a list of already-RLP-encoded items.
    function encodeList(bytes[] memory self) internal pure returns (bytes memory) {
        bytes memory payload = _flatten(self);
        return bytes.concat(_encodeLength(payload.length, 0xc0), payload);
    }

    /// @dev RLP-encodes a string.
    function encodeString(string memory self) internal pure returns (bytes memory) {
        return encodeBytes(bytes(self));
    }

    /// @dev RLP-encodes an address as its 20-byte big-endian representation.
    function encodeAddress(address self) internal pure returns (bytes memory) {
        return encodeBytes(abi.encodePacked(self));
    }

    /// @dev RLP-encodes an unsigned integer (minimal big-endian; 0 encodes to 0x80).
    function encodeUint(uint256 self) internal pure returns (bytes memory) {
        return encodeBytes(_toBinary(self));
    }

    /// @dev RLP-encodes a signed integer via its two's-complement uint256 value.
    function encodeInt(int256 self) internal pure returns (bytes memory) {
        return encodeUint(uint256(self));
    }

    /// @dev RLP-encodes a boolean (true -> 0x01, false -> 0x80).
    function encodeBool(bool self) internal pure returns (bytes memory) {
        bytes memory encoded = new bytes(1);
        encoded[0] = self ? bytes1(0x01) : bytes1(0x80);
        return encoded;
    }

    /**
     * @dev Encodes the length prefix for a string (offset 0x80) or list (offset 0xc0).
     *      For payloads <= 55 bytes the prefix is a single byte (offset + length);
     *      otherwise it is (offset + 55 + len(L)) followed by L in minimal big-endian form.
     */
    function _encodeLength(uint256 len, uint256 offset) private pure returns (bytes memory) {
        if (len < 56) {
            bytes memory short = new bytes(1);
            short[0] = bytes1(uint8(len + offset));
            return short;
        }
        bytes memory lenBytes = _toBinary(len);
        bytes memory encoded = new bytes(1 + lenBytes.length);
        encoded[0] = bytes1(uint8(lenBytes.length + offset + 55));
        for (uint256 i = 0; i < lenBytes.length; i++) {
            encoded[i + 1] = lenBytes[i];
        }
        return encoded;
    }

    /// @dev Minimal big-endian byte representation of `x` with no leading zeros (0 -> empty).
    function _toBinary(uint256 x) private pure returns (bytes memory) {
        if (x == 0) {
            return new bytes(0);
        }
        uint256 length = 0;
        for (uint256 t = x; t != 0; t >>= 8) {
            length++;
        }
        bytes memory out = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            out[length - 1 - i] = bytes1(uint8(x >> (8 * i)));
        }
        return out;
    }

    /// @dev Concatenates a list of byte strings into one.
    function _flatten(bytes[] memory list) private pure returns (bytes memory) {
        bytes memory out = "";
        for (uint256 i = 0; i < list.length; i++) {
            out = bytes.concat(out, list[i]);
        }
        return out;
    }
}

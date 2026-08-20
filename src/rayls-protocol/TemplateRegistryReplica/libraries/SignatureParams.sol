// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title SignatureParams
 * @notice Counts the top-level parameters of a canonical Solidity function signature.
 * @dev Used by the programmability gate to locate the trailing `originSender` head word in a
 *      caller-supplied `args` blob. The count is the number of comma-separated arguments inside
 *      the outermost parentheses, with commas nested inside tuple parens `(...)` ignored. Each
 *      ABI parameter — static or dynamic — occupies exactly ONE head word, so the parameter
 *      count alone fixes the byte offset of every head slot: param `k` lives at `k * 32`.
 *
 *      Examples:
 *        "crossMint(address,uint256,address)"               -> 3
 *        "crossBurn(uint256,address)"                        -> 2
 *        "crossMint(address,uint256,uint256,bytes,address)"  -> 5  (bytes is one head word)
 *        "f()"                                               -> 0
 *        "f((uint256,uint256),address)"                      -> 2  (tuple counts once)
 */
library SignatureParams {
    /// @notice Thrown when the signature is not a well-formed `name(args)` shape.
    error SignatureParams__Malformed();

    /**
     * @notice Count top-level parameters in `signature`.
     * @param signature Canonical signature, e.g. `"crossMint(address,uint256,address)"`.
     * @return count Number of top-level (comma-separated, tuple-aware) parameters.
     */
    function paramCount(string memory signature) internal pure returns (uint256 count) {
        bytes memory s = bytes(signature);
        uint256 len = s.length;

        // Locate the outermost '(' — everything before it is the function name.
        uint256 open = type(uint256).max;
        for (uint256 i = 0; i < len; i++) {
            if (s[i] == '(') {
                open = i;
                break;
            }
        }
        if (open == type(uint256).max || s[len - 1] != ')') revert SignatureParams__Malformed();

        // Empty parameter list: "name()".
        if (open + 1 == len - 1) return 0;

        // Walk the parameter region [open+1, len-1), counting depth-1 commas. A tuple `(...)`
        // raises depth so its inner commas don't count as top-level parameters.
        uint256 depth = 0;
        uint256 commas = 0;
        for (uint256 i = open + 1; i < len - 1; i++) {
            bytes1 c = s[i];
            if (c == '(') {
                depth++;
            } else if (c == ')') {
                if (depth == 0) revert SignatureParams__Malformed();
                depth--;
            } else if (c == ',' && depth == 0) {
                commas++;
            }
        }
        if (depth != 0) revert SignatureParams__Malformed();

        // n top-level commas separate n+1 parameters.
        return commas + 1;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SignatureParams} from "../../../rayls-protocol/TemplateRegistryReplica/libraries/SignatureParams.sol";

contract SignatureParamsTest is Test {
    using SignatureParams for string;

    function test_threeStaticParams() public pure {
        assertEq(SignatureParams.paramCount("crossMint(address,uint256,address)"), 3);
    }

    function test_twoParams() public pure {
        assertEq(SignatureParams.paramCount("crossBurn(uint256,address)"), 2);
    }

    function test_dynamicParamCountsAsOne() public pure {
        // `bytes` is one head word, so 5 params total.
        assertEq(SignatureParams.paramCount("crossMint(address,uint256,uint256,bytes,address)"), 5);
    }

    function test_singleParam() public pure {
        assertEq(SignatureParams.paramCount("f(address)"), 1);
    }

    function test_emptyParamList() public pure {
        assertEq(SignatureParams.paramCount("ping()"), 0);
    }

    function test_tupleCountsAsOneTopLevel() public pure {
        // The inner tuple commas must not inflate the top-level count.
        assertEq(SignatureParams.paramCount("f((uint256,uint256),address)"), 2);
        assertEq(SignatureParams.paramCount("f(address,(uint256,bytes,address))"), 2);
    }

    function test_nestedTuples() public pure {
        assertEq(SignatureParams.paramCount("f(((uint256,uint256),bool),address)"), 2);
    }

    function test_arrayParam() public pure {
        assertEq(SignatureParams.paramCount("f(uint256[],address)"), 2);
    }

    function test_malformed_noParens_reverts() public {
        vm.expectRevert(SignatureParams.SignatureParams__Malformed.selector);
        this.callParamCount("notASignature");
    }

    function test_malformed_unbalanced_reverts() public {
        vm.expectRevert(SignatureParams.SignatureParams__Malformed.selector);
        this.callParamCount("f((uint256,address)");
    }

    /// @dev External wrapper so `vm.expectRevert` catches the library revert.
    function callParamCount(string calldata sig) external pure returns (uint256) {
        return SignatureParams.paramCount(sig);
    }
}

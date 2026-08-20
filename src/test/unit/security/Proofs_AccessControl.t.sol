// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../privateHub/Proofs/Proofs.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

/// @dev Allowlist-based mock authority for Proofs tests.
contract MockAuthority_Proofs {
    mapping(address => bool) private _allowed;

    function allow(address who) external { _allowed[who] = true; }
    function deny(address who) external { _allowed[who] = false; }

    function canCall(address caller, address, bytes4) external view returns (bool, uint32, bool) {
        return (_allowed[caller], 0, false);
    }
}

contract ProofsAccessControlTest is Test {
    Proofs proofs;
    MockAuthority_Proofs auth;
    address owner = address(0xA);
    address attacker = address(0xBAD);

    function setUp() public {
        auth = new MockAuthority_Proofs();
        auth.allow(owner);

        vm.prank(owner);
        proofs = new Proofs(address(auth));
    }

    function _makeHeader(uint256 blockNum) internal pure returns (Proofs.Header memory) {
        return Proofs.Header({
            parentHash: bytes32(0),
            uncleHash: bytes32(0),
            coinbase: address(0),
            root: bytes32(0),
            txHash: bytes32(0),
            receiptHash: bytes32(0),
            bloom: "",
            difficulty: 0,
            number: blockNum,
            gasLimit: 0,
            gasUsed: 0,
            time: 0,
            extra: "",
            mixDigest: bytes32(0),
            nonce: 0,
            baseFeePerGas: 0,
            withdrawalsRoot: bytes32(0),
            blobGasUsed: 0,
            excessBlobGas: 0,
            parentBeaconBlockRoot: bytes32(0),
            requestsHash: bytes32(0)
        });
    }

    /* ── tryAddHeader ──────────────────────────────────── */

    function test_tryAddHeader_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        proofs.tryAddHeader(1, _makeHeader(1));
    }

    function test_tryAddHeader_ownerSucceeds() public {
        vm.prank(owner);
        bool ok = proofs.tryAddHeader(1, _makeHeader(1));
        assertTrue(ok);
    }

    /* ── addBatchHeaders ───────────────────────────────── */

    function test_addBatchHeaders_attackerReverts() public {
        Proofs.Header[] memory headers = new Proofs.Header[](1);
        headers[0] = _makeHeader(1);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        proofs.addBatchHeaders(1, headers);
    }

    /* ── storeEncryptedStorageProofs ───────────────────── */

    function test_storeEncryptedStorageProofs_attackerReverts() public {
        Proofs.StorageProofBatch memory batch = Proofs.StorageProofBatch({
            batchId: "b1",
            messageTag: "fp1",
            data: ""
        });

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        proofs.storeEncryptedStorageProofs(batch, 1);
    }

    function test_storeEncryptedStorageProofs_ownerSucceeds() public {
        Proofs.StorageProofBatch memory batch = Proofs.StorageProofBatch({
            batchId: "b1",
            messageTag: "fp1",
            data: ""
        });

        vm.prank(owner);
        proofs.storeEncryptedStorageProofs(batch, 1);
    }
}

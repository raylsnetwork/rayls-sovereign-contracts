// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../SignatureStorage.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";

contract SignatureStorageAccessControlTest is Test {
    SignatureStorage sig;
    RaylsAccessManagerV1 manager;
    address owner;
    address attacker = address(0xBAD);

    function setUp() public {
        owner = address(this);

        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(
            address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (owner))
        )));

        sig = new SignatureStorage(address(manager));
    }

    /* ── addSignature ──────────────────────────────────── */

    function test_addSignature_attackerReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        sig.addSignature("key1", SignatureStorage.Signature(Utils.MessageStatus.Pending, "", bytes32(0), 0, 0));
    }

    function test_addSignature_ownerSucceeds() public {
        sig.addSignature("key1", SignatureStorage.Signature(Utils.MessageStatus.Pending, "", bytes32(0), 0, 0));
        SignatureStorage.Signature memory s = sig.getSignature("key1");
        assertEq(uint(s.status), uint(Utils.MessageStatus.Pending));
    }

    /* ── deleteSignature ───────────────────────────────── */

    function test_deleteSignature_attackerReverts() public {
        sig.addSignature("key1", SignatureStorage.Signature(Utils.MessageStatus.Pending, "", bytes32(0), 0, 0));

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker));
        sig.deleteSignature("key1");
    }

    function test_deleteSignature_ownerSucceeds() public {
        sig.addSignature("key1", SignatureStorage.Signature(Utils.MessageStatus.Pending, "", bytes32(0), 0, 0));
        sig.deleteSignature("key1");
        SignatureStorage.Signature memory s = sig.getSignature("key1");
        assertEq(uint(s.status), 0);
    }
}

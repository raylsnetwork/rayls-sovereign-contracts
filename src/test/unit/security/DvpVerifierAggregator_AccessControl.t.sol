// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {DvpVerifierAggregator} from "../../../rayls-protocol/Enygma/Enygma-DVP/DvpVerifierAggregator.sol";
import {IDvp} from "../../../rayls-protocol/interfaces/IDvp.sol";

/**
 * @title Security Test: DvpVerifierAggregator Access Control
 * @notice Tests that initializeVerifier is protected by restricted modifier.
 *
 * VULNERABILITY (before fix):
 * - Anyone could call initializeVerifier and replace verifier addresses
 * - Attacker could redirect to malicious verifiers that accept fake proofs
 *
 * EXPECTED BEHAVIOR (after fix):
 * - Only authorized role can call initializeVerifier
 * - Attackers get reverted with RaylsAccessManaged__Unauthorized
 */
contract DvpVerifierAggregatorAccessControlTest is Test {
    RaylsAccessManagerV1 public manager;
    DvpVerifierAggregator public aggregator;

    uint64 public AGGREGATOR_ADMIN_ID;

    address public admin;
    address public attacker;

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin = address(this);
        attacker = makeAddr("attacker");

        // Deploy manager via UUPS proxy
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        manager = RaylsAccessManagerV1(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(RaylsAccessManagerV1.initialize, (admin))))
        );

        // Deploy aggregator with manager as authority
        aggregator = new DvpVerifierAggregator(address(manager));

        // Register and grant role
        AGGREGATOR_ADMIN_ID = manager.registerRole("AGGREGATOR_ADMIN");
        manager.grantRole(AGGREGATOR_ADMIN_ID, admin, 0);

        // Allow role to call initializeVerifier
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = aggregator.initializeVerifier.selector;
        manager.addFunctionAllowedRoles(address(aggregator), selectors, _singleRole(AGGREGATOR_ADMIN_ID));
    }

    // --- Negative: attacker cannot call initializeVerifier ---

    function test_initializeVerifier_attackerReverts() public {
        IDvp.VerifierAddresses memory addrs = IDvp.VerifierAddresses({
            enygmaJoinSplit: makeAddr("js"),
            erc721Ownership: makeAddr("721"),
            erc1155JoinSplit: makeAddr("1155")
        });
        vm.prank(attacker);
        vm.expectRevert();
        aggregator.initializeVerifier(addrs);
    }

    // --- Positive: admin can call initializeVerifier ---

    function test_initializeVerifier_adminSucceeds() public {
        IDvp.VerifierAddresses memory addrs = IDvp.VerifierAddresses({
            enygmaJoinSplit: makeAddr("js"),
            erc721Ownership: makeAddr("721"),
            erc1155JoinSplit: makeAddr("1155")
        });
        aggregator.initializeVerifier(addrs);
    }

    // --- Authority is set correctly ---

    function test_authorityIsSetCorrectly() public view {
        assertEq(aggregator.authority(), address(manager));
    }
}

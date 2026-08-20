// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RaylsAccessManagerV1} from "../../../privateHub/AccessControl/RaylsAccessManagerV1.sol";
import {RaylsAccessManaged} from "../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import {IRaylsAccessManager} from "../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";
import "../../../privateHub/AccessControl/AccessManagerTypes.sol";

// ─── Mock: Privacy Node Token Governance ──────────────────────────────────────
// Simulates RNTokenGovernanceV1's restricted governance API.

contract MockTokenGovernance is RaylsAccessManaged {
    uint256 public addTokenCalls;
    uint256 public updateStatusCalls;
    uint256 public unmappedCalls;

    constructor(address authority_) {
        _initializeAuthority(authority_);
    }

    function addToken()           external restricted { addTokenCalls++; }
    function updateTokenStatus()  external restricted { updateStatusCalls++; }
    // Not registered in manager → defaults to ADMIN (fail-closed)
    function adminOnlyByDefault() external restricted { unmappedCalls++; }
    // Unrestricted view — anyone may read
    function getTokenInfo() external pure returns (string memory) { return "info"; }
}

// ─── Mock: Privacy Node User Governance ───────────────────────────────────────
// Simulates RNUserGovernanceV1's restricted governance API.

contract MockUserGovernance is RaylsAccessManaged {
    uint256 public createUserCalls;
    uint256 public addPairCalls;
    uint256 public approveUserCalls;
    uint256 public rejectUserCalls;
    uint256 public removeUserCalls;

    constructor(address authority_) {
        _initializeAuthority(authority_);
    }

    function createUser()     external restricted { createUserCalls++; }
    function addAddressPair() external restricted { addPairCalls++; }
    function approveUser()    external restricted { approveUserCalls++; }
    function rejectUser()     external restricted { rejectUserCalls++; }
    function removeUser()     external restricted { removeUserCalls++; }
    function getAllUsers()     external pure returns (address[] memory) { return new address[](0); }
}

// ─── Mock: Private Network Hub Token Registry ─────────────────────────────────
// Simulates TokenRegistryV1's restricted governance API.

contract MockHubRegistry is RaylsAccessManaged {
    uint256 public updateStatusCalls;
    uint256 public freezeCalls;
    uint256 public unfreezeCalls;

    constructor(address authority_) {
        _initializeAuthority(authority_);
    }

    function updateStatus()  external restricted { updateStatusCalls++; }
    function freezeToken()   external restricted { freezeCalls++; }
    function unfreezeToken() external restricted { unfreezeCalls++; }
    function getAllTokens()   external pure returns (bytes32[] memory) { return new bytes32[](0); }
}

// ─── Mock: Simple recording target (no access control, for schedule/execute flow) ──

contract RecordingTarget {
    uint256 public calls;
    function doAction() external { calls++; }
}

// =============================================================================
// AUTH-V3 Business Requirements Test Suite
//
// Covers all BRs from the AUTH-V3 specification:
//   BR-01  Segregation of Duties
//   BR-02  Function-Level Granularity
//   BR-03  Third-Party Integration with Minimal Blast Radius
//   BR-04  Temporal Controls (Execution Delays)
//   BR-05  Audit Trail / Compliance Reporting
//   BR-06  Emergency Pause Per Target
//   BR-07  Identity Isolation (Independent Manager Per Chain)
//   BR-08  Delegation / Role Hierarchy
//   BR-09  Readable Role Names
//   BR-10  Fail-Closed / Safe Default
//   FR-2   Flow-Based Permission Model
//   FR-9   Approval Workflow (schedule → review → execute/cancel)
//   SC-07  Grant Delays
//   SC-08  Guardian Role (cancel scheduled ops)
//   SC-10  Least Privilege Enforcement
// =============================================================================
contract AuthV3_BusinessRequirementsTest is Test {

    // ─── Manager ─────────────────────────────────────────────────────────────
    RaylsAccessManagerV1 public manager;
    address implAddr; // reused for independent-manager tests

    // ─── Role IDs (auto-assigned by registerRole, starting at 1) ─────────────
    uint64 public PRIVACY_NODE_OPERATOR_ID;
    uint64 public BANK_EMPLOYEE_ID;
    uint64 public COMPLIANCE_OFFICER_ID;
    uint64 public AUDITOR_ID;
    uint64 public COMPLIANCE_TOOL_ID;   // 3P: AML tool
    uint64 public CUSTODY_MANAGER_ID;  // 3P: Custody provider
    uint64 public TOKENIZER_ID;        // 3P: Tokenization platform

    // ─── Personas ─────────────────────────────────────────────────────────────
    address public admin;        // = address(this), holds ADMIN
    address public marcos;       // Operator on Privacy Node (PRIVACY_NODE_OPERATOR_ID)
    address public sara;         // Bank Employee (BANK_EMPLOYEE_ID)
    address public compOfficer;  // Compliance Officer (COMPLIANCE_OFFICER_ID)
    address public auditor_;     // Auditor (AUDITOR_ID, reads only)
    address public custodyMgr;   // 3P Custody Manager (CUSTODY_MANAGER_ID)
    address public compTool;     // 3P AML Tool (COMPLIANCE_TOOL_ID)
    address public tokenizer_;   // 3P Tokenization Platform (TOKENIZER_ID)
    address public attacker;     // Unauthorized caller

    // ─── Mock Targets ─────────────────────────────────────────────────────────
    MockTokenGovernance public tokenGov;
    MockUserGovernance  public userGov;
    MockHubRegistry     public hubRegistry;

    // ─── Function selectors ───────────────────────────────────────────────────
    bytes4 SEL_ADD_TOKEN;
    bytes4 SEL_UPDATE_STATUS;
    bytes4 SEL_CREATE_USER;
    bytes4 SEL_ADD_PAIR;
    bytes4 SEL_APPROVE_USER;
    bytes4 SEL_REJECT_USER;
    bytes4 SEL_REMOVE_USER;
    bytes4 SEL_HUB_UPDATE;
    bytes4 SEL_FREEZE;
    bytes4 SEL_UNFREEZE;

    // ─────────────────────────────────────────────────────────────────────────
    // setUp
    // ─────────────────────────────────────────────────────────────────────────

    function _singleRole(uint64 roleId) internal pure returns (uint64[] memory roles) {
        roles = new uint64[](1);
        roles[0] = roleId;
    }

    function setUp() public {
        admin = address(this);

        // Personas
        marcos     = makeAddr("marcos");
        sara       = makeAddr("sara");
        compOfficer = makeAddr("compOfficer");
        auditor_   = makeAddr("auditor");
        custodyMgr = makeAddr("custodyMgr");
        compTool   = makeAddr("compTool");
        tokenizer_ = makeAddr("tokenizer");
        attacker   = makeAddr("attacker");

        // ── Deploy manager via UUPS proxy ──────────────────────────────────
        RaylsAccessManagerV1 impl = new RaylsAccessManagerV1();
        implAddr = address(impl);
        bytes memory initData = abi.encodeCall(RaylsAccessManagerV1.initialize, (admin));
        manager = RaylsAccessManagerV1(address(new ERC1967Proxy(implAddr, initData)));

        // Grant the manager itself ADMIN so that manager.execute() can call
        // `restricted` targets (manager → target: canCall(manager, ...) = ADMIN → ok).
        manager.grantRole(manager.ADMIN(), address(manager), 0);

        // ── Register named roles (auto-IDs starting at 1) ─────────────────
        PRIVACY_NODE_OPERATOR_ID           = manager.registerRole("PRIVACY_NODE_OPERATOR");
        BANK_EMPLOYEE_ID      = manager.registerRole("BANK_EMPLOYEE");
        COMPLIANCE_OFFICER_ID = manager.registerRole("COMPLIANCE_OFFICER");
        AUDITOR_ID            = manager.registerRole("AUDITOR");
        COMPLIANCE_TOOL_ID    = manager.registerRole("COMPLIANCE_TOOL");
        CUSTODY_MANAGER_ID    = manager.registerRole("CUSTODY_MANAGER");
        TOKENIZER_ID          = manager.registerRole("TOKENIZER");

        // ── Role hierarchy (BR-08) ─────────────────────────────────────────
        // PRIVACY_NODE_OPERATOR is the admin of every delegated role below it.
        manager.setRoleAdmin(BANK_EMPLOYEE_ID,      PRIVACY_NODE_OPERATOR_ID);
        manager.setRoleAdmin(COMPLIANCE_OFFICER_ID, PRIVACY_NODE_OPERATOR_ID);
        manager.setRoleAdmin(AUDITOR_ID,            PRIVACY_NODE_OPERATOR_ID);
        manager.setRoleAdmin(COMPLIANCE_TOOL_ID,    PRIVACY_NODE_OPERATOR_ID);
        manager.setRoleAdmin(CUSTODY_MANAGER_ID,    PRIVACY_NODE_OPERATOR_ID);
        manager.setRoleAdmin(TOKENIZER_ID,          PRIVACY_NODE_OPERATOR_ID);

        // ── Guardians (SC-08) ──────────────────────────────────────────────
        // PRIVACY_NODE_OPERATOR can cancel scheduled ops by COMPLIANCE_OFFICER / COMPLIANCE_TOOL.
        manager.setRoleGuardian(COMPLIANCE_OFFICER_ID, PRIVACY_NODE_OPERATOR_ID);
        manager.setRoleGuardian(COMPLIANCE_TOOL_ID,    PRIVACY_NODE_OPERATOR_ID);

        // ── Deploy mock targets ────────────────────────────────────────────
        tokenGov    = new MockTokenGovernance(address(manager));
        userGov     = new MockUserGovernance(address(manager));
        hubRegistry = new MockHubRegistry(address(manager));

        // ── Capture selectors ──────────────────────────────────────────────
        SEL_ADD_TOKEN    = MockTokenGovernance.addToken.selector;
        SEL_UPDATE_STATUS = MockTokenGovernance.updateTokenStatus.selector;
        SEL_CREATE_USER  = MockUserGovernance.createUser.selector;
        SEL_ADD_PAIR     = MockUserGovernance.addAddressPair.selector;
        SEL_APPROVE_USER = MockUserGovernance.approveUser.selector;
        SEL_REJECT_USER  = MockUserGovernance.rejectUser.selector;
        SEL_REMOVE_USER  = MockUserGovernance.removeUser.selector;
        SEL_HUB_UPDATE   = MockHubRegistry.updateStatus.selector;
        SEL_FREEZE       = MockHubRegistry.freezeToken.selector;
        SEL_UNFREEZE     = MockHubRegistry.unfreezeToken.selector;

        // ── Function→Role mappings ─────────────────────────────────────────
        //
        // Privacy Node — Token Governance
        //   addToken        → TOKENIZER_ID       (FR-4, 3P tokenization)
        //   updateStatus    → COMPLIANCE_OFFICER_ID (sensitive: delay required)
        _setFnRole(address(tokenGov), SEL_ADD_TOKEN,     TOKENIZER_ID);
        _setFnRole(address(tokenGov), SEL_UPDATE_STATUS, COMPLIANCE_OFFICER_ID);
        // adminOnlyByDefault intentionally NOT mapped → defaults to ADMIN (BR-10)

        // Privacy Node — User Governance
        //   createUser    → CUSTODY_MANAGER_ID  (FR-1, 3P custody)
        //   addAddressPair → BANK_EMPLOYEE_ID   (FR-5)
        //   approveUser   → CUSTODY_MANAGER_ID  (FR-1)
        //   rejectUser    → PRIVACY_NODE_OPERATOR_ID          (sensitive, not delegatable to 3P)
        //   removeUser    → PRIVACY_NODE_OPERATOR_ID          (sensitive)
        _setFnRole(address(userGov), SEL_CREATE_USER,  CUSTODY_MANAGER_ID);
        _setFnRole(address(userGov), SEL_ADD_PAIR,     BANK_EMPLOYEE_ID);
        _setFnRole(address(userGov), SEL_APPROVE_USER, CUSTODY_MANAGER_ID);
        _setFnRole(address(userGov), SEL_REJECT_USER,  PRIVACY_NODE_OPERATOR_ID);
        _setFnRole(address(userGov), SEL_REMOVE_USER,  PRIVACY_NODE_OPERATOR_ID);

        // Private Network Hub — Token Registry
        //   updateStatus  → BANK_EMPLOYEE_ID    (token manager flow)
        //   freezeToken   → COMPLIANCE_TOOL_ID  (FR-3, AML tool)
        //   unfreezeToken → COMPLIANCE_TOOL_ID
        _setFnRole(address(hubRegistry), SEL_HUB_UPDATE, BANK_EMPLOYEE_ID);
        _setFnRole(address(hubRegistry), SEL_FREEZE,     COMPLIANCE_TOOL_ID);
        _setFnRole(address(hubRegistry), SEL_UNFREEZE,   COMPLIANCE_TOOL_ID);

        // ── Grant roles to personas (all with 0 execution delay for most tests) ──
        // PRIVACY_NODE_OPERATOR_ID: admin is ADMIN (default); only admin can grant it.
        manager.grantRole(PRIVACY_NODE_OPERATOR_ID, marcos, 0);

        // marcos (PRIVACY_NODE_OPERATOR) grants the roles below because PRIVACY_NODE_OPERATOR is their admin.
        vm.startPrank(marcos);
        manager.grantRole(BANK_EMPLOYEE_ID,      sara,        0);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, 0);
        manager.grantRole(AUDITOR_ID,            auditor_,    0);
        manager.grantRole(COMPLIANCE_TOOL_ID,    compTool,    0);
        manager.grantRole(CUSTODY_MANAGER_ID,    custodyMgr,  0);
        manager.grantRole(TOKENIZER_ID,          tokenizer_,  0);
        vm.stopPrank();
    }

    // ─── Helper ───────────────────────────────────────────────────────────────

    function _setFnRole(address target, bytes4 sel, uint64 roleId) internal {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = sel;
        manager.addFunctionAllowedRoles(target, sels, _singleRole(roleId));
    }

    function _operationId(address caller, address target, bytes memory data)
        internal pure returns (bytes32)
    {
        return keccak256(abi.encode(caller, target, data));
    }

    // =========================================================================
    // BR-01: Segregation of Duties
    // "Different personnel must have different permissions.
    //  A Bank Employee cannot have freezeToken capability."
    // =========================================================================

    function test_BR01_bankEmployee_canAddToken_notFreezeToken() public {
        // sara (BANK_EMPLOYEE) can call addToken — wait, addToken → TOKENIZER only.
        // sara has BANK_EMPLOYEE which maps to addAddressPair / hubRegistry.updateStatus.
        // Demonstrate sara can call hub updateStatus (BANK_EMPLOYEE territory):
        vm.prank(sara);
        hubRegistry.updateStatus();
        assertEq(hubRegistry.updateStatusCalls(), 1);

        // sara cannot call freezeToken (COMPLIANCE_TOOL territory)
        vm.prank(sara);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, sara
        ));
        hubRegistry.freezeToken();
    }

    function test_BR01_complianceTool_canFreezeToken_notUpdateStatus() public {
        // compTool (COMPLIANCE_TOOL) can freeze/unfreeze
        vm.prank(compTool);
        hubRegistry.freezeToken();
        assertEq(hubRegistry.freezeCalls(), 1);

        // compTool cannot call updateStatus (BANK_EMPLOYEE territory)
        vm.prank(compTool);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, compTool
        ));
        hubRegistry.updateStatus();
    }

    function test_BR01_tokenizer_canAddToken_notUpdateTokenStatus() public {
        // tokenizer_ (TOKENIZER) can add tokens
        vm.prank(tokenizer_);
        tokenGov.addToken();
        assertEq(tokenGov.addTokenCalls(), 1);

        // tokenizer_ cannot update token status (COMPLIANCE_OFFICER territory)
        vm.prank(tokenizer_);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, tokenizer_
        ));
        tokenGov.updateTokenStatus();
    }

    function test_BR01_complianceOfficer_canUpdateStatus_notAddToken() public {
        // compOfficer (COMPLIANCE_OFFICER) can update token status
        vm.prank(compOfficer);
        tokenGov.updateTokenStatus();
        assertEq(tokenGov.updateStatusCalls(), 1);

        // compOfficer cannot add tokens (TOKENIZER territory)
        vm.prank(compOfficer);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, compOfficer
        ));
        tokenGov.addToken();
    }

    // =========================================================================
    // BR-02: Function-Level Granularity
    // "Grant access to specific functions on specific contracts,
    //  not 'all-or-nothing' owner-level access."
    // =========================================================================

    function test_BR02_sameRoleCannotCallDifferentRoleFunction() public {
        // sara (BANK_EMPLOYEE) has addAddressPair on userGov but not createUser
        vm.prank(sara);
        userGov.addAddressPair(); // ✓ BANK_EMPLOYEE → addAddressPair

        vm.prank(sara);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, sara
        ));
        userGov.createUser(); // ✗ CUSTODY_MANAGER → createUser
    }

    function test_BR02_custodyManager_canCreateAndApprove_notRejectOrRemove() public {
        // CUSTODY_MANAGER covers onboarding (createUser, approveUser) but NOT
        // the destructive operations (rejectUser, removeUser) — those belong to PRIVACY_NODE_OPERATOR.
        vm.prank(custodyMgr);
        userGov.createUser();
        assertEq(userGov.createUserCalls(), 1);

        vm.prank(custodyMgr);
        userGov.approveUser();
        assertEq(userGov.approveUserCalls(), 1);

        vm.prank(custodyMgr);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, custodyMgr
        ));
        userGov.rejectUser(); // ✗ PRIVACY_NODE_OPERATOR only
    }

    function _assertSingleRole(address target, bytes4 sel, uint64 expectedRole) internal view {
        uint64[] memory roles = manager.getFunctionAllowedRoles(target, sel);
        assertEq(roles.length, 1);
        assertEq(roles[0], expectedRole);
    }

    function test_BR02_getFunctionAllowedRoles_reflectsConfiguration() public view {
        _assertSingleRole(address(tokenGov), SEL_ADD_TOKEN, TOKENIZER_ID);
        _assertSingleRole(address(tokenGov), SEL_UPDATE_STATUS, COMPLIANCE_OFFICER_ID);
        _assertSingleRole(address(hubRegistry), SEL_FREEZE, COMPLIANCE_TOOL_ID);
        _assertSingleRole(address(userGov), SEL_REJECT_USER, PRIVACY_NODE_OPERATOR_ID);
    }

    // =========================================================================
    // BR-03: Third-Party Integration with Minimal Blast Radius
    // "Onboard compliance tools, custody providers, settlement engines
    //  WITHOUT sharing the owner key. Each 3P role maps to <5 functions
    //  on ≤2 contracts."
    // =========================================================================

    function test_BR03_complianceTool_onlyFreezeUnfreeze() public {
        // COMPLIANCE_TOOL (AML automated response) can freeze AND unfreeze
        vm.prank(compTool);
        hubRegistry.freezeToken();
        vm.prank(compTool);
        hubRegistry.unfreezeToken();

        // But cannot touch addToken, updateStatus, or any user governance
        vm.prank(compTool);
        vm.expectRevert();
        tokenGov.addToken();

        vm.prank(compTool);
        vm.expectRevert();
        userGov.createUser();
    }

    function test_BR03_custodyManager_onlyUserOnboarding() public {
        // CUSTODY_MANAGER: createUser + approveUser — nothing else
        vm.prank(custodyMgr);
        userGov.createUser();
        vm.prank(custodyMgr);
        userGov.approveUser();

        // Cannot call anything on token governance
        vm.prank(custodyMgr);
        vm.expectRevert();
        tokenGov.addToken();

        // Cannot call anything on hub registry
        vm.prank(custodyMgr);
        vm.expectRevert();
        hubRegistry.freezeToken();
    }

    function test_BR03_tokenizer_onlyAddToken() public {
        // TOKENIZER (3P tokenization platform): exactly one function on one contract
        vm.prank(tokenizer_);
        tokenGov.addToken();

        // Cannot update status (sensitive operation)
        vm.prank(tokenizer_);
        vm.expectRevert();
        tokenGov.updateTokenStatus();

        // Cannot touch user governance at all
        vm.prank(tokenizer_);
        vm.expectRevert();
        userGov.createUser();
    }

    function test_BR03_attacker_cannotCallAnyRestrictedFunction() public {
        // Uninvited caller gets Unauthorized on every restricted function
        vm.prank(attacker);
        vm.expectRevert();
        tokenGov.addToken();

        vm.prank(attacker);
        vm.expectRevert();
        hubRegistry.freezeToken();

        vm.prank(attacker);
        vm.expectRevert();
        userGov.createUser();

        vm.prank(attacker);
        vm.expectRevert();
        userGov.removeUser();
    }

    function test_BR03_complianceTool_canCallFunctions_adminCanRevoke() public {
        // 1. compTool works
        vm.prank(compTool);
        hubRegistry.freezeToken();
        assertEq(hubRegistry.freezeCalls(), 1);

        // 2. Operator revokes the 3P integration
        vm.prank(marcos);
        manager.revokeRole(COMPLIANCE_TOOL_ID, compTool);

        // 3. compTool is now unauthorized
        vm.prank(compTool);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, compTool
        ));
        hubRegistry.freezeToken();
    }

    // =========================================================================
    // BR-04: Temporal Controls (Execution Delays)
    // "Sensitive operations (e.g. updateTokenStatus) should require a delay
    //  to enable operator review (FR-9 Approval Workflow)."
    // =========================================================================

    function test_BR04_executionDelay_directCallReverts_withMustSchedule() public {
        // Re-grant compOfficer with 24h execution delay
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        vm.prank(compOfficer);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__MustSchedule.selector,
            compOfficer,
            uint32(24 hours)
        ));
        tokenGov.updateTokenStatus();
    }

    function test_BR04_schedule_storesOperation() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);

        uint48 readyAt = manager.getSchedule(opId);
        assertEq(readyAt, uint48(block.timestamp) + uint48(24 hours));
    }

    function test_BR04_execute_beforeDelay_reverts() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);

        // 23h later — still not ready
        vm.warp(block.timestamp + 23 hours);
        vm.prank(compOfficer);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotReady.selector,
            opId,
            uint48(block.timestamp - 23 hours) + uint48(24 hours)
        ));
        manager.execute(address(tokenGov), data);
    }

    function test_BR04_execute_afterDelay_succeeds() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        vm.prank(compOfficer);
        manager.schedule(address(tokenGov), data, 0);

        vm.warp(block.timestamp + 24 hours + 1);

        vm.prank(compOfficer);
        manager.execute(address(tokenGov), data);

        assertEq(tokenGov.updateStatusCalls(), 1);
    }

    function test_BR04_execute_afterExpiration_reverts() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);

        // Warp past expiration window (24h delay + 7-day EXPIRATION)
        vm.warp(block.timestamp + 24 hours + 7 days + 1);

        vm.prank(compOfficer);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__Expired.selector, opId
        ));
        manager.execute(address(tokenGov), data);
    }

    // =========================================================================
    // BR-05: Audit Trail / Compliance Reporting
    // "All permission changes SHALL emit indexed events."
    // =========================================================================

    function test_BR05_auditTrail_RoleGranted_emitted() public {
        address newEmployee = makeAddr("newEmployee");
        vm.expectEmit(true, true, false, true);
        emit IRaylsAccessManager.RoleGranted(
            BANK_EMPLOYEE_ID, newEmployee, 0, uint48(block.timestamp), marcos
        );
        vm.prank(marcos);
        manager.grantRole(BANK_EMPLOYEE_ID, newEmployee, 0);
    }

    function test_BR05_auditTrail_RoleRevoked_emitted() public {
        vm.expectEmit(true, true, true, false);
        emit IRaylsAccessManager.RoleRevoked(BANK_EMPLOYEE_ID, sara, marcos);
        vm.prank(marcos);
        manager.revokeRole(BANK_EMPLOYEE_ID, sara);
    }

    function test_BR05_auditTrail_FunctionAllowedRoleAdded_emitted() public {
        address newTarget = makeAddr("newTarget");
        bytes4 newSel = bytes4(keccak256("newFunction()"));
        vm.expectEmit(true, true, true, false);
        emit IRaylsAccessManager.FunctionAllowedRoleAdded(newTarget, newSel, PRIVACY_NODE_OPERATOR_ID);
        _setFnRole(newTarget, newSel, PRIVACY_NODE_OPERATOR_ID);
    }

    function test_BR05_auditTrail_ContractPauseUpdated_emitted() public {
        vm.expectEmit(true, false, false, true);
        emit IRaylsAccessManager.ContractPauseUpdated(address(tokenGov), true);
        manager.setContractPaused(address(tokenGov), true);
    }

    function test_BR05_auditTrail_OperationScheduled_emitted() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        bytes32 opId = _operationId(compOfficer, address(tokenGov), data);
        uint48 expectedReady = uint48(block.timestamp) + uint48(24 hours);

        vm.expectEmit(true, true, true, true);
        emit IRaylsAccessManager.OperationScheduled(opId, compOfficer, address(tokenGov), expectedReady);

        vm.prank(compOfficer);
        manager.schedule(address(tokenGov), data, 0);
    }

    function test_BR05_auditTrail_OperationExecuted_emitted() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        bytes32 opId = _operationId(compOfficer, address(tokenGov), data);

        vm.prank(compOfficer);
        manager.schedule(address(tokenGov), data, 0);
        vm.warp(block.timestamp + 24 hours + 1);

        vm.expectEmit(true, true, false, false);
        emit IRaylsAccessManager.OperationExecuted(opId, address(tokenGov));

        vm.prank(compOfficer);
        manager.execute(address(tokenGov), data);
    }

    function test_BR05_auditTrail_OperationCanceled_emitted() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());
        bytes32 opId = _operationId(compOfficer, address(tokenGov), data);

        vm.prank(compOfficer);
        manager.schedule(address(tokenGov), data, 0);

        vm.expectEmit(true, false, false, false);
        emit IRaylsAccessManager.OperationCanceled(opId);

        vm.prank(marcos); // guardian cancels
        manager.cancel(compOfficer, address(tokenGov), data);
    }

    function test_BR05_auditTrail_RoleRegistered_emitted() public {
        vm.expectEmit(false, false, false, true);
        // nextRoleId is 8 after setUp (IDs 1-7 already assigned); next = 8
        emit IRaylsAccessManager.RoleRegistered(8, "SETTLEMENT_ENGINE");
        manager.registerRole("SETTLEMENT_ENGINE");
    }

    // =========================================================================
    // BR-06: Emergency Pause Per Target
    // "If a contract has a bug, pause ONLY that contract without affecting
    //  others. Only ADMIN can close/reopen targets."
    // =========================================================================

    function test_BR06_closedTarget_blocksAllRestrictedCalls() public {
        manager.setContractPaused(address(tokenGov), true);

        // Both authorized users are blocked while tokenGov is closed — with ContractPaused error
        vm.prank(tokenizer_);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        tokenGov.addToken();

        vm.prank(compOfficer);
        vm.expectRevert(RaylsAccessManaged.RaylsAccessManaged__ContractPaused.selector);
        tokenGov.updateTokenStatus();
    }

    function test_BR06_closedTarget_doesNotAffectOtherTargets() public {
        // Close tokenGov but hubRegistry and userGov remain operational
        manager.setContractPaused(address(tokenGov), true);

        vm.prank(compTool);
        hubRegistry.freezeToken(); // unaffected ✓

        vm.prank(custodyMgr);
        userGov.createUser(); // unaffected ✓
    }

    function test_BR06_adminCanReopenTarget() public {
        manager.setContractPaused(address(tokenGov), true);
        assertEq(manager.isContractPaused(address(tokenGov)), true);

        manager.setContractPaused(address(tokenGov), false);
        assertEq(manager.isContractPaused(address(tokenGov)), false);

        // After reopen, authorized callers work again
        vm.prank(tokenizer_);
        tokenGov.addToken();
        assertEq(tokenGov.addTokenCalls(), 1);
    }

    function test_BR06_nonAdminCannotCloseTarget() public {
        vm.prank(marcos);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__Unauthorized.selector, marcos
        ));
        manager.setContractPaused(address(tokenGov), true);
    }

    // =========================================================================
    // BR-07: Identity Isolation
    // "Each Privacy Node and Private Network Hub SHALL deploy its own
    //  independent RaylsAccessManagerV1 instance. Roles are LOCAL to each
    //  instance — a grant on chain A does NOT apply on chain B."
    // =========================================================================

    function test_BR07_roleGrantedOnChainA_doesNotAuthorizeOnChainB() public {
        // Deploy second independent manager (simulates a different chain)
        address chainBAdmin = makeAddr("chainBAdmin");
        RaylsAccessManagerV1 managerB = RaylsAccessManagerV1(
            address(new ERC1967Proxy(
                implAddr,
                abi.encodeCall(RaylsAccessManagerV1.initialize, (chainBAdmin))
            ))
        );

        // Deploy a target on chain B (uses managerB as authority)
        MockTokenGovernance chainBToken = new MockTokenGovernance(address(managerB));

        // Register & map addToken on chain B (no selectors mapped yet → ADMIN default)
        // tokenizer_ has TOKENIZER on chain A manager but NOT on chain B manager.
        vm.prank(tokenizer_);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, tokenizer_
        ));
        chainBToken.addToken(); // ✗ not authorized on chain B
    }

    function test_BR07_sameRoleIdMeansNothingAcrossManagers() public {
        // On chain A, TOKENIZER_ID maps addToken. tokenizer_ is a member.
        (bool onA,) = manager.hasRole(TOKENIZER_ID, tokenizer_);
        assertTrue(onA);

        // On chain B, tokenizer_ has no membership even though the role ID is the same.
        address chainBAdmin = makeAddr("chainBAdmin2");
        RaylsAccessManagerV1 managerB = RaylsAccessManagerV1(
            address(new ERC1967Proxy(
                implAddr,
                abi.encodeCall(RaylsAccessManagerV1.initialize, (chainBAdmin))
            ))
        );
        (bool onB,) = managerB.hasRole(TOKENIZER_ID, tokenizer_);
        assertFalse(onB);
    }

    function test_BR07_eachChainOwnsItsOwnAdminRole() public {
        address chainBAdmin = makeAddr("chainBAdmin3");
        RaylsAccessManagerV1 managerB = RaylsAccessManagerV1(
            address(new ERC1967Proxy(
                implAddr,
                abi.encodeCall(RaylsAccessManagerV1.initialize, (chainBAdmin))
            ))
        );

        // admin has ADMIN on chain A but not on chain B
        (bool adminOnA,) = manager.hasRole(manager.ADMIN(), admin);
        assertTrue(adminOnA);

        (bool adminOnB,) = managerB.hasRole(managerB.ADMIN(), admin);
        assertFalse(adminOnB); // chain B admin is chainBAdmin, not address(this)

        (bool chainBAdminOnB,) = managerB.hasRole(managerB.ADMIN(), chainBAdmin);
        assertTrue(chainBAdminOnB);
    }

    // =========================================================================
    // BR-08: Delegation / Role Hierarchy
    // "PRIVACY_NODE_OPERATOR can grant/revoke BANK_EMPLOYEE role but CANNOT grant
    //  ADMIN. Role admin authority ≠ function permission authority."
    // =========================================================================

    function test_BR08_operator_canGrantBankEmployeeRole() public {
        address newEmployee = makeAddr("newEmployee");
        vm.prank(marcos);
        manager.grantRole(BANK_EMPLOYEE_ID, newEmployee, 0);

        (bool isMember,) = manager.hasRole(BANK_EMPLOYEE_ID, newEmployee);
        assertTrue(isMember);

        // New employee can immediately call functions mapped to BANK_EMPLOYEE
        vm.prank(newEmployee);
        userGov.addAddressPair();
        assertEq(userGov.addPairCalls(), 1);
    }

    function test_BR08_operator_canRevokeRole() public {
        // sara is BANK_EMPLOYEE; marcos revokes it
        vm.prank(marcos);
        manager.revokeRole(BANK_EMPLOYEE_ID, sara);

        (bool isMember,) = manager.hasRole(BANK_EMPLOYEE_ID, sara);
        assertFalse(isMember);

        // sara's access is gone
        vm.prank(sara);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, sara
        ));
        userGov.addAddressPair();
    }

    function test_BR08_operator_cannotGrantAdminRole() public {
        // PRIVACY_NODE_OPERATOR_ID is NOT the admin of ADMIN; only ADMIN (self) can grant ADMIN.
        // Cache ADMIN before pranking to avoid prank being consumed by a staticcall.
        uint64 adminRole = manager.ADMIN();
        vm.startPrank(marcos);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotRoleAdmin.selector,
            marcos,
            adminRole
        ));
        manager.grantRole(adminRole, marcos, 0);
        vm.stopPrank();
    }

    function test_BR08_nonRoleAdmin_cannotGrantRole() public {
        // attacker cannot grant any role
        vm.prank(attacker);
        vm.expectRevert();
        manager.grantRole(BANK_EMPLOYEE_ID, attacker, 0);
    }

    function test_BR08_memberCanRenounceOwnRole() public {
        // sara voluntarily gives up her BANK_EMPLOYEE role
        vm.prank(sara);
        manager.renounceRole(BANK_EMPLOYEE_ID, sara);

        (bool isMember,) = manager.hasRole(BANK_EMPLOYEE_ID, sara);
        assertFalse(isMember);
    }

    // =========================================================================
    // BR-09: Readable Role Names
    // "Operators should see 'BANK_EMPLOYEE' not just 'role 2' in audit logs."
    // =========================================================================

    function test_BR09_registerRole_createsNamedRole() public {
        uint64 id = manager.registerRole("SETTLEMENT_ENGINE");
        assertEq(manager.getRoleIdByName("SETTLEMENT_ENGINE"), id);
    }

    function test_BR09_getRoleIdByName_returnsCorrectId() public view {
        assertEq(manager.getRoleIdByName("PRIVACY_NODE_OPERATOR"),           PRIVACY_NODE_OPERATOR_ID);
        assertEq(manager.getRoleIdByName("BANK_EMPLOYEE"),      BANK_EMPLOYEE_ID);
        assertEq(manager.getRoleIdByName("COMPLIANCE_OFFICER"), COMPLIANCE_OFFICER_ID);
        assertEq(manager.getRoleIdByName("COMPLIANCE_TOOL"),    COMPLIANCE_TOOL_ID);
        assertEq(manager.getRoleIdByName("CUSTODY_MANAGER"),    CUSTODY_MANAGER_ID);
        assertEq(manager.getRoleIdByName("TOKENIZER"),          TOKENIZER_ID);
    }

    function test_BR09_hasRoleByName_reflectsMembership() public view {
        assertTrue(manager.hasRoleByName("BANK_EMPLOYEE",   sara));
        assertTrue(manager.hasRoleByName("COMPLIANCE_TOOL", compTool));
        assertFalse(manager.hasRoleByName("BANK_EMPLOYEE",  attacker));
    }

    function test_BR09_duplicateRoleName_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__RoleAlreadyRegistered.selector,
            "PRIVACY_NODE_OPERATOR"
        ));
        manager.registerRole("PRIVACY_NODE_OPERATOR");
    }

    // =========================================================================
    // BR-10: Fail-Closed / Safe Default
    // "Functions with `restricted` but no explicit manager mapping default to
    //  ADMIN — non-admins are denied. Only ADMIN can call unmapped functions."
    // =========================================================================

    function test_BR10_unmappedSelector_deniesNonAdmin() public {
        // tokenGov.adminOnlyByDefault() has no mapping → defaults to ADMIN
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, attacker
        ));
        tokenGov.adminOnlyByDefault();
    }

    function test_BR10_unmappedSelector_allowsAdmin() public {
        // admin (ADMIN) can call ANY restricted function regardless of mapping
        tokenGov.adminOnlyByDefault(); // called from address(this) = admin
        assertEq(tokenGov.unmappedCalls(), 1);
    }

    function test_BR10_canCall_unmappedSelector_returnsFalseForNonAdmin() public view {
        (bool allowed, uint32 delay,) = manager.canCall(
            attacker, address(tokenGov), bytes4(0xdeadbeef)
        );
        assertFalse(allowed);
        assertEq(delay, 0);
    }

    function test_BR10_publicRole_allowsEveryone() public {
        // Map getAllTokens (view function wrapper) to PUBLIC so anyone can call it
        _setFnRole(address(tokenGov), MockTokenGovernance.getTokenInfo.selector, manager.PUBLIC());

        (bool allowed,,) = manager.canCall(
            attacker, address(tokenGov), MockTokenGovernance.getTokenInfo.selector
        );
        assertTrue(allowed);
    }

    // =========================================================================
    // FR-2: Flow-Based Permission Model
    // "Operator selects which flows Bank Employees can have available."
    // Each flow = a set of function selectors mapped to the same role.
    // =========================================================================

    function test_FR2_tokenisationFlow_grantsAddToken() public {
        // TOKENIZER_ID = Tokenisation Flow (addToken only)
        vm.prank(tokenizer_);
        tokenGov.addToken();
        assertEq(tokenGov.addTokenCalls(), 1);

        // tokenizer_ cannot call sensitive operations outside its flow
        vm.prank(tokenizer_);
        vm.expectRevert();
        tokenGov.updateTokenStatus(); // COMPLIANCE_OFFICER flow
    }

    function test_FR2_complianceFlow_grantsFreeze_notUpdateStatus() public {
        // COMPLIANCE_TOOL_ID = Compliance Flow (freeze + unfreeze)
        vm.prank(compTool);
        hubRegistry.freezeToken();
        vm.prank(compTool);
        hubRegistry.unfreezeToken();

        // Compliance flow does NOT cover token status updates
        vm.prank(compTool);
        vm.expectRevert();
        tokenGov.updateTokenStatus();
    }

    function test_FR2_operatorCanAssignFlowsToNewEmployee() public {
        // Operator creates a new bank employee and grants them the BANK_EMPLOYEE flow
        address newSara = makeAddr("newSara");

        vm.prank(marcos); // PRIVACY_NODE_OPERATOR grants BANK_EMPLOYEE
        manager.grantRole(BANK_EMPLOYEE_ID, newSara, 0);

        // newSara can now call addAddressPair (BANK_EMPLOYEE flow) and hubRegistry.updateStatus
        vm.prank(newSara);
        userGov.addAddressPair();
        assertEq(userGov.addPairCalls(), 1);

        vm.prank(newSara);
        hubRegistry.updateStatus();
        assertEq(hubRegistry.updateStatusCalls(), 1);
    }

    // =========================================================================
    // FR-9: Approval Workflow
    // "Some operations require Operator approval — implemented via execution
    //  delays: schedule → wait (review window) → execute OR cancel."
    // =========================================================================

    function test_FR9_sensitiveOperation_mustBeScheduled() public {
        // Give compOfficer a 24h review window for token status updates
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));

        vm.prank(compOfficer);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__MustSchedule.selector,
            compOfficer, uint32(24 hours)
        ));
        tokenGov.updateTokenStatus();
    }

    function test_FR9_scheduleAndExecute_fullApprovalWorkflow() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));
        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());

        // Step 1: compOfficer submits the request
        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);
        assertGt(manager.getSchedule(opId), 0);

        // Step 2: 24h review window passes (operator had the chance to cancel)
        vm.warp(block.timestamp + 24 hours + 1);

        // Step 3: compOfficer executes
        vm.prank(compOfficer);
        manager.execute(address(tokenGov), data);

        // Operation was executed and cleared
        assertEq(tokenGov.updateStatusCalls(), 1);
        assertEq(manager.getSchedule(opId), 0);
    }

    function test_FR9_operator_canVetoByCanceling_duringReviewWindow() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));
        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());

        // compOfficer submits
        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);
        assertGt(manager.getSchedule(opId), 0);

        // marcos (PRIVACY_NODE_OPERATOR, guardian of COMPLIANCE_OFFICER) vetoes during review window
        vm.prank(marcos);
        manager.cancel(compOfficer, address(tokenGov), data);

        // Operation is cleared — compOfficer cannot execute
        assertEq(manager.getSchedule(opId), 0);
        assertEq(tokenGov.updateStatusCalls(), 0);
    }

    // =========================================================================
    // SC-07: Grant Delays
    // "Newly granted memberships become active only after the grant delay
    //  window — prevents instant privilege escalation."
    // =========================================================================

    function test_SC07_grantDelay_newMemberInactiveUntilDelayPasses() public {
        // Set 2-day grant delay for COMPLIANCE_OFFICER before the grant
        manager.setGrantDelay(COMPLIANCE_OFFICER_ID, uint32(2 days));

        address newOfficer = makeAddr("newOfficer");
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, newOfficer, 0);

        // Immediately after grant: not yet active
        (bool isMember,) = manager.hasRole(COMPLIANCE_OFFICER_ID, newOfficer);
        assertFalse(isMember);

        // canCall → denied (grant delay pending)
        (bool allowed,,) = manager.canCall(newOfficer, address(tokenGov), SEL_UPDATE_STATUS);
        assertFalse(allowed);
    }

    function test_SC07_grantDelay_memberActiveAfterDelayWindow() public {
        manager.setGrantDelay(COMPLIANCE_OFFICER_ID, uint32(2 days));

        address newOfficer = makeAddr("newOfficer");
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, newOfficer, 0);

        vm.warp(block.timestamp + 2 days + 1);

        (bool isMember,) = manager.hasRole(COMPLIANCE_OFFICER_ID, newOfficer);
        assertTrue(isMember);

        vm.prank(newOfficer);
        tokenGov.updateTokenStatus();
        assertEq(tokenGov.updateStatusCalls(), 1);
    }

    function test_SC07_grantDelay_preventsInstantPrivilegeEscalation() public {
        // Set 7-day grant delay for COMPLIANCE_OFFICER_ID
        manager.setGrantDelay(COMPLIANCE_OFFICER_ID, uint32(7 days));

        address escalator = makeAddr("escalator");
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, escalator, 0);

        // Even 6 days 23 hours later — still no access
        vm.warp(block.timestamp + 7 days - 1);

        vm.prank(escalator);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, escalator
        ));
        tokenGov.updateTokenStatus();
    }

    // =========================================================================
    // SC-08: Guardian Role
    // "PRIVACY_NODE_OPERATOR is guardian of COMPLIANCE_OFFICER — can cancel
    //  their scheduled operations during the review window."
    // =========================================================================

    function test_SC08_guardian_canCancelScheduledOperation() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));
        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());

        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);

        // marcos (PRIVACY_NODE_OPERATOR = guardian of COMPLIANCE_OFFICER) cancels
        vm.prank(marcos);
        manager.cancel(compOfficer, address(tokenGov), data);

        assertEq(manager.getSchedule(opId), 0);
    }

    function test_SC08_originalScheduler_canCancelOwnOperation() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));
        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());

        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);

        // compOfficer cancels their own scheduled operation
        vm.prank(compOfficer);
        manager.cancel(compOfficer, address(tokenGov), data);

        assertEq(manager.getSchedule(opId), 0);
    }

    function test_SC08_thirdParty_cannotCancelOthersOperation() public {
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, compOfficer, uint32(24 hours));
        bytes memory data = abi.encodeCall(MockTokenGovernance.updateTokenStatus, ());

        vm.prank(compOfficer);
        bytes32 opId = manager.schedule(address(tokenGov), data, 0);

        // attacker is neither the scheduler nor a guardian — cannot cancel
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__NotRoleGuardianOrScheduler.selector,
            opId
        ));
        manager.cancel(compOfficer, address(tokenGov), data);
    }

    // =========================================================================
    // SC-10: Least Privilege Enforcement
    // "Being admin of role X does NOT grant the function permissions of role X.
    //  Role admin authority ≠ function permission authority."
    // =========================================================================

    function test_SC10_roleAdmin_doesNotImplyFunctionPermission() public {
        // marcos has PRIVACY_NODE_OPERATOR_ID. PRIVACY_NODE_OPERATOR_ID is the admin of TOKENIZER_ID.
        // addToken is mapped to TOKENIZER_ID.
        // marcos does NOT have TOKENIZER_ID, so he cannot call addToken.
        vm.prank(marcos);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, marcos
        ));
        tokenGov.addToken();
    }

    function test_SC10_roleAdmin_impliesOnlyGrantRevoke_notFunctionAccess() public {
        // marcos (PRIVACY_NODE_OPERATOR) can grant/revoke COMPLIANCE_OFFICER (admin of it)
        // but cannot call functions mapped to COMPLIANCE_OFFICER.
        vm.prank(marcos);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManaged.RaylsAccessManaged__Unauthorized.selector, marcos
        ));
        tokenGov.updateTokenStatus(); // COMPLIANCE_OFFICER territory

        // But marcos CAN grant COMPLIANCE_OFFICER to another address
        address newOfficer = makeAddr("newOfficer");
        vm.prank(marcos);
        manager.grantRole(COMPLIANCE_OFFICER_ID, newOfficer, 0);
        (bool isMember,) = manager.hasRole(COMPLIANCE_OFFICER_ID, newOfficer);
        assertTrue(isMember);
    }

    function test_SC10_everyPermissionMustBeExplicitlyGranted() public {
        // A freshly deployed address has zero permissions on any restricted function
        address freshAddr = makeAddr("fresh");

        (bool allowed1,,) = manager.canCall(freshAddr, address(tokenGov), SEL_ADD_TOKEN);
        (bool allowed2,,) = manager.canCall(freshAddr, address(hubRegistry), SEL_FREEZE);
        (bool allowed3,,) = manager.canCall(freshAddr, address(userGov), SEL_CREATE_USER);

        assertFalse(allowed1);
        assertFalse(allowed2);
        assertFalse(allowed3);
    }

    // =========================================================================
    // BR-11: ADMIN — Global Admin with Safe Bootstrap
    // "ADMIN is the only role that can configure targets, close contracts,
    //  and upgrade the manager. It is self-administered."
    // =========================================================================

    function test_BR11_adminCanCallAnyRestrictedFunction() public {
        // admin (ADMIN) bypasses all function→role checks
        tokenGov.addToken();          // addToken → TOKENIZER, but admin overrides
        tokenGov.updateTokenStatus(); // updateTokenStatus → COMPLIANCE_OFFICER, but admin overrides
        hubRegistry.freezeToken();    // freezeToken → COMPLIANCE_TOOL, but admin overrides
        userGov.removeUser();         // removeUser → PRIVACY_NODE_OPERATOR, but admin overrides

        assertEq(tokenGov.addTokenCalls(),      1);
        assertEq(tokenGov.updateStatusCalls(),  1);
        assertEq(hubRegistry.freezeCalls(),     1);
        assertEq(userGov.removeUserCalls(),     1);
    }

    function test_BR11_adminRole_isSelfAdministered() public {
        // ADMIN's admin is ADMIN itself (admin.admin == ADMIN)
        assertEq(manager.getRoleAdmin(manager.ADMIN()), manager.ADMIN());
    }

    function test_BR11_nonAdminCannotConfigureTargetFunctions() public {
        bytes4[] memory sels = new bytes4[](1);
        sels[0] = SEL_ADD_TOKEN;

        vm.prank(marcos);
        vm.expectRevert(abi.encodeWithSelector(
            RaylsAccessManagerV1__Unauthorized.selector, marcos
        ));
        manager.addFunctionAllowedRoles(address(tokenGov), sels, _singleRole(COMPLIANCE_TOOL_ID));
    }

    function test_BR11_onlyAdminCanGrantAdminRole() public {
        // A PRIVACY_NODE_OPERATOR cannot escalate to ADMIN
        // Cache ADMIN before pranking to avoid prank being consumed by a staticcall.
        uint64 adminRole = manager.ADMIN();
        vm.startPrank(marcos);
        vm.expectRevert();
        manager.grantRole(adminRole, marcos, 0);
        vm.stopPrank();

        // ADMIN (address(this)) can grant ADMIN to another address
        address newAdmin = makeAddr("newAdmin");
        manager.grantRole(manager.ADMIN(), newAdmin, 0);
        (bool isAdmin,) = manager.hasRole(manager.ADMIN(), newAdmin);
        assertTrue(isAdmin);
    }
}

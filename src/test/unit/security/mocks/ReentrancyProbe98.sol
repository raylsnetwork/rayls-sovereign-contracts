// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ReentrancyProbe98 — E2E test contract for deploy() reentrancy
 *
 * @notice Simulates a third-party RaylsApp / integration contract that:
 *           (a) holds `FACTORY_DEPLOYER` role on the live AccessManager,
 *           (b) gets deployed by the factory (via its bytecode being passed to factory.deploy),
 *           (c) when invoked via factory's post-deploy init-call, RE-ENTERS factory.deploy.
 *
 *         Standard Rayls contracts (RNEndpointV1, ResourceManager) hold FACTORY_DEPLOYER
 *         today but do NOT have such a re-entrant pattern. This probe exists to prove the
 *         contract-level reentrancy bug fires for ANY future role-holder that introduces
 *         such a pattern — defense-in-depth justification.
 *
 *         Lives at `src/test/unit/security/mocks/ReentrancyProbe98.sol` so the
 *         `sync-contracts-local.sh` script in `rayls-privacy-tests-automation` (which
 *         excludes only `*.t.sol`) brings it into the e2e suite's `contracts/remote/`
 *         tree on every sync.
 *
 * @dev   Deployment flow (used in e2e test):
 *          1. Test deploys this contract DIRECTLY via `new ReentrancyProbe98(factoryAddr)`.
 *             Constructor bakes `factoryAddr` into the runtime as an immutable.
 *          2. Test reads probe.code; the runtime has factoryAddr embedded inline.
 *          3. Test grants FACTORY_DEPLOYER to a CREATE2-predicted address.
 *          4. Test calls factory.deploy(probe.code, "", id). Factory CREATE2-deploys at the
 *             predicted address. Same baked-in factoryAddr.
 *          5. Factory's init-call lands on the deployed copy's `fallback()`. The fallback
 *             reads the immutable factoryAddr (no storage needed) and re-enters
 *             `factory.deploy(<innerBytecode>, "", id)`.
 *          6. If inner call succeeds, deployed copy writes a flag to slot 1.
 *
 *         After the fix (`nonReentrant` on deploy()), step 5's inner call reverts with
 *         ReentrancyGuardReentrantCall. The fallback's `(bool ok, ) = ...` catches the
 *         revert; ok = false; slot 1 stays zero.
 */
contract ReentrancyProbe98 {
    /// @dev Baked into runtime as immutable; survives CREATE2 copy.
    address public immutable factoryAddr;

    /// @dev factory.deploy(bytes,bytes,bytes32) selector. Computed from the signature so
    ///      the probe stays correct if the factory ever reorders or adds parameters — a
    ///      hand-rolled hex literal would silently mis-target a renamed selector.
    bytes4 internal constant DEPLOY_SEL = bytes4(keccak256("deploy(bytes,bytes,bytes32)"));

    /// @dev Inner deploy uses 1-byte STOP runtime — universally safe init-call target.
    bytes internal constant INNER_BYTECODE = hex"00";

    constructor(address _factory) {
        factoryAddr = _factory;
    }

    fallback() external payable {
        bool already;
        assembly { already := sload(0) }
        if (already) return;
        assembly { sstore(0, 1) }

        bytes32 innerId = bytes32(uint256(0xCAFE));
        bytes memory data = abi.encodeWithSelector(
            DEPLOY_SEL,
            INNER_BYTECODE,
            "",
            innerId
        );

        (bool ok, ) = factoryAddr.call(data);
        if (ok) {
            assembly { sstore(1, 1) }
        }
    }

    /// @dev Companion to the payable fallback. Required for forge-lint; never invoked in
    ///      practice (no test sends ETH with empty calldata).
    receive() external payable {}
}

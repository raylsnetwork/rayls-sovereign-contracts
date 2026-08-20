// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../rayls-protocol-sdk/tokens/RaylsErc20Handler.sol";
import {IRaylsAccessManager} from "../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol";

contract TokenExample is RaylsErc20Handler {
    address public constant addressToFail =  address(0x0000000000000000000555000000000000001123);

    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    )
        RaylsErc20Handler(
            _name,
            _symbol,
            _endpoint,
            _raylsNodeEndpoint,
            _userGovernance,
            msg.sender,
            false
        )
    {
        _mint(msg.sender, 2000000 * 10 ** 18);
    }

    function GetERCStandard() public pure override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.ERC20Test;
    }

    function receiveTeleportAtomic(address to, uint256 value) public override restricted {
        if(to == addressToFail) revert("Destination address is the one that revert messages."); // created for test purposes

        super.receiveTeleportAtomic(to, value);
    }

    /// @custom:deprecated Decommissioning Teleport (vanilla, atomic).
    function receiveTeleportFromPublicChain(address to, uint256 value) public override {
        if (to == address(0))  revert("Hit destination revert address."); // created for test purposes

        super.receiveTeleportFromPublicChain(to, value);
    }

    /// @notice Mints tokens without notifying the Private Network Hub.
    /// @dev For test purposes only (simulates a malicious mint override that bypasses balance tracking).
    ///      Owner-gated (`restricted`) like `mint`/`burn` so it works under FACTORY-mode, where the
    ///      registrant EOA is the token owner but the constructor `msg.sender` is the deploying factory.
    ///      Deliberately omits the `_submitTokenUpdate` call `mint` makes — that omission is the fraud
    ///      being simulated (on-chain supply diverges from PNH-tracked balance).
    function fakeMint(address to, uint256 value) public restricted {
        _mint(to, value);
    }

    /// @dev Extends the parent's owner-gated selector set with `fakeMint` so the token owner can call
    ///      it. Mirrors {RaylsErc20Handler-_registerAccessControl} exactly (same MESSAGE_EXECUTOR and
    ///      RELAYER mappings, same TOKEN_OWNER-to-caller grant) — only `ownerSels` is extended.
    function _registerAccessControl(address _owner, address caller) internal virtual override {
        address mgr = address(endpoint) != address(0) ? endpoint.authority() : address(0);
        if (mgr == address(0)) return;

        _setAuthority(mgr);

        bytes4[] memory ownerSels = new bytes4[](4);
        ownerSels[0] = RaylsErc20Handler.mint.selector;
        ownerSels[1] = RaylsErc20Handler.burn.selector;
        ownerSels[2] = RaylsErc20Handler.submitTokenUpdate.selector;
        ownerSels[3] = this.fakeMint.selector;

        bytes4[] memory executorSels = new bytes4[](7);
        executorSels[0] = RaylsErc20Handler.receiveTeleport.selector;
        executorSels[1] = RaylsErc20Handler.receiveTeleportAtomic.selector;
        executorSels[2] = RaylsErc20Handler.revertTeleportMint.selector;
        executorSels[3] = RaylsErc20Handler.revertTeleportBurn.selector;
        executorSels[4] = RaylsErc20Handler.unlock.selector;
        executorSels[5] = RaylsErc20Handler.receiveTeleportFromPublicChain.selector;
        executorSels[6] = RaylsErc20Handler.revertTeleportToPublicChain.selector;

        bytes4[] memory relayerSels = new bytes4[](2);
        relayerSels[0] = RaylsErc20Handler.crossMint.selector;
        relayerSels[1] = RaylsErc20Handler.crossBurn.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](2);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);
        mappings[1] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);

        if (caller != address(0) && caller != _owner) {
            IRaylsAccessManager(mgr).grantSelfTokenOwner(caller);
        }
    }
}

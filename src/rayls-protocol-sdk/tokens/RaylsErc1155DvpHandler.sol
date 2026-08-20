// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsApp} from '../RaylsApp.sol';
import '@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import '../interfaces/IRaylsEndpoint.sol';
import '../RaylsMessage.sol';
import '../libraries/SharedObjects.sol';
import '../libraries/Utils.sol';
import '../Constants.sol';

import {IEnygmaPNEvents} from '../interfaces/IEnygmaPNEvents.sol';
import {IPNCommunicator} from '../interfaces/IPNCommunicator.sol';
import {IRaylsAccessManager} from '../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import {RaylsAccessManaged} from '../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsInitializer, RaylsTrustedInit} from '../IRaylsInitializer.sol';
import {IRaylsTokenStandard} from '../interfaces/IRaylsTokenStandard.sol';

/**
 * @title RaylsErc1155DvpHandler
 * @notice ERC1155 base for Rayls multi-tokens participating in Zero-Knowledge Delivery vs
 *         Payment. Adds per-account/per-id deposit-into-Dvp + withdraw + ZK swap with Enygma
 *         + state tracking via `lockedForDvp` and `readyForUnlockForDvp` mappings.
 * @dev Inherits ERC1155Supply + Initializable + ReentrancyGuard + RaylsAccessManaged.
 *      Owner-gated selectors: mint, burn, submitTokenUpdate, setSwapValidityTime.
 *      RELAYER-gated: unlockFromDvp, dvpSwapCompleted, notifySenderWithPNCommunicator,
 *      notifySenderAndReceiverWithPNCommunicator. MESSAGE_EXECUTOR-gated: unlock,
 *      MintFromSwapDvp. ReentrancyGuard guards every external mutation.
 */

abstract contract RaylsErc1155DvpHandler is RaylsApp, ERC1155Supply, Initializable, ReentrancyGuard, RaylsAccessManaged, IRaylsTokenStandard {
    using EnumerableSet for EnumerableSet.UintSet;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when an Enygma DvP swap validity time falls outside
    ///         `[ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME + 1, ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME - 1]`.
    /// @param provided Caller-supplied validity time.
    /// @param min Minimum allowed validity time (exclusive).
    /// @param max Maximum allowed validity time (exclusive).
    error RaylsErc1155DvpHandler__SwapValidityOutOfRange(uint64 provided, uint64 min, uint64 max);

    /// @dev Base URI returned by `uri()`. Settable at construction/initialize time.
    string private _uri;

    /// @notice Token name. Custom field — ERC1155 has no canonical name.
    string public name;

    /// @notice True for custom-token issuer flow; false for the standard template path.
    bool isCustom;

    /// @dev Always true — marks this contract as the DvP variant of ERC1155.
    bool private isDvp = true;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Emitted when a token id is locked for an account.
    /// @param account Account whose token was locked.
    /// @param tokenId Token id locked.
    event TokenLocked(address indexed account, uint256 indexed tokenId);

    /// @notice Emitted when a previously locked token id is released for an account.
    /// @param account Account whose token was unlocked.
    /// @param tokenId Token id unlocked.
    event TokenUnlocked(address indexed account, uint256 indexed tokenId);

    /// @notice Emitted when this ERC1155 DVP token contract is created and initialized.
    /// @param tokenAddress Address of the newly created token contract.
    event RaylsErc1155DvpTokenCreated(address indexed tokenAddress);

    /// @notice Per-token aggregate Dvp state (existence, lock counters, extra-data records).
    struct TokenData {
        bool exists;
        uint256 lockedAmount;
        uint256 readyForUnlockAmount;
        SharedObjects.Dvp1155ExtraData[] extraData;
    }

    /// @notice Per-token supply tracking (mirrors ERC1155Supply with a deploy-instructions guard).
    struct TokenSupply {
        uint256 totalSupply;
        bool alreadySentDeployInstructions;
    }

    /// @dev Per-id Dvp aggregate state — populated by `MintFromSwapDvp` on receive side.
    mapping(uint256 => TokenData) internal _tokenData;

    /// @dev Per-id supply + deploy-instructions guard.
    mapping(uint256 => TokenSupply) internal _tokenSupply;

    /// @dev Per-account, per-id lock flag used by the simple lock/unlock primitives.
    mapping(address => mapping(uint256 => bool)) internal lockedTokens;

    /// @dev Set of every token id that has been minted on this contract.
    EnumerableSet.UintSet internal _allTokenIds;

    /// @notice Per-account, per-id amount currently locked into Dvp.
    mapping(address => mapping(uint256 => uint256)) public lockedForDvp;

    /// @dev Per-account, per-id amount marked ready for Dvp unlock (post-`withdrawFromDvp`).
    mapping(address => mapping(uint256 => uint256)) readyForUnlockForDvp;

    /// @dev Per-id Dvp1155 extra-data records persisted alongside tokens.
    mapping(uint256 => SharedObjects.Dvp1155ExtraData[]) private tokenExtraData;

    /// @notice Validity time for Enygma DvP swaps in seconds.
    uint64 public swapValidityTime;

    /**
     * @notice Construct the handler with ERC1155 metadata + trusted endpoint references.
     * @dev `_disableInitializers()` blocks the upgradeable initialize path on the implementation.
     * @param uri Base URI for token metadata.
     * @param _name Token name (custom field).
     * @param _endpoint Trusted Rayls endpoint address.
     * @param _raylsNodeEndpoint Privacy-node endpoint; zero on PNH deploys.
     * @param _userGovernance UserGovernance binding; zero when unused.
     * @param _owner Address that receives owner-gated selectors.
     * @param _isCustom True for custom-token issuer flow; false for the standard template path.
     */
    constructor(
        string memory uri,
        string memory _name,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance,
        address _owner,
        bool _isCustom
    ) ERC1155(uri) ERC1155Supply() RaylsApp(_endpoint, _raylsNodeEndpoint, _userGovernance) {
        _uri = uri;
        name = _name;
        isCustom = _isCustom;
        swapValidityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        _registerAccessControl(_owner, address(0));
        _disableInitializers();
    }

    /**
     * @notice Canonical init entrypoint dispatched by RaylsContractFactoryV1.
     * @param userArgs ABI-encoded `(string uri, string name)`.
     *                 Caller-supplied via the cross-chain init payload.
     * @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
     *                 factory at deploy time. Caller cannot forge.
     */
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public virtual initializer {
        (string memory uri, string memory _name) = abi.decode(userArgs, (string, string));

        // ERC1155 initialization
        _uri = uri;
        name = _name;

        // RaylsApp initialization (trusted addresses from factory-injected struct)
        endpoint = IRaylsEndpoint(trusted.endpoint);
        resourceId = trusted.resourceId;
        _registerAccessControl(trusted.owner, trusted.caller);
        emit RaylsErc1155DvpTokenCreated(address(this));
    }

    /**
     * @notice Set the validity time applied to subsequent Enygma DvP swaps.
     * @dev Restricted to owner-gated callers. Reverts when `_validityTime` is outside
     *      `[ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME, ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME]`.
     * @param _validityTime Validity time in seconds.
     */
    function setSwapValidityTime(uint64 _validityTime) public virtual restricted {
        if (
            _validityTime <= Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME ||
            _validityTime >= Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
        ) {
            revert RaylsErc1155DvpHandler__SwapValidityOutOfRange(
                _validityTime,
                Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
            );
        }
        swapValidityTime = _validityTime;
    }

    /**
     * @notice Returns the ERC standard tag identifying this token shape.
     * @return The `SharedObjects.ErcStandard.DvpERC1155` enum value.
     */
    function GetERCStandard() public pure virtual override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.DvpERC1155;
    }

    /**
     * @notice Approve or revoke an operator only while this token is active on the local Privacy Node.
     * @param operator Account whose operator approval is updated.
     * @param approved True to approve the operator; false to revoke.
     */
    function setApprovalForAll(address operator, bool approved) public virtual override whenPrivacyNodeActive {
        super.setApprovalForAll(operator, approved);
    }

    /**
     * @notice Safely transfer tokens only while this token is active on the local Privacy Node.
     * @param from Account whose tokens are transferred.
     * @param to Recipient address.
     * @param id Token id to transfer.
     * @param value Amount to transfer.
     * @param data Additional data forwarded to the receiver hook.
     */
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes memory data) public virtual override whenPrivacyNodeActive {
        super.safeTransferFrom(from, to, id, value, data);
    }

    /**
     * @notice Safely transfer token batches only while this token is active on the local Privacy Node.
     * @param from Account whose tokens are transferred.
     * @param to Recipient address.
     * @param ids Token ids to transfer.
     * @param values Amounts to transfer for each token id.
     * @param data Additional data forwarded to the receiver hook.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public virtual override whenPrivacyNodeActive {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    /**
     * @notice Unlock the locked funds and transfer them to the specified address.
     * @dev Restricted to MESSAGE_EXECUTOR. If `to` is this contract, no transfer is issued.
     * @param to Recipient address to unlock the funds to.
     * @param id Id of the token to unlock.
     * @param value Amount of tokens to unlock.
     * @param data Additional data forwarded to the transfer hooks.
     * @return Always true on success; reverts otherwise.
     */
    function unlock(
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    ) external restricted nonReentrant whenHubActive returns (bool) {
        if (to != address(this)) {
            bool success = _unlock(to, id);
            require(success, 'cannot unlock the assets');
            _safeTransferFrom(address(this), to, id, value, data);
        }

        return true;
    }

    /**
     * @notice Internal lock primitive: marks an id as locked for an account.
     * @dev Reverts on zero `to`. Caller is responsible for any token transfer.
     * @param to Account whose token is being locked.
     * @param id Id to lock.
     */
    function _lock(address to, uint256 id) internal {
        require(to != address(0));
        lockedTokens[to][id] = true;
        emit TokenLocked(to, id);
    }

    /**
     * @notice Internal unlock primitive: clears the locked flag for an account/id pair.
     * @dev Reverts on zero `to` or when no lock is recorded.
     * @param to Account whose lock is being released.
     * @param id Id to unlock.
     * @return Always true on success; reverts otherwise.
     */
    function _unlock(address to, uint256 id) internal returns (bool) {
        require(to != address(0));
        bool isLocked = lockedTokens[to][id];
        require(isLocked == true, 'No funds to unlock');
        lockedTokens[to][id] = false;
        emit TokenUnlocked(to, id);
        return true;
    }

    /**
     * @notice Check whether a given token id is locked for an account.
     * @param account Account whose lock state is queried.
     * @param id Token id.
     * @return True if the token is locked for `account`.
     */
    function isTokenLocked(address account, uint256 id) public view returns (bool) {
        return lockedTokens[account][id];
    }

    /**
     * @notice Internal helper that dispatches a balance-update message to the PNH TokenRegistry.
     * @dev No-op when `resourceId` is unset (token not yet activated). Encodes per-id
     *      `(id, amount)` payload in `ERC1155Supply` form.
     * @param updateType MINT or BURN classification.
     * @param tokenId Token id changed.
     * @param value Amount changed.
     */
    function _submitTokenUpdate(
        SharedObjects.BalanceUpdateType updateType,
        uint256 tokenId,
        uint256 value
    ) internal {
        if (resourceId == bytes32(0)) {
            return;
        }

        _raylsSend(
            endpoint.getPrivateHubId(),
            endpoint.getPrivateHubAddress('TokenRegistry'),
            abi.encodeWithSignature(
                'updateTokenBalance(uint256,bytes32,uint8,bytes)',
                endpoint.getChainId(),
                resourceId,
                updateType,
                abi.encode(SharedObjects.ERC1155Supply(tokenId, value))
            )
        );
    }

    /**
     * @notice Submit a mint/burn update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param updateType MINT or BURN classification.
     * @param tokenId Token id changed.
     * @param value Amount changed.
     */
    function submitTokenUpdate(
        SharedObjects.BalanceUpdateType updateType,
        uint256 tokenId,
        uint256 value
    ) public virtual restricted {
        _submitTokenUpdate(updateType, tokenId, value);
    }

    /**
     * @notice Validate a token can participate in a Dvp operation for a given account+amount.
     * @dev Reverts unless the token is registered, exists in `_allTokenIds`, and the
     *      account has at least `_value` locked into Dvp.
     * @param from Account that owns the token.
     * @param _tokenId Token id.
     * @param _value Amount required.
     */
    function _validateDvpToken(address from, uint256 _tokenId, uint256 _value) internal view {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_allTokenIds.contains(_tokenId), 'Token does not exist');
        require(lockedForDvp[from][_tokenId] >= _value, 'This token is not deposited into Dvp');
    }

    /**
     * @notice Read the count of distinct token ids ever minted on this contract.
     * @return Length of `_allTokenIds`.
     */
    function getNumberAllTokens() public view returns (uint256) {
        return _allTokenIds.length();
    }

    /**
     * @notice Page through `_allTokenIds` and return per-id supply records.
     * @dev Reverts if `howMany == 0`. Clamps `endIndex` to set length.
     * @param startIndex Starting index in the set (0-based).
     * @param howMany Number of ids to return from `startIndex`.
     * @return supplies Array of `(id, totalSupply)` records.
     */
    function getBatchedAllTokenIdsWithSupply(
        uint256 startIndex,
        uint256 howMany
    ) public view virtual returns (SharedObjects.ERC1155Supply[] memory supplies) {
        require(howMany > 0, 'Invalid howMany value'); // Ensure howMany is greater than 0

        uint256 endIndex = startIndex + howMany - 1; // Calculate the end index based on startIndex and howMany

        if (endIndex > _allTokenIds.length()) {
            endIndex = _allTokenIds.length() - 1;
        }

        supplies = new SharedObjects.ERC1155Supply[](endIndex - startIndex + 1);

        for (uint256 i = startIndex; i <= endIndex; i++) {
            uint256 tokenId = _allTokenIds.at(i);
            supplies[i - startIndex] = SharedObjects.ERC1155Supply(tokenId, totalSupply(tokenId));
        }
    }

    /**
     * @notice Read every token id with its current total supply.
     * @return supply Array of `(id, totalSupply)` records covering `_allTokenIds`.
     */
    function getAllTokenIdsWithSupply()
        public
        view
        virtual
        returns (SharedObjects.ERC1155Supply[] memory supply)
    {
        uint256 length = _allTokenIds.length();
        supply = new SharedObjects.ERC1155Supply[](length);
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = _allTokenIds.at(i);
            supply[i] = SharedObjects.ERC1155Supply(tokenId, totalSupply(tokenId));
        }
    }

    /**
     * @notice Mint new tokens of an id with optional Dvp extra-data records, and submit the
     *         update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers. Adds the id to `_allTokenIds`. Emits a
     *      Dvp1155Mint event when active.
     * @param _to Recipient.
     * @param _id Token id.
     * @param value Amount to mint.
     * @param data Additional data forwarded to ERC1155 hooks.
     * @param _extraDatas Optional Dvp1155 extra-data records persisted alongside the token.
     */
    function mint(
        address _to,
        uint256 _id,
        uint256 value,
        bytes memory data,
        SharedObjects.Dvp1155ExtraData[] memory _extraDatas
    ) public virtual restricted nonReentrant whenPrivacyNodeActive {
        _mint(_to, _id, value, data);

        _allTokenIds.add(_id);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, _id, value);

        for (uint256 i = 0; i < _extraDatas.length; i++) {
            tokenExtraData[_id].push(_extraDatas[i]);
        }

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).dvp1155Mint(resourceId, _id, value, data);
        }
    }

    /**
     * @notice Burn tokens of an id and submit a balance update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers. Reverts if the requested amount exceeds the
     *      account's unlocked balance (locked-for-Dvp tokens cannot be burned).
     * @param _from Account whose tokens are burned.
     * @param _id Token id.
     * @param _value Amount to burn.
     */
    function burn(address _from, uint256 _id, uint256 _value) public virtual restricted nonReentrant whenPrivacyNodeActive {
        uint256 total = balanceOf(_from, _id);
        uint256 unlockedAmount = total - lockedForDvp[_from][_id];
        require(unlockedAmount >= _value, 'Not enough unlocked tokens for burn operation');

        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, _id, _value);
        _burn(_from, _id, _value);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).dvp1155Burn(resourceId, _from, _id, _value);
        }
    }

    /**
     * @notice OZ ERC1155 `_update` override — adds id to `_allTokenIds` on mint and blocks
     *         transfers/burns of tokens currently locked for Dvp.
     * @dev Reverts on self-transfer and when an account's unlocked balance is insufficient.
     * @param from Sender (zero on mint).
     * @param to Recipient (zero on burn).
     * @param ids Token ids being moved/minted/burned.
     * @param values Amounts paired with `ids`.
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal virtual override {
        require(to != from, 'Cannot transfer to self');

        for (uint256 i = 0; i < ids.length; i++) {
            if (from == address(0)) {
                // Minting token
                _allTokenIds.add(ids[i]);
            } else {
                // Transfering or burning token
                uint256 unlockedAmount = balanceOf(from, ids[i]) - lockedForDvp[from][ids[i]];
                require(unlockedAmount >= values[i], 'Not enough unlocked tokens for operation');
            }
        }

        super._update(from, to, ids, values);
    }

    /**
     * @notice Resolve the Enygma PN events contract address via the endpoint's resource registry.
     * @return Address of the contract bound to `RESOURCE_ID_ENYGMA_PN_EVENTS`.
     */
    function getEnygmaEventsAdress() public view virtual returns (address) {
        return endpoint.getAddressByResourceId(Constants.RESOURCE_ID_ENYGMA_PN_EVENTS);
    }

    /**
     * @notice Resolve the PN communicator contract address via the endpoint's resource registry.
     * @return Address of the contract bound to `RESOURCE_ID_PN_COMMUNICATOR`.
     */
    function getPNCommunicatorAddress() public view virtual returns (address) {
        return endpoint.getAddressByResourceId(Constants.RESOURCE_ID_PN_COMMUNICATOR);
    }

    /**
     * @notice Deposit tokens of an id into Dvp escrow.
     * @dev Reverts unless the token is registered, exists, and caller has enough unlocked balance.
     *      Increments `lockedForDvp[msg.sender][_tokenId]`. Emits the deposit event.
     * @param _tokenId Token id to deposit.
     * @param _value Amount to deposit.
     * @param _data Additional data forwarded to the deposit event.
     */
    function depositIntoDvp(uint256 _tokenId, uint256 _value, bytes memory _data) public virtual nonReentrant whenHubActive {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_allTokenIds.contains(_tokenId), 'Token does not exist');
        uint256 remainingUnlockedAmount = balanceOf(msg.sender, _tokenId) -
            lockedForDvp[msg.sender][_tokenId];
        require(
            remainingUnlockedAmount >= _value,
            'Not enough unlocked tokens to deposit into Dvp'
        );

        lockedForDvp[msg.sender][_tokenId] += _value; // Lock the tokens for DVP

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp1155DepositIntoDvp(
            resourceId,
            _tokenId,
            msg.sender,
            _value,
            _data
        );
    }

    /**
     * @dev Notifies the swap status to both chains
     * @param _sharedId The shared ID of the swap
     * @param _destinationChainId The ID of the destination chain
     */
    function _notifySwapStatus(bytes32 _sharedId, uint256 _destinationChainId) internal {
        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(SharedObjects.DvpCommunicatiorStatus.Swap1155ForEnygmaSent),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            ''
        );

        _raylsSendToResourceId(
            _destinationChainId,
            Constants.RESOURCE_ID_PN_COMMUNICATOR,
            abi.encodeWithSignature(
                'addSharedInfo(bytes32,uint256,uint256,string)',
                _sharedId,
                uint256(SharedObjects.DvpCommunicatiorStatus.Swap1155ForEnygmaReceived),
                uint256(SharedObjects.CommunicatiorContexts.Dvp),
                ''
            )
        );
    }

    /**
     * @notice Internal helper: submit a burn balance-update, burn locally, clear extra-data,
     *         and emit the burn event on the Enygma PN events contract.
     * @param _from Account whose tokens are burned.
     * @param _tokenId Token id.
     * @param _value Amount to burn.
     */
    function _handleTokenBurn(address _from, uint256 _tokenId, uint256 _value) internal {
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, _tokenId, _value);
        _burn(_from, _tokenId, _value);

        if (_tokenData[_tokenId].extraData.length > 0) {
            delete _tokenData[_tokenId].extraData;
        }

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).dvp1155Burn(
                resourceId,
                _from,
                _tokenId,
                _value
            );
        }
    }

    /**
     * @notice Swap ERC1155 tokens for Enygma tokens through Dvp.
     * @dev Emits the swap request and notifies the sender/receiver PN communicators.
     * @param _tokenId The ID of the token to swap
     * @param _tokenValue The amount of tokens to swap
     * @param tokenDataParam Additional data for the token swap
     * @param _enygmaAmount The amount of Enygma tokens to receive
     * @param _enygmaResourceId The resource ID for Enygma tokens
     * @param _destChainId The ID of the destination chain
     * @param _sharedId The shared ID for the swap
     * @param _validityTime Optional swap validity time in seconds; zero uses the default.
     */
    function swapWithDvpForEnygma(
        uint256 _tokenId,
        uint256 _tokenValue,
        bytes memory tokenDataParam,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public virtual nonReentrant whenHubActive {
        if (_validityTime > 0) {
            if (
                _validityTime <= Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME ||
                _validityTime >= Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
            ) {
                revert RaylsErc1155DvpHandler__SwapValidityOutOfRange(
                    _validityTime,
                    Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                    Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
                );
            }
        } else {
            _validityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        }

        require(resourceId != bytes32(0), 'Token not approved.');
        require(_allTokenIds.contains(_tokenId), 'Token does not exist');
        require(
            lockedForDvp[msg.sender][_tokenId] >= _tokenValue,
            'Not enough tokens locked to Dvp'
        );

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp1155SwapForEnygma(
            resourceId,
            _tokenId,
            _tokenValue,
            tokenDataParam,
            _enygmaAmount,
            _enygmaResourceId,
            _msgSender(),
            _destChainId,
            _sharedId,
            _validityTime
        );

        _notifySwapStatus(_sharedId, _destChainId);
    }

    /**
     * @notice Cancel a Dvp swap initiated by the caller.
     * @dev Caller must have at least `_tokenValue` locked into Dvp for `_tokenId`.
     * @param _sharedId Shared id of the swap to cancel.
     * @param _toChainId Destination chain id of the original swap.
     * @param _tokenId Token id of the multi-token side.
     * @param _tokenValue Amount of the multi-token side.
     * @param _enygmaResourceId Resource id of the Enygma token.
     * @param _enygmaAmount Enygma amount of the original swap.
     */
    function cancelSwap(
        bytes32 _sharedId,
        uint256 _toChainId,
        uint256 _tokenId,
        uint256 _tokenValue,
        bytes32 _enygmaResourceId,
        uint256 _enygmaAmount
    ) public virtual nonReentrant whenHubActive {
        require(lockedForDvp[msg.sender][_tokenId] >= _tokenValue, 'Not enough tokens locked in Dvp by sender');
        IEnygmaPNEvents(getEnygmaEventsAdress()).cancelSwap(_sharedId, _toChainId, resourceId, _tokenValue, _tokenId, SharedObjects.ErcStandard.DvpERC1155, _enygmaResourceId, _enygmaAmount, 0, SharedObjects.ErcStandard.Enygma);
    }

    /**
     * @notice Initiate withdrawal of tokens from Dvp escrow (off-chain confirmation step).
     * @dev Caller must have at least `_value` locked into Dvp for `_tokenId`. Increments
     *      `readyForUnlockForDvp`. The actual unlock happens in `unlockFromDvp`.
     * @param _tokenId Token id to withdraw.
     * @param _value Amount to mark ready-for-unlock.
     * @param data Additional data forwarded with the withdraw event.
     */
    function withdrawFromDvp(uint256 _tokenId, uint256 _value, bytes memory data) public virtual nonReentrant whenHubActive {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_allTokenIds.contains(_tokenId), 'Token does not exist');
        require(
            lockedForDvp[msg.sender][_tokenId] >= _value,
            'Not enough tokens locked in Dvp'
        );

        readyForUnlockForDvp[msg.sender][_tokenId] += _value;

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp1155WithdrawFromDvp(
            resourceId,
            _tokenId,
            _value,
            data,
            msg.sender
        );
    }

    /**
     * @notice Finalize the unlock of tokens after `withdrawFromDvp` was acknowledged off-chain.
     * @dev Restricted to RELAYER. Decrements both `lockedForDvp` and `readyForUnlockForDvp`.
     * @param _tokenId Token id to unlock.
     * @param _value Amount to unlock.
     * @param _to Account whose Dvp lock is being released.
     */
    function unlockFromDvp(uint256 _tokenId, uint256 _value, address _to) public virtual restricted nonReentrant whenHubActive {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_allTokenIds.contains(_tokenId), 'Token does not exist');
        require(lockedForDvp[_to][_tokenId] >= _value, 'Not enough tokens locked in Dvp');
        require(
            readyForUnlockForDvp[_to][_tokenId] >= _value,
            'Not enough tokens ready for unlock'
        );

        lockedForDvp[_to][_tokenId] -= _value;
        readyForUnlockForDvp[_to][_tokenId] -= _value;
    }

    /**
     * @notice Read the Dvp1155 extra-data records associated with a token id.
     * @param _tokenId Token id queried.
     * @return Array of `Dvp1155ExtraData` records.
     */
    function getTokenExtraData(
        uint256 _tokenId
    ) public view virtual returns (SharedObjects.Dvp1155ExtraData[] memory) {
        return tokenExtraData[_tokenId];
    }

    /**
     * @notice Encode the destination-side `MintFromSwapDvp` call dispatched after a successful
     *         Dvp swap.
     * @param _tokenId Token id to mint on destination.
     * @param _destinationOwner Recipient on destination.
     * @param _value Amount to mint.
     * @param data Additional data forwarded to ERC1155 hooks on destination.
     * @param extraData Dvp1155 extra-data carried over from the source chain.
     * @return Encoded calldata.
     */
    function _prepareMintFromSwapPayload(
        uint256 _tokenId,
        address _destinationOwner,
        uint256 _value,
        bytes memory data,
        SharedObjects.Dvp1155ExtraData[] memory extraData
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                this.MintFromSwapDvp.selector,
                _tokenId,
                _destinationOwner,
                _value,
                data,
                extraData
            );
    }

    /**
     * @notice Handle completion of a Dvp swap: dispatch a `MintFromSwapDvp` to the destination
     *         chain, burn the local tokens, and post status to the local PN communicator.
     * @dev Restricted to RELAYER. Validates the lock, decrements it, mints cross-chain, then
     *      burns locally.
     * @param params Swap-completion parameters:
     *               - tokenId: id of the multi-token side.
     *               - destinationChainId: chain id where tokens are re-minted.
     *               - destinationOwner: recipient on destination.
     *               - sharedId: shared id correlating the swap.
     * @param from Original sender holding the Dvp lock.
     * @param _value Amount being moved.
     * @param data Additional data forwarded to the destination mint.
     */
    function dvpSwapCompleted(
        SharedObjects.DvpSwapCompletedParams memory params,
        address from,
        uint256 _value,
        bytes memory data
    ) public virtual restricted nonReentrant whenHubActive {
        _validateDvpToken(from, params.tokenId, _value);

        lockedForDvp[from][params.tokenId] -= _value;

        BridgedTransferMetadata memory emptyMetadata;

        bytes memory payload = _prepareMintFromSwapPayload(
            params.tokenId,
            params.destinationOwner,
            _value,
            data,
            tokenExtraData[params.tokenId]
        );

        _raylsSendToResourceId(
            params.destinationChainId,
            resourceId,
            payload,
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );

        _burn(from, params.tokenId, _value);

        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            params.sharedId,
            uint256(SharedObjects.DvpCommunicatiorStatus.SwapDoneReadyForWithdraw),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            ''
        );
    }

    /**
     * @notice Mint tokens on the destination chain from a completed Dvp swap.
     * @dev Restricted to MESSAGE_EXECUTOR. Persists extra-data on first arrival of a token
     *      id; subsequently increments `lockedForDvp` for the destination owner so the
     *      counterpart unlock flow remains symmetric.
     * @param _tokenId Token id to mint on this chain.
     * @param _destinationOwner Recipient (the swap counterparty).
     * @param _value Amount to mint.
     * @param data Additional data forwarded to ERC1155 hooks.
     * @param _extraDatas Dvp1155 extra-data records carried from the source chain.
     */
    function MintFromSwapDvp(
        uint256 _tokenId,
        address _destinationOwner,
        uint256 _value,
        bytes memory data,
        SharedObjects.Dvp1155ExtraData[] memory _extraDatas
    ) public virtual restricted nonReentrant whenHubActive {
        _mint(_destinationOwner, _tokenId, _value, data);

        if (_tokenData[_tokenId].extraData.length == 0) {
            for (uint256 i = 0; i < _extraDatas.length; i++) {
                _tokenData[_tokenId].extraData.push(_extraDatas[i]);
            }
        }

        lockedForDvp[_destinationOwner][_tokenId] += _value;
    }

    /**
     * @notice Read the Dvp extra-data records associated with a token id (alternative accessor).
     * @param _tokenId Token id queried.
     * @return Array of `Dvp1155ExtraData` records from `_tokenData`.
     */
    function getNftExtradaData(
        uint256 _tokenId
    ) public view virtual returns (SharedObjects.Dvp1155ExtraData[] memory) {
        return _tokenData[_tokenId].extraData;
    }


    /**
     * @notice Post a Dvp status update to the local PN communicator.
     * @dev Restricted to RELAYER.
     * @param _sharedId Shared id correlating the operation.
     * @param _status Status code to record.
     * @param _message Free-form message attached to the status update.
     */
    function notifySenderWithPNCommunicator(
        bytes32 _sharedId,
        SharedObjects.DvpCommunicatiorStatus _status,
        string memory _message
    ) public virtual restricted nonReentrant {
        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(_status),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            _message
        );
    }

    /**
     * @notice Post a Dvp status update locally AND dispatch a status update to the destination
     *         PN communicator.
     * @dev Restricted to RELAYER.
     * @param _sharedId Shared id correlating the operation.
     * @param _destChainId Destination chain id receiving the status update.
     * @param _statusToSender Status code to record locally for the sender.
     * @param _statusToReceiver Status code to dispatch to the receiver.
     * @param _messageToSender Free-form message for the sender side.
     * @param _messageToReceiver Free-form message for the receiver side.
     */
    function notifySenderAndReceiverWithPNCommunicator(
        bytes32 _sharedId,
        uint256 _destChainId,
        SharedObjects.DvpCommunicatiorStatus _statusToSender,
        SharedObjects.DvpCommunicatiorStatus _statusToReceiver,
        string memory _messageToSender,
        string memory _messageToReceiver
    ) public virtual restricted nonReentrant {
        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(_statusToSender),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            _messageToSender
        );

        _raylsSendToResourceId(
            _destChainId,
            Constants.RESOURCE_ID_PN_COMMUNICATOR,
            abi.encodeWithSignature(
                'addSharedInfo(bytes32,uint256,uint256,string)',
                _sharedId,
                uint256(_statusToReceiver),
                uint256(SharedObjects.CommunicatiorContexts.Dvp),
                _messageToReceiver
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL REGISTRATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Register this token with the local AccessManager via `selfRegisterManagedContract`.
     * @dev Wires owner-gated selectors (mint/burn/submitTokenUpdate/setSwapValidityTime),
     *      RELAYER-gated selectors (unlockFromDvp + dvpSwapCompleted + notify*), and
     *      MESSAGE_EXECUTOR-gated selectors (unlock + MintFromSwapDvp).
     *      No-op when no AccessManager is bound.
     * @param _owner Address that becomes owner of the owner-gated selectors.
     * @param caller The external deployer (factory's `msg.sender`); when non-zero and distinct
     *               from `_owner`, also granted TOKEN_OWNER scoped to this token. `address(0)`
     *               on the constructor path.
     */
    function _registerAccessControl(address _owner, address caller) internal {
        address mgr = address(endpoint) != address(0) ? endpoint.authority() : address(0);
        if (mgr == address(0)) return;

        _setAuthority(mgr);

        bytes4[] memory ownerSels = new bytes4[](4);
        ownerSels[0] = this.mint.selector;
        ownerSels[1] = this.burn.selector;
        ownerSels[2] = this.submitTokenUpdate.selector;
        ownerSels[3] = this.setSwapValidityTime.selector;

        bytes4[] memory relayerSels = new bytes4[](4);
        relayerSels[0] = this.unlockFromDvp.selector;
        relayerSels[1] = this.dvpSwapCompleted.selector;
        relayerSels[2] = this.notifySenderWithPNCommunicator.selector;
        relayerSels[3] = this.notifySenderAndReceiverWithPNCommunicator.selector;

        bytes4[] memory executorSels = new bytes4[](2);
        executorSels[0] = this.unlock.selector;
        executorSels[1] = this.MintFromSwapDvp.selector;

        IRaylsAccessManager.SelectorRoleMapping[] memory mappings = new IRaylsAccessManager.SelectorRoleMapping[](2);
        mappings[0] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);
        mappings[1] = IRaylsAccessManager.SelectorRoleMapping("MESSAGE_EXECUTOR", executorSels);

        IRaylsAccessManager(mgr).selfRegisterManagedContract(_owner, ownerSels, mappings);

        // Also grant TOKEN_OWNER to the deployer when it differs from the configured owner
        // (factory path where `owner` is factoryOwner but the deployer is a distinct caller).
        if (caller != address(0) && caller != _owner) {
            IRaylsAccessManager(mgr).grantSelfTokenOwner(caller);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsApp} from '../RaylsApp.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import '@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol';

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
 * @title RaylsErc721DvpHandler
 * @notice ERC721 base for Rayls NFTs participating in Zero-Knowledge Delivery vs Payment.
 *         Adds per-token deposit-into-Dvp / withdraw-from-Dvp + ZK swap with Enygma + state
 *         tracking (`lockedForDvp`, `readyForUnlockForDvp`) and cross-chain mint after a
 *         successful swap.
 * @dev Inherits ERC721 + Initializable + ReentrancyGuard + RaylsAccessManaged. Owner-gated
 *      selectors: mint, burn, submitTokenUpdate, setSwapValidityTime. RELAYER-gated:
 *      unlockFromDvp, dvpSwapCompleted, notifySenderWithPNCommunicator,
 *      notifySenderAndReceiverWithPNCommunicator. MESSAGE_EXECUTOR-gated: unlock,
 *      MintFromSwapDvp. ReentrancyGuard guards every external mutation.
 */

abstract contract RaylsErc721DvpHandler is RaylsApp, ERC721, Initializable, ReentrancyGuard, RaylsAccessManaged, IRaylsTokenStandard {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    /// @notice Thrown when an Enygma DvP swap validity time falls outside
    ///         `[ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME + 1, ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME - 1]`.
    /// @param provided Caller-supplied validity time.
    /// @param min Minimum allowed validity time (exclusive).
    /// @param max Maximum allowed validity time (exclusive).
    error RaylsErc721DvpHandler__SwapValidityOutOfRange(uint64 provided, uint64 min, uint64 max);

    /// @notice Thrown when the token's resourceId has not yet been approved/registered.
    error RaylsErc721DvpHandler__TokenNotApproved();

    /// @notice Thrown when the requested token id does not exist in this contract.
    /// @param tokenId The token id that was not found.
    error RaylsErc721DvpHandler__TokenDoesNotExist(uint256 tokenId);

    /// @notice Base URI for token metadata
    string private _uri;
    /// @notice Name of the token
    string public _tokenName;
    /// @notice Symbol of the token
    string public _tokenSymbol;
    /// @notice Flag indicating if this is a custom token implementation
    bool isCustom;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event TokenLocked(address indexed account, uint256 indexed tokenId);
    event TokenUnlocked(address indexed account, uint256 indexed tokenId);
    /// @notice Emitted when this ERC721 DVP token contract is created and initialized
    /// @param tokenAddress The address of the newly created token contract
    event RaylsErc721DvpTokenCreated(address indexed tokenAddress);

    /// @notice Mapping to track locked tokens per account and token ID
    mapping(address => mapping(uint256 => bool)) lockedTokens;

    // Supply tracking
    /// @notice Mapping to track if a token ID exists
    mapping(uint256 => bool) internal _exists;
    /// @notice Array of all token IDs
    uint256[] internal _allTokens;
    /// @notice Array of token IDs in the protocol layer
    uint256[] internal _pnTokens;

    /// @notice Mapping to track tokens locked for Dvp operations
    mapping(uint256 => bool) public lockedForDvp;
    /// @notice Mapping to track tokens ready for unlock from Dvp
    mapping(uint256 => bool) readyForUnlockForDvp;

    /// @notice Mapping to store extra data for each NFT
    mapping(uint256 => SharedObjects.Dvp721ExtraData[]) internal nftExtraData;

    /// @notice Validity time for Enygma DvP swaps in seconds.
    uint64 public swapValidityTime;

    /**
     * @notice Construct the handler with ERC721 metadata + trusted endpoint references.
     * @dev `_disableInitializers()` blocks the upgradeable initialize path on the implementation.
     * @param uri Base URI for token metadata.
     * @param name_ Token name.
     * @param symbol_ Token symbol.
     * @param _endpoint Trusted Rayls endpoint address.
     * @param _raylsNodeEndpoint Privacy-node endpoint; zero on PNH deploys.
     * @param _userGovernance UserGovernance binding; zero when unused.
     * @param _owner Address that receives owner-gated selectors.
     * @param _isCustom True for custom-token issuer flow; false for the standard template path.
     */
    constructor(
        string memory uri,
        string memory name_,
        string memory symbol_,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance,
        address _owner,
        bool _isCustom
    )
        ERC721(name_, symbol_)
        RaylsApp(_endpoint, _raylsNodeEndpoint, _userGovernance)
    {
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _uri = uri;
        isCustom = _isCustom;
        swapValidityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        _registerAccessControl(_owner, address(0));
        _disableInitializers();
    }

    /// @notice Canonical init entrypoint dispatched by RaylsContractFactoryV1.
    /// @param userArgs ABI-encoded `(string uri, string name, string symbol)`.
    ///                 Caller-supplied via the cross-chain init payload.
    /// @param trusted  Trusted addresses + resourceId from {RaylsTrustedInit}, set by the
    ///                 factory at deploy time. Caller cannot forge.
    function initialize(bytes calldata userArgs, RaylsTrustedInit calldata trusted) public virtual initializer {
        (string memory uri, string memory name_, string memory symbol_) =
            abi.decode(userArgs, (string, string, string));

        // ERC721 initialization
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _uri = uri;

        // RaylsApp initialization (trusted addresses from factory-injected struct)
        endpoint = IRaylsEndpoint(trusted.endpoint);
        resourceId = trusted.resourceId;
        _registerAccessControl(trusted.owner, trusted.caller);
        emit RaylsErc721DvpTokenCreated(address(this));
    }

    /**
     * @notice Returns the ERC standard tag identifying this token shape.
     * @return The `SharedObjects.ErcStandard.DvpERC721` enum value.
     */
    function GetERCStandard() public pure virtual override returns (SharedObjects.ErcStandard) {
        return SharedObjects.ErcStandard.DvpERC721;
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
            revert RaylsErc721DvpHandler__SwapValidityOutOfRange(
                _validityTime,
                Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
            );
        }
        swapValidityTime = _validityTime;
    }

    /**
     * @notice Returns the token name. Overrides ERC721 to read from initializer-set storage.
     * @return Token name string.
     */
    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    /**
     * @notice Returns the token symbol. Overrides ERC721 to read from initializer-set storage.
     * @return Token symbol string.
     */
    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }

    /**
     * @notice Internal hook returning the base URI for ERC721 metadata.
     * @return Base URI string.
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _uri;
    }

    /**
     * @notice External accessor that returns the base URI for ERC721 metadata.
     * @return Base URI string.
     */
    function baseUri() public view virtual returns (string memory) {
        return _baseURI();
    }

    /**
     * @notice Approve an operator only while this token is active on the local Privacy Node.
     * @param to Account approved to manage `tokenId`.
     * @param tokenId Token id whose approval is updated.
     */
    function approve(address to, uint256 tokenId) public virtual override whenPrivacyNodeActive {
        super.approve(to, tokenId);
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
     * @notice Transfer an NFT only while this token is active on the local Privacy Node.
     * @param from Current token owner.
     * @param to Recipient address.
     * @param tokenId Token id to transfer.
     */
    function transferFrom(address from, address to, uint256 tokenId) public virtual override whenPrivacyNodeActive {
        super.transferFrom(from, to, tokenId);
    }

    /**
     * @notice Safely transfer an NFT only while this token is active on the local Privacy Node.
     * @param from Current token owner.
     * @param to Recipient address.
     * @param tokenId Token id to transfer.
     * @param data Additional data forwarded to the receiver hook.
     */
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public virtual override whenPrivacyNodeActive {
        super.safeTransferFrom(from, to, tokenId, data);
    }

    /**
     * @notice Unlock a token previously held in the contract pool and transfer it to `to`.
     * @dev Restricted to MESSAGE_EXECUTOR. If `to` is this contract, no transfer is issued.
     * @param to Recipient.
     * @param id Token id to unlock.
     * @return Always true on success; reverts otherwise.
     */
    function unlock(address to, uint256 id) external restricted nonReentrant whenHubActive returns (bool) {
        if (to != address(this)) {
            bool success = _unlock(to, id);
            require(success, 'cannot unlock the assets');
            _safeTransfer(address(this), to, id);
        }
        return true;
    }

    /**
     * @notice Internal lock primitive: marks a token as locked for an account.
     * @dev Reverts on zero `to`. Caller is responsible for any token transfer.
     * @param to Account whose token is being locked.
     * @param id Token id to lock.
     */
    function _lock(address to, uint256 id) internal {
        require(to != address(0));
        lockedTokens[to][id] = true;
        emit TokenLocked(to, id);
    }

    /**
     * @notice Internal unlock primitive: clears the locked flag for an account/token pair.
     * @dev Reverts on zero `to` or when no lock is recorded.
     * @param to Account whose lock is being released.
     * @param id Token id to unlock.
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
     * @dev No-op when `resourceId` is unset (token not yet activated).
     * @param updateType MINT or BURN classification.
     * @param tokenId Token id changed.
     */
    function _submitTokenUpdate(
        SharedObjects.BalanceUpdateType updateType,
        uint256 tokenId
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
                abi.encode(tokenId)
            )
        );
    }

    /**
     * @notice Validate a token is eligible for Dvp operations.
     * @dev Reverts unless the token is registered, exists, AND is currently locked for Dvp.
     * @param _tokenId Token id under inspection.
     */
    function _validateDvpToken(uint256 _tokenId) internal view {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_tokenId], 'Token does not exist');
        require(lockedForDvp[_tokenId] == true, 'This token is not deposited into Dvp');
    }

    /**
     * @notice Submit a mint/burn update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers.
     * @param updateType MINT or BURN classification.
     * @param tokenId Token id changed.
     */
    function submitTokenUpdate(
        SharedObjects.BalanceUpdateType updateType,
        uint256 tokenId
    ) public virtual restricted {
        _submitTokenUpdate(updateType, tokenId);
    }

    /**
     * @notice Read the list of all currently-existing token ids.
     * @dev Maintained by `_update`. Private; subclass exposure via `getTotalSupply`.
     * @return Array of every token id with `_exists[id] == true`.
     */
    function totalSupply() private view returns (uint256[] memory) {
        return _allTokens;
    }

    /**
     * @notice External view of the contract's existing token ids (post-approval).
     * @return Array of every token id with `_exists[id] == true`.
     */
    function getTotalSupply() public view virtual returns (uint256[] memory) {
        return totalSupply();
    }

    /**
     * @notice External view of token ids minted directly on this PN layer (not via cross-chain swap).
     * @return Array of token ids tracked in `_pnTokens`.
     */
    function getTotalSupplyAtPN() public view virtual returns (uint256[] memory) {
        return _pnTokens;
    }

    /**
     * @notice Mint a new NFT with optional Dvp extra-data records.
     * @dev Restricted to owner-gated callers. Pushes the id into `_pnTokens` and submits a
     *      mint balance-update to the PNH TokenRegistry. Emits a Dvp721Mint event when active.
     * @param _to Recipient.
     * @param _id Token id to mint.
     * @param _extraDatas Optional Dvp721 extra-data records persisted alongside the NFT.
     */
    function mint(
        address _to,
        uint256 _id,
        SharedObjects.Dvp721ExtraData[] memory _extraDatas
    ) public virtual restricted nonReentrant whenPrivacyNodeActive {
        _safeMint(_to, _id);

        _pnTokens.push(_id);
        _submitTokenUpdate(SharedObjects.BalanceUpdateType.MINT, _id);

        for (uint256 i = 0; i < _extraDatas.length; i++) {
            nftExtraData[_id].push(_extraDatas[i]);
        }

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721Mint(resourceId, _id);
        }
    }

    /**
     * @notice Burn an NFT and submit a burn balance-update to the PNH TokenRegistry.
     * @dev Restricted to owner-gated callers. Reverts if the token is currently locked for Dvp.
     *      Emits a Dvp721Burn event when active.
     * @param _id Token id to burn.
     */
    function burn(uint256 _id) public virtual restricted nonReentrant whenPrivacyNodeActive {
        require(lockedForDvp[_id] == false, 'NFT is locked for Dvp');

        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, _id);
        _burn(_id);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721Burn(resourceId, _id);
        }
    }

    /**
     * @notice OZ ERC721 `_update` override — maintains `_exists` + `_allTokens` AND blocks
     *         transfers of tokens currently locked for Dvp (unless they're explicitly ready
     *         to unlock).
     * @dev On mint (previousOwner == 0): record existence and reset Dvp flags. On burn
     *      (to == 0): clear existence and swap-pop the id out of `_allTokens`.
     * @param to New owner (zero on burn).
     * @param tokenId Token id being moved/minted/burned.
     * @param auth Caller authority (OZ ERC721 internal mechanic).
     * @return previousOwner Owner before the update (zero on mint).
     */
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal virtual override returns (address) {
        // First check if the 721 is locked in the dvp
        if (lockedForDvp[tokenId] == true) {
            require(readyForUnlockForDvp[tokenId] == true, 'This token is locked in the Dvp');
        }

        address previousOwner = super._update(to, tokenId, auth);

        // Minting token
        if (previousOwner == address(0)) {
            if (!_exists[tokenId]) {
                _allTokens.push(tokenId);
                _exists[tokenId] = true;
                lockedForDvp[tokenId] = false;
                readyForUnlockForDvp[tokenId] = false;
            }
        }

        // Burning token
        if (to == address(0)) {
            _exists[tokenId] = false;
            // Remove the id from _allTokens array
            for (uint256 i = 0; i < _allTokens.length; i++) {
                if (_allTokens[i] == tokenId) {
                    _allTokens[i] = _allTokens[_allTokens.length - 1];
                    _allTokens.pop();
                    break;
                }
            }
        }

        return previousOwner;
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
     * @notice Deposit an NFT into Dvp escrow.
     * @dev Reverts unless caller owns the token, the token is registered, exists, and is not
     *      already locked for Dvp. Emits the deposit event on the Enygma PN events contract.
     * @param _tokenId Token id to deposit.
     */
    function depositIntoDvp(uint256 _tokenId) public virtual nonReentrant whenHubActive {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_tokenId], 'Token does not exist');
        require(lockedForDvp[_tokenId] == false, 'Already deposited into Dvp');
        require(ownerOf(_tokenId) == msg.sender, 'Token not owned by the sender');

        lockedForDvp[_tokenId] = true;

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721DepositIntoDvp(
            resourceId,
            _tokenId,
            msg.sender
        );
    }

    /**
     * @notice Swap an NFT for Enygma tokens through Dvp.
     * @dev Emits the swap request and notifies the sender/receiver PN communicators.
     * @param _nftId ID of the NFT to swap
     * @param _enygmaAmount Amount of Enygma tokens to receive
     * @param _enygmaResourceId Resource ID of the Enygma token
     * @param _destChainId Destination chain ID
     * @param _sharedId Shared ID for the swap operation
     * @param _validityTime Optional swap validity time in seconds; zero uses the default.
     */
    function swapWithDvpForEnygma(
        uint256 _nftId,
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
                revert RaylsErc721DvpHandler__SwapValidityOutOfRange(
                    _validityTime,
                    Utils.ENYGMA_DVP_SWAP_MIN_VALIDITY_TIME,
                    Utils.ENYGMA_DVP_SWAP_MAX_VALIDITY_TIME
                );
            }
        } else {
            _validityTime = Utils.ENYGMA_DVP_SWAP_DEFAULT_VALIDITY_TIME;
        }

        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_nftId], 'Token does not exist');
        require(lockedForDvp[_nftId] == true, 'NFT not deposited into Dvp');
        require(ownerOf(_nftId) == msg.sender, 'Token not owned by the sender');

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721SwapForEnygma(
            resourceId,
            _nftId,
            _enygmaAmount,
            _enygmaResourceId,
            _msgSender(),
            _destChainId,
            _sharedId,
            _validityTime
        );

        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            _sharedId,
            uint256(SharedObjects.DvpCommunicatiorStatus.Swap721ForEnygmaSent),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            ''
        );

        _raylsSendToResourceId(
            _destChainId,
            Constants.RESOURCE_ID_PN_COMMUNICATOR,
            abi.encodeWithSignature(
                'addSharedInfo(bytes32,uint256,uint256,string)',
                _sharedId,
                uint256(SharedObjects.DvpCommunicatiorStatus.Swap721ForEnygmaReceived),
                uint256(SharedObjects.CommunicatiorContexts.Dvp),
                ''
            )
        );
    }

    /**
     * @notice Cancel a Dvp swap initiated by the caller.
     * @dev Caller must own the NFT side of the swap. Emits the cancel event on the Enygma
     *      PN events contract.
     * @param _sharedId Shared id of the swap to cancel.
     * @param _toChainId Destination chain id of the original swap.
     * @param _nftId Token id of the NFT side.
     * @param _enygmaAmount Enygma amount of the original swap.
     * @param _enygmaResourceId Resource id of the Enygma token.
     */
    function cancelSwap(
        bytes32 _sharedId,
        uint256 _toChainId,
        uint256 _nftId,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId
    ) public virtual nonReentrant whenHubActive {
        require(ownerOf(_nftId) == msg.sender, 'Token not owned by the sender');
        IEnygmaPNEvents(getEnygmaEventsAdress()).cancelSwap(_sharedId, _toChainId, resourceId, 1, _nftId, SharedObjects.ErcStandard.DvpERC721, _enygmaResourceId, _enygmaAmount, 0, SharedObjects.ErcStandard.Enygma);
    }

    /**
     * @notice Initiate withdrawal of an NFT from Dvp escrow (off-chain confirmation step).
     * @dev Caller must own the token; token must be registered, exist, and be locked for Dvp.
     *      Marks the token as ready-for-unlock; the actual unlock happens in `unlockFromDvp`.
     * @param _tokenId Token id to withdraw.
     */
    function withdrawFromDvp(uint256 _tokenId) public virtual nonReentrant whenHubActive {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_tokenId], 'Token does not exist');
        require(lockedForDvp[_tokenId] == true, 'This token is not deposited into Dvp');
        require(ownerOf(_tokenId) == msg.sender, 'Token not owned by the sender');

        readyForUnlockForDvp[_tokenId] = true;

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721WithdrawFromDvp(
            resourceId,
            _tokenId,
            msg.sender
        );
    }

    /**
     * @notice Finalize the unlock of an NFT after `withdrawFromDvp` was acknowledged off-chain.
     * @dev Restricted to RELAYER. Reverts unless the token is registered, exists, locked for
     *      Dvp, AND ready-for-unlock. Clears both Dvp flags.
     * @param _tokenId Token id to unlock.
     */
    function unlockFromDvp(uint256 _tokenId) public virtual restricted nonReentrant whenHubActive {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_tokenId], 'Token does not exist');
        require(lockedForDvp[_tokenId] == true, 'This token is not deposited into Dvp');
        require(readyForUnlockForDvp[_tokenId] == true, 'This token is not ready for unlock');

        lockedForDvp[_tokenId] = false;
        readyForUnlockForDvp[_tokenId] = false;
    }

    /**
     * @notice Read the Dvp extra-data records associated with an NFT.
     * @param _tokenId Token id queried.
     * @return Array of `Dvp721ExtraData` records persisted alongside the token.
     */
    function getNftExtradaData(
        uint256 _tokenId
    ) public view virtual returns (SharedObjects.Dvp721ExtraData[] memory) {
        return nftExtraData[_tokenId];
    }

    /**
     * @notice Handle completion of a Dvp swap: dispatch a `MintFromSwapDvp` to the destination
     *         chain, burn the local NFT, and post status to the local PN communicator.
     * @dev Restricted to RELAYER. Validates the token is in Dvp, then unlocks, mints
     *      cross-chain, and burns locally. Cleans up `nftExtraData` and `_pnTokens`.
     * @param params Swap-completion parameters:
     *               - tokenId: NFT involved in the swap.
     *               - destinationChainId: Chain id where the NFT is re-minted.
     *               - destinationOwner: Recipient on the destination chain.
     *               - sharedId: Shared id correlating the swap.
     */
    function dvpSwapCompleted(
        SharedObjects.DvpSwapCompletedParams calldata params
    ) public virtual restricted nonReentrant whenHubActive {
        _validateDvpToken(params.tokenId);

        lockedForDvp[params.tokenId] = false;

        BridgedTransferMetadata memory emptyMetadata;

        _raylsSendToResourceId(
            params.destinationChainId,
            resourceId,
            abi.encodeWithSelector(
                this.MintFromSwapDvp.selector,
                params.tokenId,
                params.destinationOwner,
                nftExtraData[params.tokenId]
            ),
            bytes(''),
            bytes(''),
            bytes(''),
            emptyMetadata
        );

        _burn(params.tokenId);

        if (nftExtraData[params.tokenId].length > 0) {
            delete nftExtraData[params.tokenId];
        }

        for (uint256 i = 0; i < _pnTokens.length; i++) {
            if (_pnTokens[i] == params.tokenId) {
                _pnTokens[i] = _pnTokens[_pnTokens.length - 1];
                _pnTokens.pop();
                break;
            }
        }

        IPNCommunicator(getPNCommunicatorAddress()).addSharedInfo(
            params.sharedId,
            uint256(SharedObjects.DvpCommunicatiorStatus.SwapDoneReadyForWithdraw),
            uint256(SharedObjects.CommunicatiorContexts.Dvp),
            ''
        );
    }

    /**
     * @notice Mint an NFT on the destination chain from a completed Dvp swap.
     * @dev Restricted to MESSAGE_EXECUTOR. Records `_pnTokens`, persists extra-data, and
     *      marks the token as locked for Dvp on the receive side.
     * @param _tokenId Token id to mint on this chain.
     * @param _destinationOwner Recipient (the swap counterparty).
     * @param _extraDatas Dvp721 extra-data records carried over from the source chain.
     */
    function MintFromSwapDvp(
        uint256 _tokenId,
        address _destinationOwner,
        SharedObjects.Dvp721ExtraData[] memory _extraDatas
    ) public virtual restricted nonReentrant whenHubActive {
        _safeMint(_destinationOwner, _tokenId);

        _pnTokens.push(_tokenId);

        for (uint256 i = 0; i < _extraDatas.length; i++) {
            nftExtraData[_tokenId].push(_extraDatas[i]);
        }

        lockedForDvp[_tokenId] = true;
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

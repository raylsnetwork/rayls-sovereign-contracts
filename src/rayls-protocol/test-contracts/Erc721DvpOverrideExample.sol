// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import '../../rayls-protocol-sdk/libraries/Utils.sol';
import '../../rayls-protocol-sdk/tokens/RaylsErc721DvpHandler.sol';

contract Erc721DvpOverrideExample is RaylsErc721DvpHandler {
    constructor(
        string memory uri,
        string memory name_,
        string memory symbol_,
        address _endpoint,
        address _owner,
        bool _isCustom
    ) RaylsErc721DvpHandler(uri, name_, symbol_, _endpoint, address(0), address(0), _owner, _isCustom) {}

    // Override burn function to remove lockedForDvp check
    function burn(uint256 _id) public virtual override restricted {
        // Removed check: require(lockedForDvp[_id] == false, 'NFT is locked for Dvp');

        _submitTokenUpdate(SharedObjects.BalanceUpdateType.BURN, _id);
        _burn(_id);

        if (resourceId != bytes32(0)) {
            IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721Burn(resourceId, _id);
        }
    }

    // Override _update function to remove lockedForDvp and readyForUnlockForDvp checks
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        // Removed checks:
        // if (lockedForDvp[tokenId] == true) {
        //     require(readyForUnlockForDvp[tokenId] == true, 'This token is locked in the Dvp');
        // }

        address previousOwner = super._update(to, tokenId, auth);

        // Minting token
        if (previousOwner == address(0)) {
            if (!_exists[tokenId]) {
                _allTokens.push(tokenId);
                _exists[tokenId] = true;
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

    // Override depositIntoDvp function to remove lockedForDvp check and setting
    function depositIntoDvp(uint256 _tokenId) public virtual override {
        if (resourceId == bytes32(0)) revert RaylsErc721DvpHandler__TokenNotApproved();
        if (!_exists[_tokenId]) revert RaylsErc721DvpHandler__TokenDoesNotExist(_tokenId);
        // Removed check: require(lockedForDvp[_tokenId] == false, 'Already deposited into Dvp');

        // Removed setting: lockedForDvp[_tokenId] = true;

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721DepositIntoDvp(resourceId, _tokenId, msg.sender);
    }

    // Override swapWithDvpForEnygma function to remove lockedForDvp check
    function swapWithDvpForEnygma(
        uint256 _nftId,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public virtual override {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_nftId], 'Token does not exist');
        // Removed check: require(lockedForDvp[_nftId] == true, 'NFT not deposited into Dvp');

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

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721SwapForEnygma(resourceId, _nftId, _enygmaAmount, _enygmaResourceId, _msgSender(), _destChainId, _sharedId, _validityTime);

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

    // Override withdrawFromDvp function to remove lockedForDvp check and readyForUnlockForDvp setting
    function withdrawFromDvp(uint256 _tokenId) public virtual override {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_tokenId], 'Token does not exist');
        // Removed check: require(lockedForDvp[_tokenId] == true, 'This token is not deposited into Dvp');

        // Removed setting: readyForUnlockForDvp[_tokenId] = true;

        IEnygmaPNEvents(getEnygmaEventsAdress()).dvp721WithdrawFromDvp(resourceId, _tokenId, msg.sender);
    }

    // Override unlockFromDvp function to remove lockedForDvp and readyForUnlockForDvp checks and settings
    function unlockFromDvp(uint256 _tokenId) public virtual override restricted {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[_tokenId], 'Token does not exist');
        // Removed check: require(lockedForDvp[_tokenId] == true, 'This token is not deposited into Dvp');
        // Removed check: require(readyForUnlockForDvp[_tokenId] == true, 'This token is not ready for unlock');

        // Removed settings:
        // lockedForDvp[_tokenId] = false;
        // readyForUnlockForDvp[_tokenId] = false;
    }

    // Override dvpSwapCompleted function to remove lockedForDvp check and setting
    function dvpSwapCompleted(SharedObjects.DvpSwapCompletedParams calldata params) public virtual override restricted {
        require(resourceId != bytes32(0), 'Token not approved.');
        require(_exists[params.tokenId], 'Token does not exist');
        // Removed check: require(lockedForDvp[_tokenId] == true, 'This token is not deposited into Dvp');

        // Removed setting: lockedForDvp[_tokenId] = false;

        BridgedTransferMetadata memory emptyMetadata;

        _raylsSendToResourceId(
            params.destinationChainId,
            resourceId,
            abi.encodeWithSelector(this.MintFromSwapDvp.selector, params.tokenId, params.destinationOwner, nftExtraData[params.tokenId]),
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

    // Override MintFromSwapDvp function to remove lockedForDvp setting
    function MintFromSwapDvp(uint256 _tokenId, address _destinationOwner, SharedObjects.Dvp721ExtraData[] memory _extraDatas) public virtual override restricted {
        _mint(_destinationOwner, _tokenId);

        _pnTokens.push(_tokenId);

        for (uint256 i = 0; i < _extraDatas.length; i++) {
            nftExtraData[_tokenId].push(_extraDatas[i]);
        }

        // Removed setting: lockedForDvp[_tokenId] = true;
    }
}

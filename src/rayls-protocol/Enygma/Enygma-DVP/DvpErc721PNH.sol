// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import '../../../rayls-protocol-sdk/libraries/SharedObjects.sol';
import '../../interfaces/IEnygmaFactorySettings.sol';
import './Erc721CoinVaultCreator.sol';
import './DvpSettings.sol';
import '../../interfaces/IDvp.sol';

/// @notice PNH-side mirror of cross-chain DVP ERC721 NFTs. State-mutating
///         entrypoints (`mint`, `burn`, `UpdateInfosAfterDvpWithdraw`) are
///         gated by the named `RELAYER` role on `RaylsAccessManagerV1`.
///         Compromise of any account holding `RELAYER` is a system-wide
///         risk for every PNH-side mirror; provisioning, rotation and
///         revocation of that role must be treated accordingly.
contract DvpErc721PNH is ERC721, RaylsAccessManaged {
    string private _uri;
    string public _tokenName;
    string public _tokenSymbol;

    // Supply tracking
    mapping(uint256 => bool) private _exists;
    uint256[] private _allTokens;

    // TokenId to ChainId mapping
    mapping(uint256 => uint256) private _tokenIdToChainId;

    mapping(uint256 => SharedObjects.Dvp721ExtraData[]) private nftExtraData;

    // Dvp vault and merkle addresses
    address public vaultAddress;
    address public merkleAddress;
    uint256 public vaultId;

    uint256 private treeDepth;


    /**
     * @dev Constructor to initialize the DvpErc721PNH with the provided owner.
     * @param uri_ The URI of the token.
     * @param name_ The name of the token.
     * @param symbol_ The symbol of the token.
     * @param _authority The address of the access manager.

     */
    constructor(
        string memory uri_,
        string memory name_,
        string memory symbol_,
        address _authority,
        uint256 _treeDepth

    ) ERC721(name_, symbol_) {
        if (_authority != address(0)) _setAuthority(_authority);
        _tokenName = name_;
        _tokenSymbol = symbol_;
        _uri = uri_;
        treeDepth = _treeDepth;

        // Register cross-chain mutators against the RELAYER role so only the
        // relayer can drive PNH-side state from cross-chain settlement messages.
        if (_authority != address(0)) {
            // Empty: this contract intentionally exposes no `TOKEN_OWNER`-gated
            // selectors. All privileged mutators are routed to the RELAYER role.
            bytes4[] memory ownerSels = new bytes4[](0);
            bytes4[] memory relayerSels = new bytes4[](3);
            relayerSels[0] = DvpErc721PNH.mint.selector;
            relayerSels[1] = DvpErc721PNH.burn.selector;
            relayerSels[2] = DvpErc721PNH.UpdateInfosAfterDvpWithdraw.selector;

            IRaylsAccessManager.SelectorRoleMapping[] memory mappings =
                new IRaylsAccessManager.SelectorRoleMapping[](1);
            mappings[0] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);

            IRaylsAccessManager(_authority).selfRegisterManagedContract(msg.sender, ownerSels, mappings);
        }
    }

    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _uri;
    }

    /**
     * Overrides
     */
    function totalSupply() private view returns (uint256[] memory) {
        return _allTokens;
    }

    /**
     * @dev Mint new tokens and submit an update to the Private Hub.
     * @param _to The address to which the new tokens will be minted.
     * @param _id The id of the token to mint.
     * @param _chainId The chainId owner
     * @param _extraDatas The extra data for the token
     */
    function mint(address _to, uint256 _id, uint256 _chainId, SharedObjects.Dvp721ExtraData[] memory _extraDatas) external virtual restricted {
        _mint(_to, _id);
        _tokenIdToChainId[_id] = _chainId;

        for (uint256 i = 0; i < _extraDatas.length; i++) {
            nftExtraData[_id].push(_extraDatas[i]);
        }
    }

    /**
     * @dev Burn tokens and submit an update to the Private Hub.
     * @param _id The id of the token to burn.
     */
    function burn(uint256 _id) external virtual restricted {
        _burn(_id);
        delete _tokenIdToChainId[_id];
        delete nftExtraData[_id];
    }

    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
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

    function getChainIdByTokenId(uint256 _tokenId) public view virtual returns (uint256) {
        return _tokenIdToChainId[_tokenId];
    }

    /**
     * This is for total supply after approve
     */
    function getTotalSupply() public view virtual returns (uint256[] memory) {
        return totalSupply();
    }

    function getNftExtradaData(uint256 _tokenId) public view virtual returns (SharedObjects.Dvp721ExtraData[] memory) {
        return nftExtraData[_tokenId];
    }

    function UpdateInfosAfterDvpWithdraw(uint256 _nftId, uint256 _chainId, SharedObjects.Dvp721ExtraData[] memory _extraDatas, address _newOwner) external virtual restricted {
        _update(_newOwner, _nftId, address(0));
        _tokenIdToChainId[_nftId] = _chainId;

        if (_extraDatas.length > 0) {
            delete nftExtraData[_nftId];
            for (uint256 i = 0; i < _extraDatas.length; i++) {
                nftExtraData[_nftId].push(_extraDatas[i]);
            }
        }
    }

    /**
     * @dev Sets the vault and merkle addresses and vault ID
     * @param _vaultAddress Address of the vault
     * @param _merkleAddress Address of the merkle tree
     * @param _vaultId ID of the vault
     * @notice Can only be called once (by factory during initialization)
     */
    /// @dev Not `restricted`: this selector is intentionally outside the role mapping
    ///      registered in the constructor. Safety relies on the
    ///      `require(vaultAddress == address(0))` one-shot guard — the factory
    ///      atomically deploys this token and calls `setVaultInfo` in the same
    ///      transaction, leaving no front-run window.
    function setVaultInfo(address _vaultAddress, address _merkleAddress, uint256 _vaultId) external {
        require(vaultAddress == address(0), 'Vault already set');
        require(_vaultAddress != address(0), 'Invalid vault address');
        require(_merkleAddress != address(0), 'Invalid merkle address');

        vaultAddress = _vaultAddress;
        merkleAddress = _merkleAddress;
        vaultId = _vaultId;
    }
}

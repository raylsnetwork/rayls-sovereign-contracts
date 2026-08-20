// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import '@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';
import {IRaylsAccessManager} from '../../../privateHub/AccessControl/interfaces/IRaylsAccessManager.sol';
import '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';
import '../../../rayls-protocol-sdk/libraries/SharedObjects.sol';
import '../../interfaces/IEnygmaFactorySettings.sol';
import './Erc1155CoinVaultCreator.sol';
import './DvpSettings.sol';
import '../../interfaces/IDvp.sol';

/// @notice PNH-side mirror of cross-chain DVP ERC1155 tokens. State-mutating
///         entrypoints (`mint`, `burn`, `UpdateInfosAfterDvpWithdraw`) are
///         gated by the named `RELAYER` role on `RaylsAccessManagerV1`.
///         Compromise of any account holding `RELAYER` is a system-wide
///         risk for every PNH-side mirror; provisioning, rotation and
///         revocation of that role must be treated accordingly.
contract DvpErc1155PNH is ERC1155Supply, RaylsAccessManaged {
    using EnumerableSet for EnumerableSet.UintSet;

    string private _uri;
    string public name;

    // Supply tracking
    EnumerableSet.UintSet private _allTokens;

    // TokenId to ChainId mapping
    mapping(uint256 => uint256) private _tokenIdToChainId;

    mapping(uint256 => SharedObjects.Dvp1155ExtraData[]) private tokenExtraData;

    // Dvp vault and merkle addresses
    address public vaultAddress;
    address public merkleAddress;
    uint256 public vaultId;
    address public dvpAddress;
    address public factoryAddress;

    uint256 private treeDepth;

    // Asset group constants
    uint256 private constant GROUP_ID_FUNGIBLES = 0;
    uint256 private constant GROUP_ID_NON_FUNGIBLES = 1;

    // Track which tokens have been registered to asset groups
    mapping(uint256 => bool) private tokenRegisteredToGroup;

    // Track fungibility type per tokenId (true = fungible, false = non-fungible)
    mapping(uint256 => bool) private tokenIsFungible;

    /**
     * @dev Constructor to initialize the DvpErc1155PNH with the provided owner.
     * @param uri_ The URI of the token.
     * @param name_ The name of the token.
     * @param _authority The address of the access manager.
     */
    constructor(
        string memory uri_,
        string memory name_,
        address _authority,
        uint256 _treeDepth
    ) ERC1155(uri_) {
        if (_authority != address(0)) _setAuthority(_authority);
        _uri = uri_;
        name = name_;
        treeDepth = _treeDepth;

        // Register cross-chain mutators against the RELAYER role so only the
        // relayer can drive PNH-side state from cross-chain settlement messages.
        if (_authority != address(0)) {
            // Empty: this contract intentionally exposes no `TOKEN_OWNER`-gated
            // selectors. All privileged mutators are routed to the RELAYER role.
            bytes4[] memory ownerSels = new bytes4[](0);
            bytes4[] memory relayerSels = new bytes4[](3);
            relayerSels[0] = DvpErc1155PNH.mint.selector;
            relayerSels[1] = DvpErc1155PNH.burn.selector;
            relayerSels[2] = DvpErc1155PNH.UpdateInfosAfterDvpWithdraw.selector;

            IRaylsAccessManager.SelectorRoleMapping[] memory mappings =
                new IRaylsAccessManager.SelectorRoleMapping[](1);
            mappings[0] = IRaylsAccessManager.SelectorRoleMapping("RELAYER", relayerSels);

            IRaylsAccessManager(_authority).selfRegisterManagedContract(msg.sender, ownerSels, mappings);
        }
    }

    function uri(uint256 /* id */) public view virtual override returns (string memory) {
        return _uri;
    }

    function _setURI(string memory newuri) internal virtual override {
        _uri = newuri;
    }

    function getTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * This function returns an array with all the token ids.
     * @param startIndex The starting index of the array to return.
     * @param howMany How many token ids to return from the starting index. If there are not enough tokens in the PN,
     *                it will return as many as possible.
     * @return tokenIds An array containing the token ids from startIndex to startIndex+howMany-1 or to the end of the array if there are not enough tokens.
     * @return supplies An array containing the supply of each token id in the same order as tokenIds.
     * @dev If startIndex+howMany exceeds the length of _allTokens, it will be adjusted to the last valid index.
     * @dev If startIndex is greater than or equal to the length of _allTokens, an empty array will be returned.
     */
    function getAllTokenIdsWithSupply(
        uint256 startIndex,
        uint256 howMany
    ) public view virtual returns (uint256[] memory tokenIds, uint256[] memory supplies) {
        require(howMany > 0, 'Invalid howMany value'); // Ensure howMany is greater than 0

        uint256 endIndex = startIndex + howMany - 1; // Calculate the end index based on startIndex and howMany

        if (endIndex > _allTokens.length()) {
            endIndex = _allTokens.length() - 1;
        }

        tokenIds = new uint256[](endIndex - startIndex + 1);
        supplies = new uint256[](endIndex - startIndex + 1);

        for (uint256 i = startIndex; i <= endIndex; i++) {
            uint256 tokenId = _allTokens.at(i);
            tokenIds[i - startIndex] = tokenId;
            supplies[i - startIndex] = totalSupply(tokenId);
        }

        return (tokenIds, supplies);
    }

    /**
     * @dev Mint new tokens and submit an update to the Private Hub.
     * @param _to The address to which the new tokens will be minted.
     * @param _id The id of the token to mint.
     * @param _chainId The chainId owner
     * @param _extraDatas The extra data for the token
     * @notice Automatically registers token to asset group on first mint
     * @notice All tokens are currently fungible (tokenIsFungible defaults to true)
     */
    function mint(
        address _to,
        uint256 _id,
        uint256 _value,
        bytes memory _data,
        uint256 _chainId,
        SharedObjects.Dvp1155ExtraData[] memory _extraDatas
    ) external virtual restricted {
        // On first mint, set fungibility to true (all tokens are fungible for now)
        if (!tokenRegisteredToGroup[_id]) {
            tokenIsFungible[_id] = true;
            tokenRegisteredToGroup[_id] = true;
        }
        _tokenIdToChainId[_id] = _chainId;

        for (uint256 i = 0; i < _extraDatas.length; i++) {
            tokenExtraData[_id].push(_extraDatas[i]);
        }

        _mint(_to, _id, _value, _data);

        // TODO: COMMENTED OUT - Token-level registration temporarily disabled
        // Using vault-level membership (added in factory) until ERC1155 circuit supports
        // asset group merkle root as a public input. This will be re-enabled after circuit update.
        /*
        // Register token to asset group on first mint
        if (!tokenRegisteredToGroup[_id] && factoryAddress != address(0) && vaultId != 0) {
            // Determine target group based on fungibility
            uint256 targetGroupId = tokenIsFungible[_id] ? GROUP_ID_FUNGIBLES : GROUP_ID_NON_FUNGIBLES;

            // Call factory to register token (factory has OWNER_ROLE in Dvp)
            (bool success, ) = factoryAddress.call(
                abi.encodeWithSignature(
                    "registerTokenToGroup(address,uint256,uint256)",
                    address(this),
                    _id,
                    targetGroupId
                )
            );

            if (success) {
                tokenRegisteredToGroup[_id] = true;
            }
        }
        */
    }

    /**
     * @dev Burn tokens and submit an update to the Private Hub.
     * @param _id The id of the token to burn.
     */
    function burn(address _from, uint256 _id, uint256 _value) external virtual restricted {
        _burn(_from, _id, _value);

        if (totalSupply(_id) == 0) {
            delete _tokenIdToChainId[_id];
            delete tokenExtraData[_id];
            // The mint-side first-write-wins block keys off
            // `tokenRegisteredToGroup[_id] == false`, so leftover `true` here
            // would silently skip re-registration on a future re-mint of the
            // same id (matters once the currently commented-out factory
            // registration is re-enabled).
            delete tokenRegisteredToGroup[_id];
            delete tokenIsFungible[_id];
        }
    }

    function getChainIdByTokenId(uint256 _tokenId) public view virtual returns (uint256) {
        return _tokenIdToChainId[_tokenId];
    }

    function getNumberAllTokens() public view returns (uint256) {
        return _allTokens.length();
    }

    /**
     * This is for total supply after approve
     * @param startIndex The starting index of the tokens to retrieve
     * @param howMany The number of tokens to retrieve starting from the startIndex. If this value exceeds the number of tokens available, it will return all remaining tokens starting from startIndex.
     * @return tokenIds An array of token IDs and their corresponding total supply amounts.
     * @dev This function returns a paginated list of token IDs and their total supply amounts.
     */
    function getTotalSupply(
        uint256 startIndex,
        uint256 howMany
    ) public view virtual returns (uint256[] memory tokenIds) {
        require(howMany > 0, 'Invalid howMany value'); // Ensure howMany is greater than 0
        uint256 endIndex = startIndex + howMany - 1; // Calculate the end index based on startIndex and howMany

        if (endIndex > _allTokens.length()) {
            endIndex = _allTokens.length() - 1;
        }

        tokenIds = new uint256[](endIndex - startIndex + 1);

        for (uint256 i = startIndex; i <= endIndex; i++) {
            uint256 tokenId = _allTokens.at(i);
            tokenIds[i - startIndex] = tokenId;
        }
    }

    function getTokenExtraData(
        uint256 _tokenId
    ) public view virtual returns (SharedObjects.Dvp1155ExtraData[] memory) {
        return tokenExtraData[_tokenId];
    }

    /**
     * @dev Check if a token has been registered to an asset group
     * @param _tokenId The token ID to check
     * @return bool True if token has been registered
     */
    function isTokenRegistered(uint256 _tokenId) public view returns (bool) {
        return tokenRegisteredToGroup[_tokenId];
    }

    /**
     * @dev Get the fungibility type of a token
     * @param _tokenId The token ID to check
     * @return bool True if fungible, false if non-fungible
     * @notice Currently all tokens are fungible (true)
     */
    function getTokenFungibility(uint256 _tokenId) public view returns (bool) {
        require(exists(_tokenId), "Token not yet minted");
        return tokenIsFungible[_tokenId];
    }

    /// @dev `_update(msg.sender, _newOwner, _ids, _amounts)` debits the
    ///      caller's balance, so the RELAYER calling this function must hold
    ///      `_amounts[i]` of `_ids[i]` at call time. Insufficient balance
    ///      reverts with the underlying ERC1155 error rather than a contract-
    ///      level message. The relayer accumulates this balance via `mint`
    ///      (initial supply sync / source-chain deposit) and via the on-PNH
    ///      withdraw flow that transfers vault → relayer before this call.
    function UpdateInfosAfterDvpWithdraw(
        uint256[] memory _ids,
        uint256[] memory _amounts,
        uint256 _chainId,
        SharedObjects.Dvp1155ExtraData[] memory _extraDatas,
        address _newOwner
    ) external virtual restricted {
        _update(msg.sender, _newOwner, _ids, _amounts);
        for (uint256 i = 0; i < _ids.length; i++) {
            _tokenIdToChainId[_ids[i]] = _chainId;

            if (_extraDatas.length > 0) {
                delete tokenExtraData[_ids[i]];

                for (uint256 j = 0; j < _extraDatas.length; j++) {
                    tokenExtraData[_ids[i]].push(_extraDatas[j]);
                }
            }
        }
    }

    /**
     * @dev Sets the vault and merkle addresses, vault ID, and Dvp address
     * @param _vaultAddress Address of the vault
     * @param _merkleAddress Address of the merkle tree
     * @param _vaultId ID of the vault
     * @param _dvpAddress Address of the Dvp contract
     * @notice Can only be called once (by factory during initialization)
     */
    /// @notice One-time vault initialization, called by the factory during creation.
    /// @dev Not `restricted`: this selector is intentionally outside the role mapping
    ///      registered in the constructor. Safety relies on the
    ///      `require(vaultAddress == address(0))` one-shot guard — the factory
    ///      atomically deploys this token and calls `setVaultInfo` in the same
    ///      transaction, leaving no front-run window.
    function setVaultInfo(
        address _vaultAddress,
        address _merkleAddress,
        uint256 _vaultId,
        address _dvpAddress
    ) external {
        require(vaultAddress == address(0), 'Vault already set');
        require(_vaultAddress != address(0), 'Invalid vault address');
        require(_merkleAddress != address(0), 'Invalid merkle address');
        require(_dvpAddress != address(0), 'Invalid dvp address');

        vaultAddress = _vaultAddress;
        merkleAddress = _merkleAddress;
        vaultId = _vaultId;
        dvpAddress = _dvpAddress;
        factoryAddress = msg.sender; // msg.sender is the factory
    }
}

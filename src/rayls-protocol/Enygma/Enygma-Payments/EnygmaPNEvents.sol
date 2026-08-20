//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import './CurveBabyJubJub.sol';
import '../../../rayls-protocol-sdk/RaylsApp.sol';
import '../../../rayls-protocol-sdk/Constants.sol';
import '../../../rayls-protocol-sdk/libraries/SharedObjects.sol';
import '../../../rayls-protocol-sdk/interfaces/IEnygmaPNEvents.sol';
import '../../../rayls-protocol-sdk/interfaces/IRaylsEndpoint.sol';
import '../../interfaces/IParticipantValidator.sol';
import '../../interfaces/ITokenRegistryValidator.sol';
import {RaylsAccessManaged} from '../../../privateHub/AccessControl/RaylsAccessManaged.sol';

contract EnygmaPNEvents is RaylsApp, RaylsAccessManaged {
    /*//////////////////////////////////////////////////////////////
                           STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Validator for participant permissions and status
    IParticipantValidator public participantValidator;

    /// @notice Validator for token registry operations
    ITokenRegistryValidator public tokenValidator;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error EnygmaPNEvents__ValidatorsNotInitialized();

    /**
     * @notice Validates participant status and token freeze status for source and (optionally) destination chains
     * @dev Validates:
     *      1. Current chain is registered and active
     *      2. Token is not frozen for Current chain
     *      3. Each destination chain is registered and active (only when _toChainIds is non-empty)
     *      4. Token is not frozen for each destination chain (only when _toChainIds is non-empty)
     * @param _resourceId The token resource ID to validate
     * @param _toChainIds Destination chain IDs. Receives an empty array for DVP operations (current chain check only);
     *                    receive destination chain IDs for cross-chain Enygma transfers.
     */
    modifier validateTransfer(bytes32 _resourceId, uint256[] memory _toChainIds) {
        if (address(participantValidator) == address(0) || address(tokenValidator) == address(0)) {
            revert EnygmaPNEvents__ValidatorsNotInitialized();
        }

        uint256 currentChainId = IRaylsEndpoint(endpoint).getChainId();

        // Always validate current chain participant status and token freeze
        participantValidator.validateParticipantStatus(currentChainId);
        tokenValidator.validateTokenForParticipant(_resourceId, currentChainId);

        // Validate destination chains only for cross-chain Enygma transfers
        for (uint256 i = 0; i < _toChainIds.length; i++) {
            participantValidator.validateParticipantStatus(_toChainIds[i]);
            tokenValidator.validateTokenForParticipant(_resourceId, _toChainIds[i]);
        }

        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes EnygmaPNEvents with endpoint and validators
     * @param _endpointAddress Address of the Rayls endpoint
     * @param _participantValidator Address of the participant validator
     * @param _tokenValidator Address of the token validator
     * @dev Validators can be set to address(0) initially and set later via setters
     */
    constructor(
        address _endpointAddress,
        address _participantValidator,
        address _tokenValidator,
        address _authority
    ) RaylsApp(_endpointAddress, address(0), address(0)) {
        if (_participantValidator != address(0)) {
            participantValidator = IParticipantValidator(_participantValidator);
        }
        if (_tokenValidator != address(0)) {
            tokenValidator = ITokenRegistryValidator(_tokenValidator);
        }
        if (_authority != address(0)) {
            _initializeAuthority(_authority);
        }
    }

    function initialize() public {
        require(resourceId == bytes32(0), "Already initialized");
        resourceId = Constants.RESOURCE_ID_ENYGMA_PN_EVENTS;
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets the participant validator
     * @param _participantValidator Address of the participant validator
     * @dev Can only be called by authorized addresses
     */
    function setParticipantValidator(address _participantValidator) external restricted {
        require(_participantValidator != address(0), "EnygmaPNEvents: zero address");
        participantValidator = IParticipantValidator(_participantValidator);
    }

    /**
     * @notice Sets the token validator
     * @param _tokenValidator Address of the token validator
     * @dev Can only be called by authorized addresses
     */
    function setTokenValidator(address _tokenValidator) external restricted {
        require(_tokenValidator != address(0), "EnygmaPNEvents: zero address");
        tokenValidator = ITokenRegistryValidator(_tokenValidator);
    }

    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event EnygmaMint(bytes32 _resourceId, address _to, uint256 _amount);
    event EnygmaBurn(bytes32 _resourceId, address _from, uint256 _amount);
    event EnygmaCreation(bytes32 _resourceId, uint256 _initialSupply);
    event EnygmaSendTransferPNH(
        bytes32 _resourceId,
        uint256[] _value,
        uint256[] _toChainId,
        address[] _to,
        address _from,
        bytes32 _referenceId,
        SharedObjects.EnygmaProgramData[][] _programData
    );

    event EnygmaRevertMint(bytes32 _resourceId, uint256 _amount, address _to, string _reason);

    //DVP
    event EnygmaDepositToDvp(bytes32 _resourceId, uint256 amount, address _from, bytes32 _referenceId);
    event EnygmaWithdrawFromDvp(bytes32 _resourceId, uint256 amount, address _to, bytes32 _referenceId);
    event EnygmaSwapWithDvpForERC721(bytes32 _resourceId, uint256 _nftId, bytes32 _nftResourceId, uint256 _enygmaAmount, address _from, uint256 _destChainId, bytes32 _sharedId, uint64 _validityTime);
    event EnygmaSwapWithDvpForERC1155(bytes32 _resourceId, uint256 _nftId, bytes32 _nftResourceId, uint256 _nftAmountOrOne, uint256 _enygmaAmount, address _from, uint256 _destChainId, bytes32 _sharedId, uint64 _validityTime);
    
    event Dvp721Creation(bytes32 _resourceId);
    event Dvp721Burn(bytes32 _resourceId, uint256 _nftId);
    event Dvp721Mint(bytes32 _resourceId, uint256 _nftId);
    event Dvp721DepositIntoDvp(bytes32 _resourceId, uint256 _nftId, address from);
    event Dvp721WithdrawFromDvp(bytes32 _resourceId, uint256 _nftId, address owner);
    event Dvp721SwapForEnygma(bytes32 _nftResourceId, uint256 _nftId, uint256 _enygmaAmount, bytes32 _enygmaResourceId, address _from, uint256 _destChainId, bytes32 _sharedId, uint64 _validityTime);
    event Dvp721SwapCompleted(bytes32 _resourceId, uint256 _nftId, uint256 _destinationChainId, address _destinationOwner);

    event Dvp1155Creation(bytes32 _resourceId);
    event Dvp1155Burn(bytes32 _resourceId, address _to,  uint256 _tokenId, uint256 _value);
    event Dvp1155Mint(bytes32 _resourceId, uint256 _tokenId, uint256 _value, bytes data);
    event Dvp1155DepositIntoDvp(bytes32 _resourceId, uint256 _tokenId, address from, uint256 _value, bytes data);
    event Dvp1155WithdrawFromDvp(bytes32 _resourceId, uint256 _tokenId, uint256 _value, bytes  data, address owner);
    event Dvp1155SwapForEnygma(
        bytes32 _tokenResourceId,
        uint256 _tokenId,
        uint256 _tokenValue,
        bytes _tokenData,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        address from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    );
    event Dvp1155SwapCompleted(bytes32 _resourceId, uint256 _tokenId, uint256 _destinationChainId, address _destinationOwner);
    event DvpSwapCancelled(bytes32 _sharedId, uint256 _destChainId, bytes32 _tokenInResourceId, uint256 _tokenInAmount, uint256 _tokenInId, SharedObjects.ErcStandard _tokenInStandard, bytes32 _tokenOutResourceId, uint256 _tokenOutAmount, uint256 _tokenOutId, SharedObjects.ErcStandard _tokenOutStandard);

    function mint(bytes32 _resourceId, address _to, uint256 _amount) external restricted {
        emit EnygmaMint(_resourceId, _to, _amount);
    }

    function burn(bytes32 _resourceId, address _from, uint256 _amount) external restricted {
        emit EnygmaBurn(_resourceId, _from, _amount);
    }

    function creation(bytes32 _resourceId, uint256 initialSupply) public restricted {
        emit EnygmaCreation(_resourceId, initialSupply);
    }

    /**
     * @notice Emits Enygma cross-chain transfer event after validating participants and token status
     * @param _pnhTransfer The cross-chain transfer data
     * @dev Validates that:
     *      1. All destination chains are registered and ACTIVE participants
     *      2. Token is not frozen for source and all destination chains
     */
    function sendTransferPNH(SharedObjects.PNHTransfer memory _pnhTransfer)
        public
        restricted
        validateTransfer(_pnhTransfer.resourceId, _pnhTransfer.toChainId)
    {
        emit EnygmaSendTransferPNH(
            _pnhTransfer.resourceId,
            _pnhTransfer.value,
            _pnhTransfer.toChainId,
            _pnhTransfer.to,
            _pnhTransfer.from,
            _pnhTransfer.referenceId,
            _pnhTransfer.programData
        );
    }

    function revertMint(bytes32 _resourceId, uint256 _amount, address _to, string memory _reason) public restricted {
        emit EnygmaRevertMint(_resourceId, _amount, _to, _reason);
    }

    //DVP

    function cancelSwap(bytes32 _sharedId, uint256 _toChainId, bytes32 _tokenInResourceId, uint256 _tokenInAmount, uint256 _tokenInId, SharedObjects.ErcStandard _tokenInStandard, bytes32 _tokenOutResourceId, uint256 _tokenOutAmount, uint256 _tokenOutId, SharedObjects.ErcStandard _tokenOutStandard) external restricted {
        emit DvpSwapCancelled(_sharedId, _toChainId, _tokenInResourceId, _tokenInAmount, _tokenInId, _tokenInStandard, _tokenOutResourceId, _tokenOutAmount, _tokenOutId, _tokenOutStandard);
    }

    function depositToDvp(bytes32 _resourceId, uint256 amount, address _from, bytes32 _referenceId) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit EnygmaDepositToDvp(_resourceId, amount, _from, _referenceId);
    }

    function withdrawFromDvp(bytes32 _resourceId, uint256 amount, address _to, bytes32 _referenceId) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit EnygmaWithdrawFromDvp(_resourceId, amount, _to, _referenceId);
    }

    function swapWithDvpForERC721(
        bytes32 _resourceId,
        uint256 _nftId,
        bytes32 _nftResourceId,
        uint256 _enygmaAmount,
        address _from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit EnygmaSwapWithDvpForERC721(_resourceId, _nftId, _nftResourceId, _enygmaAmount, _from, _destChainId, _sharedId, _validityTime);
    }

    function dvp721Creation(bytes32 _resourceId) public restricted {
        emit Dvp721Creation(_resourceId);
    }

    function dvp721Mint(bytes32 _resourceId, uint256 _nftId) public restricted {
        emit Dvp721Mint(_resourceId, _nftId);
    }

    function dvp721Burn(bytes32 _resourceId, uint256 _nftId) public restricted {
        emit Dvp721Burn(_resourceId, _nftId);
    }

    function dvp721DepositIntoDvp(bytes32 _resourceId, uint256 _nftId, address from) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit Dvp721DepositIntoDvp(_resourceId, _nftId, from);
    }

    function dvp721SwapForEnygma(
        bytes32 _nftResourceId,
        uint256 _nftId,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        address _from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public restricted validateTransfer(_nftResourceId, new uint256[](0)) {
        emit Dvp721SwapForEnygma(_nftResourceId, _nftId, _enygmaAmount, _enygmaResourceId, _from, _destChainId, _sharedId, _validityTime);
    }

    function dvp721WithdrawFromDvp(bytes32 _resourceId, uint256 _nftId, address owner) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit Dvp721WithdrawFromDvp(_resourceId, _nftId, owner);
    }

    function dvp721SwapCompleted(bytes32 _resourceId, uint256 _nftId, uint256 _destinationChainId, address _destinationOwner) public restricted {
        emit Dvp721SwapCompleted(_resourceId, _nftId, _destinationChainId, _destinationOwner);
    }

    function dvp1155Creation(bytes32 _resourceId) public restricted {
        emit Dvp1155Creation(_resourceId);
    }

    function dvp1155Mint(bytes32 _resourceId, uint256 _tokenId, uint256 _value, bytes memory data) public restricted {
        emit Dvp1155Mint(_resourceId, _tokenId, _value, data);
    }

    function dvp1155Burn(bytes32 _resourceId, address _to,  uint256 _tokenId, uint256 _value) public restricted {
        emit Dvp1155Burn(_resourceId, _to, _tokenId, _value);
    }

    function dvp1155DepositIntoDvp(bytes32 _resourceId, uint256 _tokenId, address from, uint256 _value, bytes memory data) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit Dvp1155DepositIntoDvp(_resourceId, _tokenId, from, _value, data);
    }

    function dvp1155SwapForEnygma(
        bytes32 _tokenResourceId,
        uint256 _tokenId,
        uint256 _tokenValue,
        bytes memory _tokenData,
        uint256 _enygmaAmount,
        bytes32 _enygmaResourceId,
        address from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public restricted validateTransfer(_tokenResourceId, new uint256[](0)) {
        emit Dvp1155SwapForEnygma(
            _tokenResourceId,
            _tokenId,
            _tokenValue,
            _tokenData,
            _enygmaAmount,
            _enygmaResourceId,
            from,
            _destChainId,
            _sharedId,
            _validityTime
        );
    }

    function swapWithDvpForERC1155(
        bytes32 _resourceId,
        uint256 _nftId,
        bytes32 _nftResourceId,
        uint256 _nftAmountOrOne,
        uint256 _enygmaAmount,
        address _from,
        uint256 _destChainId,
        bytes32 _sharedId,
        uint64 _validityTime
    ) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit EnygmaSwapWithDvpForERC1155(_resourceId, _nftId, _nftResourceId, _nftAmountOrOne, _enygmaAmount, _from, _destChainId, _sharedId, _validityTime);
    }

    function dvp1155WithdrawFromDvp(bytes32 _resourceId, uint256 _tokenId, uint256 _value, bytes memory data, address owner) public restricted validateTransfer(_resourceId, new uint256[](0)) {
        emit Dvp1155WithdrawFromDvp(_resourceId, _tokenId, _value, data, owner);
    }

    function dvp1155SwapCompleted(bytes32 _resourceId, uint256 _tokenId, uint256 _destinationChainId, address _destinationOwner) public restricted {
        emit Dvp1155SwapCompleted(_resourceId, _tokenId, _destinationChainId, _destinationOwner);
    }
}

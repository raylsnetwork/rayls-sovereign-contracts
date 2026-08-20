// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../interfaces/IEnygmaManager.sol";
import "../../interfaces/IParticipantCore.sol";
import "../../libraries/ParticipantStructs.sol";
import "../../../../privateHub/AccessControl/RaylsAccessManaged.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title EnygmaManager
 * @dev Module that handles Enygma-related functionality
 */
contract EnygmaManagerV1 is Initializable, IEnygmaManager, UUPSUpgradeable, RaylsAccessManaged {
    // Mapping of chain ID to Payment spend data
    mapping(uint256 => ParticipantStructs.PrivacyNodeSpendData) internal paymentSpendData;
    
    // Array of all Enygma participants
    uint256[] public allEnygmaParticipants;
    
    // Address of the PN Enygma events contract
    address public pnEnygmaEvents;

    // Reference to the ParticipantCore module
    IParticipantCore public participantCore;

    // Address of the parent ParticipantStorage contract
    address public parentStorage;

    error EnygmaManagerV1__UnauthorizedCaller(address caller);

    modifier onlyParticipantStorage() {
        if (msg.sender != parentStorage) {
            revert EnygmaManagerV1__UnauthorizedCaller(msg.sender);
        }
        _;
    }

    /**
     * @notice Initializes the contract
     * @param _participantCore The address of the ParticipantCore module
     * @param _parentStorage The address of the ParticipantStorage contract
     * @param authority_ Address of the deployed RaylsAccessManagerV1.
     */
    function initialize(address _participantCore, address _parentStorage, address authority_) public initializer {
        __UUPSUpgradeable_init();
        participantCore = IParticipantCore(_participantCore);
        parentStorage = _parentStorage;
        _initializeAuthority(authority_);
    }

    /// @dev Upgrade authorization is gated by the access manager (ADMIN required).
    function _authorizeUpgrade(address /*newImplementation*/) internal override {
        _checkCanCall(msg.sender, msg.sig);
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function setPaymentSpendPublicKey(
        uint256 _chainId,
        uint256 _paymentSpendPublicKey,
        address[] calldata _pnAddresses
     ) external override onlyParticipantStorage {
        require(paymentSpendData[_chainId].paymentSpendPublicKey == 0, "EnygmaManager: Payment Data for this chainId is already set!"); 
        require(participantCore.verifyParticipant(_chainId), "EnygmaManager: Participant not exists or not with an Active Status");

        paymentSpendData[_chainId].paymentSpendPublicKey = _paymentSpendPublicKey;
        paymentSpendData[_chainId].pnAddresses = _pnAddresses;
        paymentSpendData[_chainId].chainId = _chainId;
        allEnygmaParticipants.push(_chainId);
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function getPaymentSpendPublicKeyByChainId(uint256 chainId) external view override returns (uint256) {
        return paymentSpendData[chainId].paymentSpendPublicKey;
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function getAllPaymentSpendPublicKeys() external view override returns (ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory) {
        uint256 totalParticipants = allEnygmaParticipants.length;
        ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory pnSpendDataSafe =
            new ParticipantStructs.PrivacyNodeSpendDataSafeReturn[](totalParticipants);

        for (uint256 i = 0; i < totalParticipants; i++) {
            uint256 chainId = allEnygmaParticipants[i];
            pnSpendDataSafe[i] = ParticipantStructs.PrivacyNodeSpendDataSafeReturn(
                paymentSpendData[chainId].paymentSpendPublicKey,
                paymentSpendData[chainId].pnAddresses,
                paymentSpendData[chainId].chainId
            );
        }

        return pnSpendDataSafe;
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function getEnygmaAllParticipantsChainIds() external view override returns (uint256[] memory) {
        return allEnygmaParticipants;
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function checkEnygmaAccountAllowed(address _address) external view override returns (bool) {
        for (uint256 i = 0; i < allEnygmaParticipants.length; i++) {
            uint256 chainId = allEnygmaParticipants[i];
            for (uint256 j = 0; j < paymentSpendData[chainId].pnAddresses.length; j++) {
                if (paymentSpendData[chainId].pnAddresses[j] == _address) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function checkEnygmaIssuerAccountAllowed(address _address, uint256 _chainId) external view override returns (bool) {
        for (uint256 i = 0; i < allEnygmaParticipants.length; i++) {
            if (allEnygmaParticipants[i] == _chainId) {
                address[] memory pnAddresses = paymentSpendData[_chainId].pnAddresses;
                for (uint256 j = 0; j < pnAddresses.length; j++) {
                    if (pnAddresses[j] == _address) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function setEnygmaPnEventsAddress(address _pnEnygmaEvents) external override onlyParticipantStorage {
        pnEnygmaEvents = _pnEnygmaEvents;
    }

    /**
     * @inheritdoc IEnygmaManager
     */
    function getEnygmaPnEventsAddress() external view override returns (address) {
        return pnEnygmaEvents;
    }

    /**
     * @dev Returns the contract version
     * @return The version number (1) of this contract implementation
     */
    function contractVersion() external pure virtual returns (uint256) {
        return 1;
    }
} 
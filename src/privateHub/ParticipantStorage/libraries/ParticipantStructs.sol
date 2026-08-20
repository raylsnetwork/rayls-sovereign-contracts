// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library ParticipantStructs {
    enum Status {
        NEW,
        ACTIVE,
        INACTIVE,
        FROZEN
    }

    enum Role {
        PARTICIPANT,
        ISSUER,
        AUDITOR
    }

    struct Participant {
        uint256 chainId;
        Role role;
        Status status;
        string ownerId;
        string name;
        uint256 createdAt;
        uint256 updatedAt;
        bool allowedToBroadcast;
    }

    struct ParticipantData {
        uint256 chainId;
        Role role;
        string ownerId;
        string name;
        bool allowedToBroadcast;
    }

    struct AuditInfoData {
        uint256 chainId;
        string raylsViewPublicKey;
        bytes encryptedRaylsViewPrivateKey;
        bytes mac;
        uint256 blockNumber;
    }

    struct PrivacyNodeViewData {
        uint256 chainId;
        string raylsViewPublicKey;
        uint256 blockNumber;
    }

    struct PrivacyNodeSpendData {
        uint256 paymentSpendPublicKey;
        address[] pnAddresses;
        uint256 chainId;
    }

    struct KeyAgreementData {
        uint256 chainId;
        bytes ciphertext;
        bytes digest;
        uint256 blockNumber;
    }

    struct PrivacyNodeSpendDataSafeReturn {
        uint256 paymentSpendPublicKey;
        address[] pnAddresses;
        uint256 chainId;
    }

    struct PrivacyNodeDataEnygmaSecretSafeReturn {
        uint256 secret;
        uint256 chainId;
    }
} 
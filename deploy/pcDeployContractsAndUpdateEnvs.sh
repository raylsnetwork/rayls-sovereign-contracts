#!/usr/bin/env bash
cd "$(dirname "$0")/.." || exit 1

# Wrapper script for public chain deployment with OpenZeppelin file management
# Usage: ./deploy/pcDeployContractsAndUpdateEnvs.sh <PARTICIPANT_NAME> <NETWORK> <CHAIN_ID>
# Example: ./deploy/pcDeployContractsAndUpdateEnvs.sh A localPC 7331

PARTICIPANT_NAME=$1
HH_PC_NETWORK=$2
HH_PC_CHAIN_ID=$3

if [ -z "$PARTICIPANT_NAME" ]; then
    echo "Error: Participant name is required"
    echo "Usage: $0 <PARTICIPANT_NAME>"
    exit 1
fi

echo "Starting public chain deployment for participant $PARTICIPANT_NAME..."

# Determine appropriate lock directory for cross-platform compatibility
if [ -d "/var/lock" ] && [ -w "/var/lock" ]; then
    LOCK_DIR="/var/lock"
elif [ -d "/tmp" ] && [ -w "/tmp" ]; then
    LOCK_DIR="/tmp"
else
    LOCK_DIR="./locks"
    mkdir -p "$LOCK_DIR"
fi

LOCK_FILE="$LOCK_DIR/public-chain-deployment"

# Use file locking to serialize public chain deployments to prevent OpenZeppelin file conflicts
(
    flock 300
    
    echo "Acquired deployment lock for participant $PARTICIPANT_NAME"
    
    # Derive NODE_PN_CHAIN_ID from contracts .env PARTICIPANTS list using participant letter index (A=0, B=1, ...)
    CONTRACTS_ENV="/parfin/rayls-contracts/.env"
    if [ ! -f "$CONTRACTS_ENV" ]; then
        echo "Contracts env file not found at $CONTRACTS_ENV, trying fallback .env" >&2
        CONTRACTS_ENV=".env"
        if [ ! -f "$CONTRACTS_ENV" ]; then
            echo "Error: Contracts env file not found at /parfin/rayls-contracts/.env or .env" >&2
            exit 1
        fi
    fi
    
    echo "Using env file: $CONTRACTS_ENV"
    PARTICIPANTS_LINE=$(grep -E '^PARTICIPANTS=' "$CONTRACTS_ENV" | head -n1 || true)
    if [ -n "$PARTICIPANTS_LINE" ]; then
        PARTICIPANTS_VALUE=${PARTICIPANTS_LINE#PARTICIPANTS=}
        IFS=',' read -r -a PN_CHAIN_IDS <<< "$PARTICIPANTS_VALUE"
        # Compute index from letter
        LETTER_ASCII=$(printf '%d' "'${PARTICIPANT_NAME}")
        INDEX=$((LETTER_ASCII - 65))
        if [ $INDEX -ge 0 ] && [ $INDEX -lt ${#PN_CHAIN_IDS[@]} ]; then
            export NODE_PN_CHAIN_ID=${PN_CHAIN_IDS[$INDEX]}
            echo "Using NODE_PN_CHAIN_ID=$NODE_PN_CHAIN_ID for participant $PARTICIPANT_NAME"
        else
            echo "Warning: Unable to map participant $PARTICIPANT_NAME to a PN chain id from PARTICIPANTS list" >&2
        fi
    else
        echo "Warning: PARTICIPANTS not found in $CONTRACTS_ENV; proceeding without NODE_PN_CHAIN_ID" >&2
    fi
    
    # Export participant name for deployment scripts to use
    export PARTICIPANT_NAME
    
    # Check for existing deployment manifest (flat naming: unknown-<chain-id>-<participant>.json)
    MANIFEST_FILE=".openzeppelin/unknown-${HH_PC_CHAIN_ID}-${PARTICIPANT_NAME}.json"
    if [ -f "$MANIFEST_FILE" ]; then
        echo "" >&2
        echo "❌ ERROR: Existing public chain deployment detected for participant $PARTICIPANT_NAME" >&2
        echo "   Manifest: $MANIFEST_FILE" >&2
        echo "" >&2
        echo "   To redeploy, first delete the existing manifest:" >&2
        echo "   rm $MANIFEST_FILE" >&2
        echo "" >&2
        exit 1
    fi
    
    # Run deployment
    npx hardhat deploy:public-chain --network "$HH_PC_NETWORK"
    HARDHAT_EXIT=$?
    if [ $HARDHAT_EXIT -ne 0 ]; then
        echo "Hardhat public-chain deployment failed with exit code $HARDHAT_EXIT for participant $PARTICIPANT_NAME" >&2
        exit $HARDHAT_EXIT
    fi
    
    # Verify manifest was created with correct naming
    if [ -f "$MANIFEST_FILE" ]; then
        echo "✅ Deployment manifest created: $MANIFEST_FILE"
    else
        echo "Warning: Expected manifest file not found at $MANIFEST_FILE" >&2
    fi
    
    echo "Released deployment lock for participant $PARTICIPANT_NAME"
    
) 300>"$LOCK_FILE"
WRAPPED_EXIT=$?
echo "Public chain deployment completed for participant $PARTICIPANT_NAME"
exit $WRAPPED_EXIT
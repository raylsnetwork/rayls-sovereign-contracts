#!/usr/bin/env bash

#trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT

# Trap SIGTERM and SIGINT signals
trap 'kill_node' SIGTERM SIGINT

# Function to kill the Node.js server
kill_node() {
    echo "Signal received. Killing Node.js server..."
    
    # Check if PID exists
    if [ -n "$NODE_PID" ]; then
        # Send the signal to the Node.js process
        kill -s SIGINT "$NODE_PID"
        
        # Wait until the process terminates
        while kill -0 "$NODE_PID" 2>/dev/null; do
            sleep 0.1
        done
        
        echo "Node.js server has exited."
    fi
}

CONTRACTS_PATH=${CONTRACTS_PATH:-"/parfin/rayls-privacy-contracts"}

echo "0.0,Started" > /tmp/deploy_status

# Start node in background as a direct child of this shell
node "${CONTRACTS_PATH}"/docker/dev/contracts_deploy_healthcheck.js &
NODE_PID=$!

set -eo pipefail

# This script is meant to be executed inside a docker container of rayls-privacy-contracts.
# This script's working directory is /app, which is a copy of the rayls-privacy-contracts root dir.
# DO NOT USE THIS IN PRODUCTION!

CUSTOM_UID=${CUSTOM_UID:-id -u}
CUSTOM_GID=${CUSTOM_GID:-id -g}
GOVERNANCE_ENABLED=${GOVERNANCE_ENABLED:-false}
PUBLIC_CHAIN_ENABLED=${PUBLIC_CHAIN_ENABLED:-true}
HUB_ENABLED=${HUB_ENABLED:-true}
RELAYER_PATH=${RELAYER_PATH:-"/parfin/rayls-privacy-relayer-api"}
GOVERNANCE_PATH=${GOVERNANCE_PATH:-"/parfin/rayls-privacy-pnh-governance-api"}
OPS_API_PATH=${OPS_API_PATH:-"/parfin/rayls-privacy-ops-api"}
OPS_API_ENABLED=${OPS_API_ENABLED:-true}

PARTICIPANT_LIST=${PARTICIPANT_LIST:-A,B}
# Remove quotes from string
PARTICIPANT_LIST=${PARTICIPANT_LIST//\"/}
# Populate PARTICIPANT_NAMES based on PARTICIPANT_LIST
IFS=',' read -r -a PARTICIPANT_NAMES <<< "$PARTICIPANT_LIST"

# echo "PARTICIPANT_LIST=$PARTICIPANT_LIST"
# echo "PARTICIPANT_NAMES=${PARTICIPANT_NAMES[@]}"

# update rayls-privacy-contracts/.env so that it registers the right amount of PARTICIPANTS (PLs)
DEV_MODE=local
BASE_CHAIN_ID=12345  # Starting chainId for the first participant (local environment)

    # Generate participant ChainIDs as a comma-separated string of sequential numbers
    PARTICIPANTS_PN_CHAIN_IDS=""
    for i in "${!PARTICIPANT_NAMES[@]}"; do
        current_chain_id=$((BASE_CHAIN_ID + i))
        PARTICIPANTS_PN_CHAIN_IDS+="${current_chain_id},"
    done

    # Remove the trailing comma
    PARTICIPANTS_PN_CHAIN_IDS=${PARTICIPANTS_PN_CHAIN_IDS%,}

# Check if the variable already exists in the .env file
if grep -q "^PARTICIPANTS=" "${CONTRACTS_PATH}"/.env; then
    # Replace the existing value
    # we can't use sed to update mounted files directly, because it moves them and changes the inode.
    # so instead we're going to use copy to bypass that docker limitation.
    # https://duckduckgo.com/?t=ffab&q=docker+volume+sed%3A+cannot+rename++Device+or+resource+busy&ia=web
    # http://blog.jonathanargentiero.com/docker-sed-cannot-rename-etcsedl8ysxl-device-or-resource-busy/
    # https://unix.stackexchange.com/questions/404189/find-and-sed-string-in-docker-got-error-device-or-resource-busy
    cp "${CONTRACTS_PATH}"/.env /tmp/.env.tmp
    sed -i "s|^PARTICIPANTS=.*|PARTICIPANTS=$PARTICIPANTS_PN_CHAIN_IDS|" /tmp/.env.tmp
    cat /tmp/.env.tmp > "${CONTRACTS_PATH}/.env"
    rm /tmp/.env.tmp
    chown $CUSTOM_UID:$CUSTOM_GID "${CONTRACTS_PATH}/.env"
else
    # Add the variable if it doesn't exist
    echo "PARTICIPANTS=$PARTICIPANTS_PN_CHAIN_IDS" >> "${CONTRACTS_PATH}/.env"
fi

declare -A RELAYER_ENV_FILES
for name in "${PARTICIPANT_NAMES[@]}"; do
    # Populate the associative array with relayer names as keys and .env file paths as values
    FULL_PATH="$RELAYER_PATH/.${name}.env"
    RELAYER_ENV_FILES[$name]="$FULL_PATH"
done

# The loop above will populate RELAYER_ENV_FILES associative array (map) with:
# RELAYER_ENV_FILES={
#     "A" => "$RELAYER_PATH/.A.env"
#     "B" => "$RELAYER_PATH/.B.env"
#     "C" => "$RELAYER_PATH/.C.env"
#     "D" => "$RELAYER_PATH/.D.env"
#     "E" => "$RELAYER_PATH/.E.env"
#     "F" => "$RELAYER_PATH/.F.env"
# }


# Chain RPC URLs for the local docker stack. The audit suite reads these from
# .env at run time (PNH_RPC_URL, PUBLIC_CHAIN_RPC_URL, PRIVACY_NODE_<X>_RPC_URL)
# so operators can run audits without hardhat config knowledge.
pnh_url="http://private-hub:3445"
pc_url="http://public-chain:8845"

# Compute the per-PN RPC URL following the `pn-<lowercase-name>:<854X>`
# docker-service convention used by docker-compose.yml. Echoes the resolved
# URL on stdout. Caller writes it to .env.
compute_pn_url() {
    local pn_name=$1
    local pn_lower
    pn_lower=$(echo "$pn_name" | tr '[:upper:]' '[:lower:]')
    # A=8545, B=8546, ... matches hardhat.config.ts localA-F definitions.
    local pn_idx=$(( $(printf '%d' "'$pn_name") - 65 ))
    echo "http://pn-${pn_lower}:$((8545 + pn_idx))"
}

# Read a key's value from the contracts .env. This shell does not source .env
# (only hardhat reads it via dotenv).
env_get() {
    awk -F= -v k="$1" '$1==k{sub(/^[[:space:]]+/,"",$2);sub(/[[:space:]\r]+$/,"",$2);print $2;exit}' /parfin/rayls-privacy-contracts/.env
}

# Wipe stale sentinel files from any aborted prior run. The wait loop downstream
# reads /tmp/pn_deploy_failed_* and /tmp/pc_deploy_failed_*; a stale file from a
# previous run (killed between sentinel creation and cleanup) would otherwise
# trigger a false-positive failure on the next run.
rm -f /tmp/pn_deploy_failed_* /tmp/pc_deploy_failed_* 2>/dev/null || true

# ─── Helper functions (must be defined before any background fork) ───

# Ensure file ends with a newline before appending
ensure_newline() {
    local file=$1
    if [ -s "$file" ] && [ "$(tail -c 1 "$file" | od -An -tx1 | tr -d ' ')" != "0a" ]; then
        echo "" >> "$file"
    fi
}

# Update or add an environment variable in a file
update_env_var() {
    local env_file=$1
    local var_name=$2
    local var_value=$3

    if grep -q "^$var_name=" "$env_file"; then
        local temp_file="/tmp/.env.tmp.$BASHPID"
        cp "$env_file" "$temp_file"
        sed -i "s|^$var_name=.*|$var_name=$var_value|" "$temp_file"
        cat "$temp_file" > "$env_file"
        rm "$temp_file"
        chown $CUSTOM_UID:$CUSTOM_GID "$env_file"
    else
        ensure_newline "$env_file"
        echo "$var_name=$var_value" >> "$env_file"
        chown $CUSTOM_UID:$CUSTOM_GID "$env_file"
    fi
}

# Pre-compile once: builds with Forge, converts artifacts, generates TypeChain.
# All subsequent `npx hardhat` invocations (PNH + 6 parallel PNs + auth tasks)
# will hit the smart cache and skip the 10s compile overhead.
echo "0.05,Pre-compiling contracts..." > /tmp/deploy_status
echo "Pre-compiling contracts (one-time — all deployments will use cache)..."
npx hardhat compile

# Static audit — every `iface.getFunction('NAME')` reference in the deploy
# code must resolve against the just-compiled artifacts. Catches deploy code
# referencing a function that was renamed/removed since the last deploy.
# Runs BEFORE any chain deploy so a stale string fails fast instead of mid-
# transaction. Under set -e a non-zero exit stops the script.
echo "0.07,Auditing deploy-script selectors..." > /tmp/deploy_status
echo "🔍 Static audit: deploy-script selectors against current ABIs..."
audit_start=$SECONDS
npx hardhat audit:deploy-selectors
echo "   ⏱  audit:deploy-selectors took $((SECONDS - audit_start))s"

# ─── Public chain deployments: start early, run in background ───
# Public chain deployments do NOT depend on PNH or PN deployments.
# They only need the PARTICIPANTS env var (set above) and the public chain RPC.
# Starting them now lets them serialize via their own flock while PNH + PNs deploy.
deploy_public_chain() {
    local RELAYER_NAME=$1
    local HH_PC_NETWORK HH_PC_CHAIN_ID
    # Default to the in-stack local public chain (localPC = public-chain:8845,
    # chain-id 7331). When bridging to an EXTERNAL public chain — PUBLIC_CHAIN_RPC_URL
    # set to anything other than the local public-chain host — use the env-driven
    # `public_chain` hardhat network (built from PUBLIC_CHAIN_RPC_URL/PUBLIC_CHAIN_ID)
    # instead. Otherwise the deploy dials the nonexistent local `public-chain` host
    # and fails with `ENOTFOUND public-chain` on a testnet-bridged stack.
    HH_PC_NETWORK="localPC"
    HH_PC_CHAIN_ID="7331"
    if [ -n "${PUBLIC_CHAIN_RPC_URL:-}" ] && [[ "$PUBLIC_CHAIN_RPC_URL" != *"public-chain:8845"* ]]; then
        HH_PC_NETWORK="public_chain"
        HH_PC_CHAIN_ID="${PUBLIC_CHAIN_ID:-$HH_PC_CHAIN_ID}"
    fi

    echo "Deploying Public Chain contracts for $RELAYER_NAME..."
    set +e
    local pc_deploy_output
    pc_deploy_output=$(./deploy/pcDeployContractsAndUpdateEnvs.sh "$RELAYER_NAME" "$HH_PC_NETWORK" "$HH_PC_CHAIN_ID" 2>&1)
    local pc_deploy_rc=$?
    if [ $pc_deploy_rc -ne 0 ]; then
        echo "❌ Public Chain contracts deployment failed for $RELAYER_NAME (exit $pc_deploy_rc)!"
        echo "$pc_deploy_output"
        touch "/tmp/pc_deploy_failed_${RELAYER_NAME}" 2>/dev/null || true
        return 1
    fi
    echo "✅ Public Chain $RELAYER_NAME deployment completed successfully"

    # Avoid `echo "$big" | grep -m1 ...` — when grep matches early it closes stdin
    # and the upstream process dies with SIGPIPE (exit 141). With `set -o pipefail
    # + set -e`, that randomly aborts the subshell mid-function (~33% failure rate
    # observed on PN-A), leaving env vars unwritten. Use printf with here-string and
    # awk (single process, no pipeline) to extract values deterministically.
    local pc_deployment_registry pc_starting_block
    pc_deployment_registry=$(awk -F= '/^[[:space:]]*PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY=/ {sub(/^[[:space:]]+/,"",$2); sub(/[[:space:]]+$/,"",$2); print $2; exit}' <<< "$pc_deploy_output")
    pc_starting_block=$(awk -F= '/^[[:space:]]*PUBLIC_CHAIN_STARTING_BLOCK=/ {sub(/^[[:space:]]+/,"",$2); sub(/[[:space:]]+$/,"",$2); print $2; exit}' <<< "$pc_deploy_output")
    set -e

    if [ -z "$pc_deployment_registry" ] || [ -z "$pc_starting_block" ]; then
        echo "❌ Error: Could not extract PUBLIC_CHAIN vars for $RELAYER_NAME (DPR='$pc_deployment_registry' BLOCK='$pc_starting_block')"
        touch "/tmp/pc_deploy_failed_${RELAYER_NAME}" 2>/dev/null || true
        return 1
    fi

    local RELAYER_ENV_FILE=${RELAYER_ENV_FILES[$RELAYER_NAME]}
    if [ -z "$RELAYER_ENV_FILE" ]; then
        echo "❌ RELAYER_ENV_FILES[$RELAYER_NAME] is empty — cannot persist public-chain config"
        touch "/tmp/pc_deploy_failed_${RELAYER_NAME}" 2>/dev/null || true
        return 1
    fi
    update_env_var "$RELAYER_ENV_FILE" "PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY" "$pc_deployment_registry"
    update_env_var "$RELAYER_ENV_FILE" "PUBLIC_CHAIN_STARTING_BLOCK" "$pc_starting_block"
    # The CTS (scratch image, no shell to sed its env at startup) reads
    # PUBLIC_CHAIN_RPC_URL from this file. The baked template default points at
    # a chain this stack may not be running (e.g. the local `public-chain`
    # container in a CLI stack that bridges to the Rayls testnet), so when an
    # external public chain is configured overwrite it with the real target.
    if [ -n "${PUBLIC_CHAIN_RPC_URL:-}" ]; then
        update_env_var "$RELAYER_ENV_FILE" "PUBLIC_CHAIN_RPC_URL" "$PUBLIC_CHAIN_RPC_URL"
    fi

    # Post-condition: confirm the keys actually landed in the .X.env file.
    # Without this, a silent write failure would only surface much later as
    # a pubrelayer crash-loop and a stuck relayer waiting for authorization.
    if ! grep -q "^PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY=$pc_deployment_registry$" "$RELAYER_ENV_FILE" \
       || ! grep -q "^PUBLIC_CHAIN_STARTING_BLOCK=$pc_starting_block$" "$RELAYER_ENV_FILE"; then
        echo "❌ Failed to persist PUBLIC_CHAIN_* keys to $RELAYER_ENV_FILE for $RELAYER_NAME"
        touch "/tmp/pc_deploy_failed_${RELAYER_NAME}" 2>/dev/null || true
        return 1
    fi

    (
        flock 200
        update_env_var "${CONTRACTS_PATH}/.env" "PRIVACY_NODE_${RELAYER_NAME}_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY" "$pc_deployment_registry"
        # Also write the PC starting block to contracts .env so the audit's
        # resolveStartingBlock helper can find it (skips the eth_getCode
        # binary search on long-lived chains).
        update_env_var "${CONTRACTS_PATH}/.env" "PRIVACY_NODE_${RELAYER_NAME}_PUBLIC_CHAIN_STARTING_BLOCK" "$pc_starting_block"
        # PUBLIC_CHAIN_RPC_URL is the shared PC URL — same value across all PNs.
        # Idempotent here: every PC deploy iteration writes the same string.
        update_env_var "${CONTRACTS_PATH}/.env" "PUBLIC_CHAIN_RPC_URL" "$pc_url"
    ) 200>/var/lock/contractsenvlockfile

    # On-chain selector audit for this PC's freshly deployed AccessManager.
    # public-chain.ts deploys its own RaylsAccessManagerV1 and wires role
    # mappings on it, same as PNH/PN.
    local pc_audit_start=$SECONDS
    echo "🔍 On-chain audit: PC ($RELAYER_NAME) AccessManager state against current ABIs..."
    npx hardhat audit:pc:onchain-selectors --pn $RELAYER_NAME --registry $pc_deployment_registry
    echo "   ⏱  audit:pc:onchain-selectors (PC $RELAYER_NAME) took $((SECONDS - pc_audit_start))s"
}

PC_PIDS=()
if [ "$PUBLIC_CHAIN_ENABLED" = "true" ]; then
    echo "🔄 Starting public chain deployments in background (parallel with PNH + PNs)..."
    for RELAYER_NAME in "${PARTICIPANT_NAMES[@]}"; do
        deploy_public_chain "$RELAYER_NAME" &
        PC_PIDS+=($!)
    done
fi

# ─── Private Network Hub (PNH) deploy path ───────────────────────────────
# Entire block gated on HUB_ENABLED. When false (start_dev.sh --no-hub) the PNH
# (Besu) container isn't started, so nothing may dial http://private-hub:3445 and
# no PNH_* var may be written to any .env — CTS keys hub-less mode off their absence.
if [ "$HUB_ENABLED" = "true" ]; then
echo "0.1,Deploying Private Network Hub contracts..." > /tmp/deploy_status

# Deploy Private Network Hub contracts
echo "Deploying Private Network Hub contracts..."
PNH_NETWORK_NAME="localPNH"

set +e
pnh_deploy_output=$(npx hardhat deploy:private-hub --network $PNH_NETWORK_NAME 2>&1)
# check if exit code was error or success
if [ $? -ne 0 ]; then
    echo "❌ Private Network Hub contracts deployment failed!"
    echo "$pnh_deploy_output"
    exit 1
else
    echo "✅ Private Network Hub deployment completed successfully"
fi
set -e

echo "Private Network Hub contracts deployed."

echo "0.5,Updating configs" > /tmp/deploy_status

# Extract Relayer config lines from the deployment output
pnh_relayer_config=$(echo "$pnh_deploy_output" | sed -n "/👉 Relayer Configuration 👈/,/===========================================/p")

PNH_DEPLOY_VARS=$(echo "$pnh_relayer_config" | grep -oE '[A-Za-z0-9_]+=[^ ]+')

# Check if any variables were found
if [ -z "$PNH_DEPLOY_VARS" ]; then
    echo "❌ No relayer variables found in the deployment output."
    echo "Config extraction failed. Check deployment logs above."
    exit 2
fi

# Update Governance configuration
if [ "$GOVERNANCE_ENABLED" = "true" ]; then
    echo "DEBUG: GOVERNANCE_ENABLED is true, extracting governance config..."

    # Extract Governance config lines from the deployment output
    governance_config=$(echo "$pnh_deploy_output" | sed -n "/👉 Governance, Listener & Flagger Configuration 👈/,/===========================================/p")

    echo "DEBUG: Extracted governance config section:"
    echo "$governance_config"
    echo "DEBUG: End of governance config section"

    GOVERNANCE_DEPLOY_VARS=$(echo "$governance_config" | grep -oE '[A-Za-z0-9_]+=[^ ]+')

    echo "DEBUG: Extracted variables:"
    echo "$GOVERNANCE_DEPLOY_VARS"
    echo "DEBUG: End of variables"

    # Check if any variables were found
    if [ -z "$GOVERNANCE_DEPLOY_VARS" ]; then
        echo "ERROR: No governance variables found in the deployment output."
        echo "DEBUG: Full deployment output:"
        echo "$pnh_deploy_output"
        exit 1
    fi

    # Create an associative array with all the vars and values
    declare -A governance_deploy_vars_map
    while IFS='=' read -r key value; do
        governance_deploy_vars_map[$key]=$value
    done <<< "$GOVERNANCE_DEPLOY_VARS"

    echo "Parsed ${#governance_deploy_vars_map[@]} governance variables"

    # Write variables to governance .env file
    GOVERNANCE_ENV_FILE="$GOVERNANCE_PATH/.env"

    echo "DEBUG: GOVERNANCE_PATH=$GOVERNANCE_PATH"
    echo "DEBUG: GOVERNANCE_ENV_FILE=$GOVERNANCE_ENV_FILE"
    echo "DEBUG: Checking if file exists..."
    if [ -f "$GOVERNANCE_ENV_FILE" ]; then
        echo "DEBUG: File exists"
    else
        echo "DEBUG: File does not exist, will be created"
        touch "$GOVERNANCE_ENV_FILE"
        chown $CUSTOM_UID:$CUSTOM_GID "$GOVERNANCE_ENV_FILE"
    fi

    for VAR_NAME in "${!governance_deploy_vars_map[@]}"; do
        VAR_VALUE=${governance_deploy_vars_map[$VAR_NAME]}

        echo "DEBUG: Writing $VAR_NAME=$VAR_VALUE"

        # Check if the variable already exists in the .env file
        if grep -q "^$VAR_NAME=" "$GOVERNANCE_ENV_FILE"; then
            # Replace the existing value (Docker-safe: use temp file to avoid "Resource busy" error)
            echo "DEBUG: Variable exists, updating..."
            cp "$GOVERNANCE_ENV_FILE" /tmp/.governance_env.tmp
            sed -i "s|^$VAR_NAME=.*|$VAR_NAME=$VAR_VALUE|" /tmp/.governance_env.tmp
            cat /tmp/.governance_env.tmp > "$GOVERNANCE_ENV_FILE"
            rm /tmp/.governance_env.tmp
            chown $CUSTOM_UID:$CUSTOM_GID "$GOVERNANCE_ENV_FILE"
        else
            # Add the variable if it doesn't exist
            echo "DEBUG: Variable doesn't exist, adding..."
            echo "$VAR_NAME=$VAR_VALUE" >> "$GOVERNANCE_ENV_FILE"
            chown $CUSTOM_UID:$CUSTOM_GID "$GOVERNANCE_ENV_FILE"
        fi
    done

    # Add/update URL in governance .env
    if grep -q "^PNH_RPC_URL=" "$GOVERNANCE_ENV_FILE"; then
        cp "$GOVERNANCE_ENV_FILE" /tmp/.governance_env.tmp
        sed -i "s|^PNH_RPC_URL=.*|PNH_RPC_URL=$pnh_url|" /tmp/.governance_env.tmp
        cat /tmp/.governance_env.tmp > "$GOVERNANCE_ENV_FILE"
        rm /tmp/.governance_env.tmp
        chown $CUSTOM_UID:$CUSTOM_GID "$GOVERNANCE_ENV_FILE"
    else
        echo "PNH_RPC_URL=$pnh_url" >> "$GOVERNANCE_ENV_FILE"
        chown $CUSTOM_UID:$CUSTOM_GID "$GOVERNANCE_ENV_FILE"
    fi

    echo "Updated Governance API .env file with ${#governance_deploy_vars_map[@]} variables and URL=$pnh_url"
fi

# Create an associative array with all the vars and values
declare -A pnh_deploy_vars_map
while IFS='=' read -r key value; do
  pnh_deploy_vars_map[$key]=$value
done <<< "$PNH_DEPLOY_VARS"

# Update the /parfin/raylz-relayer/.X.env files
for RELAYER_ENV_FILE in "${RELAYER_ENV_FILES[@]}"; do
    
    for VAR_NAME in "${!pnh_deploy_vars_map[@]}"; do
        VAR_VALUE=${pnh_deploy_vars_map[$VAR_NAME]}

        # update_env_var, not sed -i: these files live on a Docker volume, where
        # sed's rename-in-place fails with "Device or resource busy".
        update_env_var "$RELAYER_ENV_FILE" "$VAR_NAME" "$VAR_VALUE"
    done
done

# Extract Contracts config lines from the deployment output
pnh_contracts_config=$(echo "$pnh_deploy_output" | sed -n "/👉 Contracts Configuration 👈/,/===========================================/p")

PNH_DEPLOY_CONTRACTS_VARS=$(echo "$pnh_contracts_config" | grep -oE '[A-Za-z0-9_]+=[^ ]+')

# Check if any variables were found
if [ -z "$PNH_DEPLOY_CONTRACTS_VARS" ]; then
    echo "❌ No contract variables found in the deployment output."
    echo "Config extraction failed. Check deployment logs above."
    exit 2
fi

# Create an associative array with all the vars and values
declare -A pnh_deploy_contracts_vars_map
while IFS='=' read -r key value; do
    pnh_deploy_contracts_vars_map[$key]=$value
done <<< "$PNH_DEPLOY_CONTRACTS_VARS"

## Update contracts .env with contracts variables (Docker-safe: single temp write)
# we can't use sed to update mounted files directly, because it moves them and changes the inode.
# so instead we're going to use copy to bypass that docker limitation.
# https://duckduckgo.com/?t=ffab&q=docker+volume+sed%3A+cannot+rename++Device+or+resource+busy&ia=web
# http://blog.jonathanargentiero.com/docker-sed-cannot-rename-etcsedl8ysxl-device-or-resource-busy/
# https://unix.stackexchange.com/questions/404189/find-and-sed-string-in-docker-got-error-device-or-resource-busy
cp "${CONTRACTS_PATH}/.env" /tmp/.env.tmp

for VAR_NAME in "${!pnh_deploy_contracts_vars_map[@]}"; do
    VAR_VALUE=${pnh_deploy_contracts_vars_map[$VAR_NAME]}

    # Check if the variable already exists in the temp .env file
    if grep -q "^$VAR_NAME=" /tmp/.env.tmp; then
        sed -i "s|^$VAR_NAME=.*|$VAR_NAME=$VAR_VALUE|" /tmp/.env.tmp
    else
        # Add the variable if it doesn't exist
        echo "$VAR_NAME=$VAR_VALUE" >> /tmp/.env.tmp
    fi
done

cat /tmp/.env.tmp > "${CONTRACTS_PATH}/.env"
rm /tmp/.env.tmp
chown $CUSTOM_UID:$CUSTOM_GID "${CONTRACTS_PATH}/.env"

# Persist the PNH RPC URL so the audit suite can read it from .env without
# needing --network. External operators populate this themselves.
update_env_var "/parfin/rayls-privacy-contracts/.env" "PNH_RPC_URL" "$pnh_url"

echo "Updated .env file with Private Network Hub contract proxy values."

# Activate PNH business roles (NETWORK_OPERATOR, NETWORK_AUDITOR, COMPLIANCE_OFFICER, TOKEN_MANAGER)
# Pass registry address explicitly — .env may not yet reflect the fresh deployment.
PNH_REGISTRY=${pnh_deploy_contracts_vars_map[PNH_DEPLOYMENT_PROXY_REGISTRY]}
echo "🔐 Activating PNH business roles (registry=$PNH_REGISTRY)..."
npx hardhat activate-business-roles-pnh --registry-address $PNH_REGISTRY --network $PNH_NETWORK_NAME 2>&1
echo "✅ PNH business roles activated"

# Verify the fresh PNH AccessManager state matches the just-compiled ABIs.
# STALE here means the deploy code's role-mapping calls reference a function
# that no longer exists on the target — a real bug, not a deploy environment
# issue.
echo "0.55,Auditing PNH on-chain selectors..." > /tmp/deploy_status
echo "🔍 On-chain audit: PNH AccessManager state against current ABIs..."
audit_start=$SECONDS
npx hardhat audit:pnh:onchain-selectors --registry $PNH_REGISTRY
echo "   ⏱  audit:pnh:onchain-selectors took $((SECONDS - audit_start))s"
else
    echo "0.5,Skipping Private Network Hub deploy (HUB_ENABLED=false)" > /tmp/deploy_status
    echo "⏭️  HUB_ENABLED=false — skipping PNH deploy, business roles, and PNH_* env writes"
fi
# ─── End Private Network Hub (PNH) deploy path ───────────────────────────

if [ "$PUBLIC_CHAIN_ENABLED" = "true" ]; then
    echo "0.6,Deploying Privacy Node and Public Chain contracts..." > /tmp/deploy_status
    # Deploy Privacy Node and Public Chain contracts
    echo "Deploying Privacy Node and Public Chain contracts..."
else
    echo "0.6,Deploying Privacy Node contracts (public chain disabled)..." > /tmp/deploy_status
    # Deploy only Privacy Node contracts
    echo "Deploying Privacy Node contracts (PUBLIC_CHAIN_ENABLED=false)..."
fi

deploy_relayer() {
    local RELAYER_NAME=$1
    local PN_NETWORK_NAME RELAYER_INDEX
    local pn_deploy_output pn_config PN_DEPLOY_VARS RELAYER_ENV_FILE
    local VAR_NAME VAR_VALUE deployment_proxy_registry
    local rayls_node_endpoint endpoint rayls_node_user_governance
    local token_registry token_core token_freeze_manager
    local deploymentRegistry
    echo "Deploying contracts into Privacy Node $RELAYER_NAME..."
    PN_NETWORK_NAME="local$RELAYER_NAME"

    # Wrap hardhat with a per-attempt timeout + retry. Hardhat occasionally wedges on
    # tx receipt polling when an RPC request is dropped or a tx is silently evicted
    # from the txpool — `tx.wait()` then polls forever. Killing the process and
    # restarting hardhat with a fresh nonce manager recovers reliably; the
    # NONCE_EXPIRED guard in batch-helpers.ts handles any txs that did mine.
    local PN_DEPLOY_TIMEOUT=${PN_DEPLOY_TIMEOUT:-420}
    local PN_DEPLOY_MAX_ATTEMPTS=${PN_DEPLOY_MAX_ATTEMPTS:-3}
    local pn_deploy_rc=0
    # Derive this PN's chainId so we can scope the per-attempt manifest
    # cleanup below to ONLY this PN's file — sibling PNs are deploying in
    # parallel against their own chainIds and we must not touch their
    # manifests.
    local pn_index pn_chainid pn_manifest
    # RELAYER_NAME is always a single uppercase letter A..Z (set by the
    # caller). printf '%d' "'X" prints the decimal ASCII codepoint of the
    # first character of "X", so subtracting 65 ('A') yields a zero-based
    # index: A->0, B->1, ..., F->5.
    pn_index=$(( $(printf '%d' "'$RELAYER_NAME") - 65 ))
    pn_chainid=$((BASE_CHAIN_ID + pn_index))
    pn_manifest=".openzeppelin/unknown-${pn_chainid}.json"
    set +e
    for attempt in $(seq 1 $PN_DEPLOY_MAX_ATTEMPTS); do
        # If a previous attempt wrote the OpenZeppelin manifest then
        # exited non-zero, hardhat-upgrades will refuse to redeploy with
        # "Cannot deploy: manifest already exists. Delete it first to
        # redeploy." (privacy-node.ts:56). Cleaning the per-chainId
        # file before each retry is the supported recovery path —
        # we're starting the deploy from scratch anyway.
        if [ $attempt -gt 1 ] && [ -f "$pn_manifest" ]; then
            echo "  ↺ Privacy Node $RELAYER_NAME: removing stale manifest $pn_manifest before retry"
            rm -f "$pn_manifest" 2>/dev/null || true
        fi
        pn_deploy_output=$(timeout --signal=KILL ${PN_DEPLOY_TIMEOUT}s npx hardhat deploy:privacy-node --network $PN_NETWORK_NAME --privacy-node $RELAYER_NAME 2>&1)
        pn_deploy_rc=$?
        if [ $pn_deploy_rc -eq 0 ]; then
            [ $attempt -gt 1 ] && echo "  ↻ Privacy Node $RELAYER_NAME succeeded on attempt $attempt"
            break
        fi
        if [ $pn_deploy_rc -eq 137 ]; then
            # timeout --signal=KILL produces 137 (SIGKILL); plain SIGTERM would produce 124,
            # but we use --signal=KILL so 124 is unreachable.
            echo "⚠️  Privacy Node $RELAYER_NAME hardhat hung — killed after ${PN_DEPLOY_TIMEOUT}s (attempt $attempt/$PN_DEPLOY_MAX_ATTEMPTS)"
        else
            echo "⚠️  Privacy Node $RELAYER_NAME deploy exited $pn_deploy_rc (attempt $attempt/$PN_DEPLOY_MAX_ATTEMPTS)"
        fi
        [ $attempt -lt $PN_DEPLOY_MAX_ATTEMPTS ] && sleep 5
    done
    if [ $pn_deploy_rc -ne 0 ]; then
        echo "❌ Privacy Node $RELAYER_NAME deployment failed after $PN_DEPLOY_MAX_ATTEMPTS attempts!"
        echo "$pn_deploy_output"
        # Sentinel for the parent script's wait loop to detect partial failures.
        touch "/tmp/pn_deploy_failed_${RELAYER_NAME}" 2>/dev/null || true
        exit 3
    else
        echo "✅ Privacy Node $RELAYER_NAME deployment completed successfully"
    fi
    set -e

    # SIGPIPE-immune extraction: a single awk process reads from a here-string,
    # extracts the Relayer Configuration block, and emits VAR=VALUE lines.
    # Avoids `echo $big | sed | grep | sed` pipelines whose upstream processes
    # die with SIGPIPE if a downstream closes early — under set -e + pipefail
    # that randomly aborts the deploy_relayer subshell mid-function.
    pn_config=$(awk '/👉👉👉👉 Relayer Configuration 👈👈👈👈/,/==========================================/' <<< "$pn_deploy_output")
    # POSIX-safe extract: strip leading whitespace, print the first field (KEY=VAL).
    # Lines without a KEY= match are filtered by the regex guard.
    PN_DEPLOY_VARS=$(awk '/^[[:space:]]*[A-Za-z0-9_]+=[^[:space:]]+/ { sub(/^[[:space:]]+/, ""); print $1 }' <<< "$pn_config")

    # Check if any variables were found
    if [ -z "$PN_DEPLOY_VARS" ]; then
        echo "❌ No upgrade variables found in the deployment output for $RELAYER_NAME"
        echo "Config extraction failed. Check deployment logs above."
        touch "/tmp/pn_deploy_failed_${RELAYER_NAME}" 2>/dev/null || true
        exit 4
    fi

    # Create an associative lookup from the KEY=VALUE lines printed by the PN
    # deploy task. Later contracts .env updates read from this map
    # instead of re-parsing pn_deploy_output with separate grep/cut pipelines.
    declare -A pn_deploy_vars_map
    while IFS='=' read -r key value; do
        pn_deploy_vars_map[$key]=$value
    done <<< "$PN_DEPLOY_VARS"

    RELAYER_ENV_FILE=${RELAYER_ENV_FILES[$RELAYER_NAME]}

    # Registry address for the role-activation + on-chain audit tasks below.
    # The subshell at the bottom of this function assigns a same-valued
    # `deploymentRegistry`, but that stays trapped in the subshell — capture it
    # here in function scope so lines 791/798 get a non-empty --registry-address.
    deployment_proxy_registry=${pn_deploy_vars_map[PRIVACY_NODE_DEPLOYMENT_PROXY_REGISTRY]}

    for VAR_NAME in "${!pn_deploy_vars_map[@]}"; do
        VAR_VALUE=${pn_deploy_vars_map[$VAR_NAME]}

        # update_env_var, not sed -i: these files live on a Docker volume, where
        # sed's rename-in-place fails with "Device or resource busy".
        update_env_var "$RELAYER_ENV_FILE" "$VAR_NAME" "$VAR_VALUE"
    done

    echo "Updated Relayer's .${RELAYER_NAME}.env with contract proxy values."

    # Update contracts .env with PRIVACY_NODE_<X>_ENDPOINT_ADDRESS and Rayls Node variables
    # Check if the variable already exists in the /parfin/rayls-contracts/ file
    (
        # use file lock to ensure consistency writting to .env file, because
        # this function is executed in parallel
        flock 200
        update_contracts_env_var() {
            local name=$1
            local value=$2

            if grep -q "^${name}=" "${CONTRACTS_PATH}/.env"; then
                # Replace the existing value.
                # We can't use sed to update mounted files directly because it moves
                # them and changes the inode, which fails on some Docker mounts.
                # Copy to a temporary file, update there, then stream the result back
                # into the mounted file to preserve the original inode.
                # https://duckduckgo.com/?t=ffab&q=docker+volume+sed%3A+cannot+rename++Device+or+resource+busy&ia=web
                # http://blog.jonathanargentiero.com/docker-sed-cannot-rename-etcsedl8ysxl-device-or-resource-busy/
                # https://unix.stackexchange.com/questions/404189/find-and-sed-string-in-docker-got-error-device-or-resource-busy
                cp "${CONTRACTS_PATH}/.env" /tmp/.env.tmp
                sed -i "s|^${name}=.*|${name}=${value}|" /tmp/.env.tmp
                cat /tmp/.env.tmp > "${CONTRACTS_PATH}/.env"
                rm /tmp/.env.tmp
                chown $CUSTOM_UID:$CUSTOM_GID "${CONTRACTS_PATH}/.env"
            else
                # Add the variable if it doesn't exist.
                echo "${name}=${value}" >> "${CONTRACTS_PATH}/.env"
            fi
        }

        # Extract endpoint addresses from deployment output
        rayls_node_endpoint=${pn_deploy_vars_map[PRIVACY_NODE_${RELAYER_NAME}_RAYLS_NODE_ENDPOINT_ADDRESS]:-}
        endpoint=${pn_deploy_vars_map[PRIVACY_NODE_${RELAYER_NAME}_ENDPOINT_ADDRESS]:-}
        # Fallback: if ENDPOINT_ADDRESS wasn't printed, use RAYLS_NODE_ENDPOINT_ADDRESS (backward compat)
        endpoint=${endpoint:-$rayls_node_endpoint}

        # Extract Rayls Node and Token Registry variables from the deployment output
        rayls_node_user_governance=${pn_deploy_vars_map[PRIVACY_NODE_${RELAYER_NAME}_RAYLS_NODE_USER_GOVERNANCE]:-}
        token_registry=${pn_deploy_vars_map[PRIVACY_NODE_${RELAYER_NAME}_TOKEN_REGISTRY_ADDRESS]:-}
        token_core=${pn_deploy_vars_map[PRIVACY_NODE_${RELAYER_NAME}_TOKEN_CORE_ADDRESS]:-}
        token_freeze_manager=${pn_deploy_vars_map[PRIVACY_NODE_${RELAYER_NAME}_TOKEN_FREEZE_MANAGER_ADDRESS]:-}

        update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_ENDPOINT_ADDRESS" "$endpoint"

        deploymentRegistry=${pn_deploy_vars_map[PRIVACY_NODE_DEPLOYMENT_PROXY_REGISTRY]}
        update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_DEPLOYMENT_PROXY_REGISTRY" "$deploymentRegistry"
        update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_RAYLS_NODE_ENDPOINT_ADDRESS" "$rayls_node_endpoint"
        update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_RAYLS_NODE_USER_GOVERNANCE" "$rayls_node_user_governance"

        if [ -n "$token_registry" ]; then
            update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_TOKEN_REGISTRY_ADDRESS" "$token_registry"
        fi

        # Update PRIVACY_NODE_<X>_STARTING_BLOCK (consumed by the audit's
        # resolveStartingBlock fallback ladder; skips the eth_getCode binary
        # search on long-lived chains).
        local pn_starting_block
        pn_starting_block=$(echo "$pn_deploy_output" | grep "PRIVACY_NODE_${RELAYER_NAME}_STARTING_BLOCK=" | tail -1 | cut -d'=' -f2 | tr -d ' \r')
        if [ -n "$pn_starting_block" ]; then
            update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_STARTING_BLOCK" "$pn_starting_block"
        fi

        # Update PRIVACY_NODE_<X>_ACCESS_MANAGER_STARTING_BLOCK (the chain tip captured
        # just before the AccessManager deploy; <= the AM deploy block). start_dev.sh
        # reads this to seed the ops-worker's AM role-event indexer so it backfills from
        # deploy-time instead of genesis. Distinct from _STARTING_BLOCK above, which is
        # captured post-deploy for the audit suite.
        local pn_am_starting_block
        pn_am_starting_block=$(echo "$pn_deploy_output" | grep "PRIVACY_NODE_${RELAYER_NAME}_ACCESS_MANAGER_STARTING_BLOCK=" | tail -1 | cut -d'=' -f2 | tr -d ' \r')
        if [ -n "$pn_am_starting_block" ]; then
            update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_ACCESS_MANAGER_STARTING_BLOCK" "$pn_am_starting_block"
        fi

        # Write the PN's RPC URL so the audit suite resolves it from .env.
        local pn_rpc_url
        pn_rpc_url=$(compute_pn_url "$RELAYER_NAME")
        if [ -n "$pn_rpc_url" ]; then
            update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_RPC_URL" "$pn_rpc_url"
        fi
        if [ -n "$token_core" ]; then
            update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_TOKEN_CORE_ADDRESS" "$token_core"
        fi
        if [ -n "$token_freeze_manager" ]; then
            update_contracts_env_var "PRIVACY_NODE_${RELAYER_NAME}_TOKEN_FREEZE_MANAGER_ADDRESS" "$token_freeze_manager"
        fi

    ) 200>/var/lock/contractsenvlockfile

    # NOTE: Public chain deployment for this participant is started in background
    # at the top of this script (see deploy_public_chain function) and runs in
    # parallel with PNH + PN deployments. We wait for all PC deployments to
    # complete after the per-relayer loop finishes.

    # Activate PN business roles (OPERATOR, BANK_EMPLOYEE, AUDITOR, COMPLIANCE_OFFICER)
    # Pass registry address explicitly — .env may not reflect the fresh deployment yet.
    echo "🔐 Activating business roles for Privacy Node $RELAYER_NAME (registry=$deployment_proxy_registry)..."
    npx hardhat activate-business-roles-pn --pn $RELAYER_NAME --registry-address $deployment_proxy_registry --network $PN_NETWORK_NAME 2>&1
    echo "✅ PN $RELAYER_NAME business roles activated"

    # On-chain selector audit for this PN's freshly deployed AccessManager.
    # Runs inside the per-PN background fork — every PN audits in parallel.
    local pn_audit_start=$SECONDS
    echo "🔍 On-chain audit: PN $RELAYER_NAME AccessManager state against current ABIs..."
    npx hardhat audit:pn:onchain-selectors --pn $RELAYER_NAME --registry $deployment_proxy_registry
    echo "   ⏱  audit:pn:onchain-selectors (PN $RELAYER_NAME) took $((SECONDS - pn_audit_start))s"
}

# Function to wait for a URL to be ready with exponential backoff
wait_for_url_ready() {
    local url=$1
    local service_name=${2:-"Service"}
    local max_attempts=60  # 10 minutes max wait
    local attempt=1
    local wait_time=5
    local curl_output curl_exit_code

    echo "Starting health check for $service_name on $url..."

    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt/$max_attempts: Checking $service_name health..."
        echo "Testing URL: $url"
        # Make curl robust under set -e: temporarily disable errexit for the probe
        set +e
        curl_output=$(curl -f -s --max-time 5 --connect-timeout 3 "$url" 2>&1)
        curl_exit_code=$?
        set -e
        echo "Curl exit code: $curl_exit_code"

        if [ $curl_exit_code -eq 0 ]; then
            echo "✅ $service_name is healthy! Response received"
            return 0
        else
            case "$curl_exit_code" in
                6)
                    echo "❌ Curl DNS resolution failed (code 6). The host may not be resolvable yet. Output: $curl_output"
                    ;;
                7)
                    echo "❌ Curl failed to connect (code 7). Service might not be listening yet. Output: $curl_output"
                    ;;
                28)
                    echo "❌ Curl timed out (code 28). The service may still be starting. Output: $curl_output"
                    ;;
                *)
                    echo "❌ Curl failed (code $curl_exit_code). Output: $curl_output"
                    ;;
            esac
        fi

        if [ $attempt -eq $max_attempts ]; then
            echo "❌ Timeout waiting for $service_name to become healthy after $max_attempts attempts"
            return 1
        fi

        echo "$service_name not ready yet. Waiting ${wait_time}s before next attempt..."
        sleep $wait_time

        # Exponential backoff up to 30s max
        wait_time=$((wait_time < 30 ? wait_time + 2 : 30))
        attempt=$((attempt + 1))
    done
}

prepare_participant_for_authorization() {
    local PARTICIPANT_NAME=$1
    local relayer_index=0

    participant_index=$(( $(printf '%d' "'$PARTICIPANT_NAME") - 65 )) # The ASCII position of A is 65

    local participant_name_lower=$(echo "$PARTICIPANT_NAME" | tr '[:upper:]' '[:lower:]')
    # Base URL of this participant's CTS HTTP server. CTS_SERVICE_<P>_URL wins
    # when set (the Rayls CLI runs every CTS on container port 8090 behind
    # per-participant DNS aliases and passes these vars — the same ones
    # add-authorized-relayers already reads); the 8090+index fallback matches
    # the relayer repo's dev compose, where each cts-<p> binds its own port.
    local cts_url_var="CTS_SERVICE_${PARTICIPANT_NAME}_URL"
    local cts_base_url="${!cts_url_var:-}"
    if [ -z "$cts_base_url" ]; then
        local cts_internal_port=$((8090 + participant_index))
        cts_base_url="http://cts-${participant_name_lower}:${cts_internal_port}"
    fi
    local cts_url="${cts_base_url%/}/health"

    echo "Starting authorization monitoring for CTS $PARTICIPANT_NAME on $cts_url..."

    if ! wait_for_url_ready "$cts_url" "CTS $PARTICIPANT_NAME"; then
        echo "1.2,Authorization failed for participant $PARTICIPANT_NAME" > /tmp/deploy_status
        return 1
    fi
    return 0
}

# Run a relayer-authorization hardhat command with retry + backoff on TRANSIENT
# RPC failures. A single dropped connection to a PN (socket hang
# up, a momentary network blip, "failed to detect network") otherwise leaves that PN's
# relayers unauthorized — and its CTS then hangs forever in "Waiting for addresses to
# be authorized". We retry only on network-shaped failures; a genuine error (bad role,
# revert) fails fast so we don't loop pointlessly. The command's combined output is
# placed in AUTH_RETRY_OUTPUT; the function returns the last exit code.
run_auth_with_retry() {
    local label=$1; shift
    local max=${AUTH_MAX_ATTEMPTS:-5}
    local backoff=5
    local rc=0 attempt
    set +e
    for attempt in $(seq 1 "$max"); do
        AUTH_RETRY_OUTPUT=$("$@" 2>&1)
        rc=$?
        if [ $rc -eq 0 ]; then
            [ "$attempt" -gt 1 ] && echo "  ↻ $label succeeded on attempt $attempt/$max"
            set -e
            return 0
        fi
        if echo "$AUTH_RETRY_OUTPUT" | grep -qiE "socket hang up|failed to detect network|could not detect network|ETIMEDOUT|ECONNRESET|ECONNREFUSED|EAI_AGAIN|getaddrinfo|network timeout|timeout of [0-9]|503 Service|connection (refused|reset|timed out)"; then
            echo "⚠️  $label hit a transient RPC error (attempt $attempt/$max, exit $rc) — retrying in ${backoff}s"
            if [ "$attempt" -lt "$max" ]; then
                sleep "$backoff"
                backoff=$(( backoff * 2 )); [ "$backoff" -gt 40 ] && backoff=40
                continue
            fi
            echo "  ✗ $label still failing after $max attempts (transient errors)"
        else
            echo "  ✗ $label failed with a non-transient error (exit $rc) — not retrying"
            break
        fi
    done
    set -e
    return $rc
}

# Function to authorize relayer after it's operational
authorize_participant_async() {
    local RELAYER_NAME=$1
    
    prepare_participant_for_authorization "$RELAYER_NAME"
    if [ $? -ne 0 ]; then
        echo "Authorization preparation failed for relayer $RELAYER_NAME" > /tmp/deploy_status
        return 1
    fi

    # Update status to show we're authorizing this specific relayer
    echo "1.1,Authorizing participant $RELAYER_NAME..." > /tmp/deploy_status

    # Local PN network (aligns with deploy_relayer). Declared at function scope
    # so it survives the `( flock 200 ... )` subshell
    # below — the post-authorization audit step (outside the subshell) needs it.
    # Without this, `set -u` aborts the deploy with "network_name: unbound variable".
    local network_name RELAYER_INDEX
    network_name="local$RELAYER_NAME"

    # Use flock to ensure only one process executes hardhat tasks at a time
    # As of now, the private keys used for public-chain and private-network-hub are the same for all relayers
    # So we need to ensure only one process executes hardhat tasks at a time to avoid conflicts
    (
        flock 200

        # Run the hardhat task to authorize relayers
        echo "Running authorization for relayer $RELAYER_NAME..."

        local auth_output auth_exit_code
        local auth_output_pnh auth_exit_code_pnh

        local hh_cmd=(npx hardhat add-authorized-relayers --pn "$RELAYER_NAME" --with-public-relayer "$PUBLIC_CHAIN_ENABLED" --network "$network_name")

        auth_exit_code=0
        run_auth_with_retry "PN-side auth ($RELAYER_NAME)" "${hh_cmd[@]}" || auth_exit_code=$?
        auth_output=$AUTH_RETRY_OUTPUT

        if [ $auth_exit_code -eq 0 ]; then
            echo "✅ Successfully authorized relayers for $RELAYER_NAME"
            echo "$auth_output"
            echo "Relayer $RELAYER_NAME authorization completed successfully." >> /tmp/auth_results
        else
            echo "❌ Failed to authorize relayers for $RELAYER_NAME"
            echo "$auth_output"
            echo "Relayer $RELAYER_NAME authorization failed: $auth_output" >> /tmp/auth_results
            echo "1.2,Authorization failed for $RELAYER_NAME" > /tmp/deploy_status
            return 1
        fi

        # PNH-side authorization is skipped in hub-less mode (no PNH to authorize on).
        if [ "$HUB_ENABLED" = "true" ]; then
        local hh_cmd_pnh=(npx hardhat add-authorized-relayers-pnh --privacy-nodes "$RELAYER_NAME" --rpc-url "$pnh_url" --network "$PNH_NETWORK_NAME")

        echo "Running authorization for relayer $RELAYER_NAME in Private Network Hub..."

        auth_exit_code_pnh=0
        run_auth_with_retry "PNH-side auth ($RELAYER_NAME)" "${hh_cmd_pnh[@]}" || auth_exit_code_pnh=$?
        auth_output_pnh=$AUTH_RETRY_OUTPUT

        if [ $auth_exit_code_pnh -eq 0 ]; then
            echo "✅ Successfully authorized relayer $RELAYER_NAME in Private Network Hub"
            echo "$auth_output_pnh"
            echo "Relayer $RELAYER_NAME authorization in Private Network Hub completed successfully." >> /tmp/auth_results
        else
            echo "❌ Failed to authorize relayer $RELAYER_NAME in Private Network Hub"
            echo "$auth_output_pnh"
            echo "Relayer $RELAYER_NAME authorization in Private Network Hub failed: $auth_output_pnh" >> /tmp/auth_results
            echo "1.2,Authorization failed for relayer $RELAYER_NAME in Private Network Hub" > /tmp/deploy_status
            return 1
        fi
        fi

        echo "Relayer $RELAYER_NAME authorization completed successfully"
        return 0
    ) 200>/var/lock/relayauthorizationlockfile

    # ─── Post-authorization audit (per-PN scopes only) ───────────────────
    # Verify the RELAYER role grants we just made on this PN's own chain
    # (and, if public chain is enabled, on its per-PN PC AccessManager).
    # Read-only — runs outside the flock so all relayers' audits proceed in
    # parallel. The deploy fails if any audit finds MISSING or UNEXPECTED
    # grants. The PNH (shared chain) audit is NOT done here — it must run
    # once after every PN has been authorized to know the full expected set;
    # see the post-AUTH_PIDS-wait block at the bottom of this script.
    local relayer_env_file=${RELAYER_ENV_FILES[$RELAYER_NAME]}
    local pn_registry
    pn_registry=$(grep "^PRIVACY_NODE_DEPLOYMENT_PROXY_REGISTRY=" "$relayer_env_file" | cut -d= -f2 | tr -d ' \r' || true)

    # PC network mirrors deploy_public_chain's selection.
    local hh_pc_network
    hh_pc_network="localPC"
    if [ -n "${PUBLIC_CHAIN_RPC_URL:-}" ] && [[ "$PUBLIC_CHAIN_RPC_URL" != *"public-chain:8845"* ]]; then
        hh_pc_network="public_chain"
    fi

    # PN registry must exist by this point — `deploy_relayer` writes it to
    # the relayer env file before completing. Empty-check is defensive: if
    # something corrupted the env file mid-deploy, we'd rather fail loudly
    # here than pass `--registry ""` to the audit (which under set -e would
    # kill the subshell with a less-actionable error message).
    if [ -z "$pn_registry" ]; then
        echo "❌ Cannot audit PN role grants for $RELAYER_NAME — PRIVACY_NODE_DEPLOYMENT_PROXY_REGISTRY missing from $relayer_env_file"
        echo "   (deploy_relayer should have written this; the env file may be corrupted)"
        return 1
    fi
    local audit_start=$SECONDS
    echo "🔍 Auditing relayer roles for $RELAYER_NAME (PN side)..."
    npx hardhat audit:pn:roles \
        --pn "$RELAYER_NAME" \
        --registry "$pn_registry" \
        --with-public-relayer "$PUBLIC_CHAIN_ENABLED"
    echo "   ⏱  audit:pn:roles (PN $RELAYER_NAME) took $((SECONDS - audit_start))s"

    if [ "$PUBLIC_CHAIN_ENABLED" = "true" ]; then
        local pc_registry
        pc_registry=$(grep "^PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY=" "$relayer_env_file" | cut -d= -f2 | tr -d ' \r' || true)
        if [ -n "$pc_registry" ]; then
            audit_start=$SECONDS
            echo "🔍 Auditing relayer roles for $RELAYER_NAME (PC side)..."
            npx hardhat audit:pc:roles \
                --pn "$RELAYER_NAME" \
                --registry "$pc_registry"
            echo "   ⏱  audit:pc:roles ($RELAYER_NAME) took $((SECONDS - audit_start))s"
        else
            echo "⚠️  Skipping PC role audit for $RELAYER_NAME — PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY not found in $relayer_env_file"
        fi
    fi
}


# Create an array to hold PIDs of background processes
PIDS=()

for RELAYER_NAME in "${PARTICIPANT_NAMES[@]}"; do
    deploy_relayer "$RELAYER_NAME" &
    PIDS+=($!)
done

# Wait for all PN deployments to complete
wait "${PIDS[@]}"
# Each deploy_relayer subshell that ran out of retries touches /tmp/pn_deploy_failed_<X>;
# without this check, individual PN failures are silently swallowed by `wait` and the
# deploy continues to "1.0 Deployment complete" with broken PNs.
failed_pns=()
for RELAYER_NAME in "${PARTICIPANT_NAMES[@]}"; do
    if [ -f "/tmp/pn_deploy_failed_${RELAYER_NAME}" ]; then
        failed_pns+=("$RELAYER_NAME")
        rm -f "/tmp/pn_deploy_failed_${RELAYER_NAME}"
    fi
done
if [ ${#failed_pns[@]} -gt 0 ]; then
    echo "❌ Privacy Node deployments failed for: ${failed_pns[*]}" >&2
    echo "0,Privacy Node deployment failed: ${failed_pns[*]}" > /tmp/deploy_status
    exit 5
fi
echo "All Privacy Node contracts deployed."

# -------------------------------------------------------------------------
# SEED STANDARD TEMPLATES ON THE PNH TEMPLATE REGISTRY
# Must run AFTER the PNs are deployed (the task reads the canonical Enygma bytecode
# hash from a PN's RNContractFactoryV1 via getBytecodeHash) and AFTER PNH business
# roles are active (seedStandardTemplate is PRIVATE_NETWORK_OPERATOR-gated). Without
# this, the PN template gate rejects crossMint with ProgramData__Unapproved and every
# Enygma cross-transfer mint reverts on the destination PN.
# Gated on HUB_ENABLED: hub-less mode has no PNH template registry to seed.
# -------------------------------------------------------------------------
if [ "$HUB_ENABLED" = "true" ]; then
SEED_PN_NAME="${PARTICIPANT_NAMES[0]}"
SEED_PN_INDEX=$(( $(printf '%d' "'$SEED_PN_NAME") - 65 ))
SEED_PN_RPC="http://pn-$(echo "$SEED_PN_NAME" | tr 'A-Z' 'a-z'):$((8545 + SEED_PN_INDEX))"
if [ -z "$SEED_PN_RPC" ]; then
    echo "❌ Could not resolve PN RPC URL for seeding (PRIVACY_NODE_${SEED_PN_NAME}_RPC_URL missing from .env)." >&2
    echo "0,PNH standard template seeding failed: missing PN RPC URL" > /tmp/deploy_status
    exit 5
fi
SEED_PN_FACTORY=$(grep -oE "PRIVACY_NODE_${SEED_PN_NAME}_RAYLS_NODE_CONTRACT_FACTORY=0x[0-9a-fA-F]+" "$RELAYER_PATH/.${SEED_PN_NAME}.env" 2>/dev/null | cut -d= -f2 | head -1)
echo "🌱 Seeding PNH standard templates (PN=$SEED_PN_NAME rpc=$SEED_PN_RPC factory=$SEED_PN_FACTORY)..."
if npx hardhat seed-standard-templates --network "$PNH_NETWORK_NAME" --rpc-url "$pnh_url" --registry-address "$PNH_REGISTRY" --pn-rpc-url "$SEED_PN_RPC" --pn-factory-address "$SEED_PN_FACTORY" 2>&1; then
    echo "✅ PNH standard templates seeded."
else
    echo "❌ PNH standard template seeding failed — Enygma cross-transfer mints will revert (ProgramData__Unapproved)." >&2
    echo "0,PNH standard template seeding failed" > /tmp/deploy_status
    exit 5
fi
else
    echo "⏭️  HUB_ENABLED=false — skipping PNH standard-template seeding"
fi

# Wait for public chain deployments (started before PNH, should be done or nearly done)
if [ ${#PC_PIDS[@]} -gt 0 ]; then
    echo "Waiting for public chain deployments to finish..."
    wait "${PC_PIDS[@]}"
    failed_pc=()
    for RELAYER_NAME in "${PARTICIPANT_NAMES[@]}"; do
        if [ -f "/tmp/pc_deploy_failed_${RELAYER_NAME}" ]; then
            failed_pc+=("$RELAYER_NAME")
            rm -f "/tmp/pc_deploy_failed_${RELAYER_NAME}"
        fi
    done
    if [ ${#failed_pc[@]} -gt 0 ]; then
        echo "❌ Public Chain deployments failed for: ${failed_pc[*]}" >&2
        echo "0,Public Chain deployment failed: ${failed_pc[*]}" > /tmp/deploy_status
        exit 6
    fi
    echo "All Public Chain contracts deployed."
fi

echo "0.8,Generating Go bindings for relayer..." > /tmp/deploy_status



# Run the additional npm commands
echo "Running npm bindings:delete relayer..."
npm run bindings:delete -- "$RELAYER_PATH/contracts"

echo "Running npm bindings:generate:relayer ..."
npm run bindings:generate:relayer

echo "0.9,Moving Go bindings to relayer" > /tmp/deploy_status

echo "Running npm bindings:move..."
mkdir -p "$RELAYER_PATH/contracts"
npm run bindings:move -- "$RELAYER_PATH/contracts"
chown -R $CUSTOM_UID:$CUSTOM_GID "$RELAYER_PATH/contracts"

# NOTE: We deliberately do NOT signal 1.0 here, even though relayer bindings
# are ready. Consumers via `docker compose up --wait contracts` (e.g.
# start_dev.sh) treat the first healthy state as their signal to proceed —
# and the very next thing they do is rebuild dev images (cts/relayer/
# pubrelayer), whose Dockerfile.dev copies $RELAYER_PATH/contracts. Governance
# bindings aren't written until further below, so signalling 1.0 early lets a
# consumer image rebuild race against the binding writes, baking stale/missing
# bindings into the image. Hold the status at <1.0 until ALL bindings (relayer +
# governance) are persisted; bump to 1.0 once at line "Deployment complete" below.
echo "0.92,Generating governance bindings..." > /tmp/deploy_status

# Initialize authorization results file
echo > /tmp/auth_results

# Create array to hold authorization process PIDs
AUTH_PIDS=()

# Start authorization monitoring for each participant in background.
# Auths consume relayer/CTS addresses on-chain; they don't touch the bindings
# being generated below, so it's safe to fork them here while we keep going.
for RELAYER_NAME in "${PARTICIPANT_NAMES[@]}"; do
    echo "Starting authorization monitoring for relayer $RELAYER_NAME..."
    authorize_participant_async "$RELAYER_NAME" &
    AUTH_PIDS+=($!)
done

# Generate governance bindings inline.
#
# Historical context: bindings + auth-wait used to live inside a background
# `monitor_authorization_completion &` subshell. That wrapper was broken
# because `wait $pid` against the parent's children returns 127 from a
# sibling subshell, and `set -e` killed the monitor before it could
# update /tmp/deploy_status to 1.2/1.3. Inlining the bindings here
# eliminates the subshell entirely. This note is kept as a tombstone so
# a future refactor doesn't reintroduce the same wrapper pattern.
echo "0.95,Generating Go bindings for governance API..." > /tmp/deploy_status
if [ "$GOVERNANCE_ENABLED" = "true" ]; then
    echo "Running npm bindings:delete governance-api..."
    set +e
    npm run bindings:delete -- "$GOVERNANCE_PATH/contracts"
    delete_exit_code=$?
    set -e
    if [ $delete_exit_code -ne 0 ]; then
        echo "❌ Error: Failed to delete old governance API contract bindings"
        echo "   Directory: $GOVERNANCE_PATH/contracts"
        echo "   Make sure the directory exists and is writable"
        exit 10
    fi
    echo "Running npm bindings:generate:governance ..."
    npm run bindings:generate:governance
    echo "Running npm bindings:move for governance API..."
    mkdir -p "$GOVERNANCE_PATH/contracts"
    npm run bindings:move -- "$GOVERNANCE_PATH/contracts"
    chown -R $CUSTOM_UID:$CUSTOM_GID "$GOVERNANCE_PATH/contracts"
else
    echo "Governance API bindings generation skipped as GOVERNANCE_ENABLED is set to false."
fi

# Generate ops-api bindings inline (same hold-status-<1.0 invariant as above:
# the ops-api image rebuild triggered by start_dev.sh copies
# $OPS_API_PATH/contracts, so these writes must complete before the 1.0 bump).
echo "0.97,Generating Go bindings for ops-api..." > /tmp/deploy_status
if [ "$OPS_API_ENABLED" = "true" ]; then
    echo "Running npm bindings:delete for ops-api..."
    set +e
    npm run bindings:delete -- "$OPS_API_PATH/contracts"
    delete_exit_code=$?
    set -e
    if [ $delete_exit_code -ne 0 ]; then
        echo "❌ Error: Failed to delete old ops-api contract bindings"
        echo "   Directory: $OPS_API_PATH/contracts"
        echo "   Make sure the directory exists and is writable"
        exit 10
    fi
    echo "Running npm bindings:generate:ops-service ..."
    npm run bindings:generate:ops-service
    echo "Running npm bindings:move for ops-api..."
    mkdir -p "$OPS_API_PATH/contracts"
    npm run bindings:move -- "$OPS_API_PATH/contracts"
    chown -R $CUSTOM_UID:$CUSTOM_GID "$OPS_API_PATH/contracts"
else
    echo "ops-api bindings generation skipped as OPS_API_ENABLED is set to false."
fi

# Bindings are up-to-date (auth background processes forked at line ~1086
# are still running; their `wait` happens further down) — bump status to
# 1.0 so the healthcheck reports "deployed" and start_dev.sh can proceed
# to launch governance services that consume the bindings we just
# generated.
# Preserve the configuration-dependent status message so operators triaging
# /tmp/deploy_status can distinguish the public-chain-enabled deploy from
# the public-chain-disabled one without re-reading the script.
if [ "$PUBLIC_CHAIN_ENABLED" = "true" ]; then
    echo "1.0,Deployment complete" > /tmp/deploy_status
else
    echo "1.0,Deployment complete (public chain disabled)" > /tmp/deploy_status
fi
echo "✅ Contracts are deployed and you can now start the Key Operation Services, Relayers and Governance."
echo "📋 You can check authorization progress in /tmp/auth_results"
echo "📊 Current status available at /tmp/deploy_status"

# Reorganize .env file to group variables by privacy node (independent of
# auth — uses values written by the PN deploy phase). Done here so the auth
# wait + PNH audit block below can `exit 11` on failure without leaving the
# .env half-reorganised.
echo "Reorganizing .env file to group variables by privacy node..."
(
    flock 200

    # Create temporary file for reorganized content
    TEMP_ENV="/tmp/.env.reorganized"
    > "$TEMP_ENV"

    # First, add all non-PRIVACY_NODE_X_ variables
    echo "# Global Configuration" >> "$TEMP_ENV"
    grep -v "^PRIVACY_NODE_[A-Z]_" "${CONTRACTS_PATH}/.env" >> "$TEMP_ENV" || true
    echo "" >> "$TEMP_ENV"

    # Then, group PRIVACY_NODE_X_ variables by participant
    for RELAYER_NAME in "${PARTICIPANT_NAMES[@]}"; do
        echo "# Privacy Node $RELAYER_NAME" >> "$TEMP_ENV"
        grep "^PRIVACY_NODE_${RELAYER_NAME}_" "${CONTRACTS_PATH}/.env" >> "$TEMP_ENV" || true
        echo "" >> "$TEMP_ENV"
    done

    # Write reorganized content back to .env
    cat "$TEMP_ENV" > "${CONTRACTS_PATH}/.env"
    rm "$TEMP_ENV"
    chown $CUSTOM_UID:$CUSTOM_GID "${CONTRACTS_PATH}/.env"

) 200>/var/lock/contractsenvlockfile
echo "✅ .env file reorganized with grouped privacy node variables"

# ─── Foreground auth wait ─────────────────────────────────────────────────
# `wait "$pid"` only returns the real exit code when the calling shell is the
# actual parent of $pid. The previous design `&`-launched a monitor *sibling*
# subshell, whose `wait $pid` returned 127, and `set -e` killed it silently
# before it could update /tmp/deploy_status. Running this loop in the parent
# shell (which spawned AUTH_PIDS) fixes both issues. The `if wait …` form
# captures the exit code into $? without triggering `set -e`.
total_relayers=${#PARTICIPANT_NAMES[@]}
auth_completed=0
auth_failed=0
for pid in "${AUTH_PIDS[@]}"; do
    if wait "$pid"; then
        auth_completed=$((auth_completed + 1))
        echo "Authorization process $pid completed successfully ($auth_completed/$total_relayers)"
    else
        auth_failed=$((auth_failed + 1))
        echo "Authorization process $pid failed ($auth_failed failures)"
    fi
    echo "1.1,Auth $((auth_completed + auth_failed))/$total_relayers done ($auth_failed failures)" > /tmp/deploy_status
done

# ─── Cross-PN PNH audit ───────────────────────────────────────────────────
# PNH has a single AccessManager shared by every PN, so its expected set is
# the union of all PNs' CTS `private_hub_addresses`. Running once with the
# full participant list avoids the per-PN false positives we'd otherwise get
# (each per-PN audit would see the other PNs' grants as "UNEXPECTED").
# Skipped automatically when PUBLIC_CHAIN_ENABLED is false because the rest
# of the deploy never wires up the per-PN PC audits either.
# pnh_audit_failed stays 0 in hub-less mode so the final status check below resolves
# to a clean "all relayers authorized" exactly as a PN+PC-only deploy should.
pnh_audit_failed=0
if [ "$HUB_ENABLED" = "true" ]; then
echo "🔍 Auditing relayer roles on PNH for all participants: ${PARTICIPANT_NAMES[*]}..."
pnh_pns=$(IFS=,; echo "${PARTICIPANT_NAMES[*]}")
pnh_audit_start=$SECONDS
set +e
npx hardhat audit:pnh:roles \
    --privacy-nodes "$pnh_pns" \
    --registry "$PNH_REGISTRY"
pnh_audit_rc=$?
set -e
echo "   ⏱  audit:pnh:roles took $((SECONDS - pnh_audit_start))s"
if [ "$pnh_audit_rc" -ne 0 ]; then
    pnh_audit_failed=1
    echo "❌ PNH cross-PN relayer-roles audit failed (exit $pnh_audit_rc)"
fi
fi

# ─── Final deploy status ──────────────────────────────────────────────────
if [ "$auth_failed" -eq 0 ] && [ "$pnh_audit_failed" -eq 0 ]; then
    echo "1.3,All relayers authorized successfully" > /tmp/deploy_status
    echo "🎉 All relayer authorizations completed successfully!"
else
    detail="auth=$auth_failed failures, pnh_audit=$pnh_audit_failed"
    echo "1.2,Some relayer authorizations or the PNH audit failed ($detail)" > /tmp/deploy_status
    echo "⚠️ Relayer authorization completed with $auth_failed auth failure(s) and pnh_audit_failed=$pnh_audit_failed"
    # Surface the failure in the container exit code so CI / operators see
    # it. We exit *before* the NODE_PID wait so the container actually
    # terminates instead of blocking on the healthcheck server forever.
    exit 11
fi

# Wait for the node process to complete
echo "Waiting for Node.js process $NODE_PID to complete..."
if kill -0 "$NODE_PID" 2>/dev/null; then
    wait "$NODE_PID" 2>/dev/null || true
    echo "Node.js process $NODE_PID has completed"
else
    echo "Node.js process $NODE_PID is not running"
fi

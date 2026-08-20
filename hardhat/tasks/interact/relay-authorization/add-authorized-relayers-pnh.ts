import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { ethers as ethersLib } from 'ethers';
import axios from 'axios';


interface RelayerAddresses {
  private_hub_addresses: string[];
  private_hub_dvp_operator_addresses?: string[];
  error: string;
}

task('add-authorized-relayers-pnh', 'Grant RELAYER to Private Relayer addresses via RaylsAccessManagerV1 on the Private Network Hub')
  .addParam('privacyNodes', 'The participant names to authorize (comma separated list)', 'A,B,C,D')
  .addOptionalParam('rpcUrl', 'The Private Network Hub URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The operator private key used for signing transactions')
  .setAction(async (taskArgs, { ethers }) => {
    console.log('🚀 Running relay authorization for privacy nodes: ', taskArgs.privacyNodes);
    console.log('============================================================');

    // Load environment or CLI parameters
    const rpcUrl = getEnvVariableOrFlag('Network Hub RPC URL', `PNH_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
    const operatorPrivateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    if (!taskArgs.privacyNodes) {
      throw new Error('The --privacyNodes parameter must be provided');
    }
    const privacyNodes = taskArgs.privacyNodes.split(',').map((node: string) => node.trim());
    if (privacyNodes.length === 0) {
      throw new Error('No privacy nodes specified');
    }

    // Get deployment registry addresses
    const deploymentRegistryAddress = getEnvVariableOrFlag('Network Hub Deployment Registry Address', `PNH_DEPLOYMENT_PROXY_REGISTRY`, 'deploymentRegistryAddress', '--deployment-registry-address', taskArgs);

    // Setup providers and signers
    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(operatorPrivateKey);
    const operator = wallet.connect(provider);

    // Fetch RaylsAccessManagerV1 address from deployment registry
    console.log('🔍 Fetching RaylsAccessManagerV1 address from deployment registry...');
    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentRegistryAddress, operator);

    const authorizationRegistryAddress = await deploymentRegistry.getContract('RaylsAccessManager');

    // Validate registry addresses
    if (!ethersLib.isAddress(authorizationRegistryAddress)) {
      throw new Error(`Invalid authorization registry address: ${authorizationRegistryAddress}`);
    }

    for (const privacyNode of privacyNodes) {
      console.log(`🔍 Authorizing PN: ${privacyNode}`);

      const ctsResponse = await fetchAddressesFromCTS(privacyNode, 'private_relayer');
      const { private_hub_addresses: hubAddresses, private_hub_dvp_operator_addresses: dvpOperatorAddresses } = ctsResponse;

      if (hubAddresses.length === 0) {
        throw new Error('No Private Relayer private hub keys found in CTS response');
      }

      // Combine PrivateHub addresses (used for endpoint receivePayload, executeMessage, etc.)
      // with PrivateHubDvpOperator addresses (used for DVP token mint/burn/UpdateInfos on
      // PNH-side mirrors). Both sets sign txs from the relayer to PNH and need RELAYER role.
      const relayerAddresses: string[] = [...hubAddresses, ...(dvpOperatorAddresses ?? [])];

      // Validate all addresses
      for (const address of relayerAddresses) {
        if (!ethersLib.isAddress(address)) {
          throw new Error(`Invalid Relayer address: ${address}`);
        }
        console.log(`   ✓ ${address}`);
      }


      console.log(`📋 Authorization Registry Address: ${authorizationRegistryAddress}`);
      console.log(`📝 Private Relayer addresses to add: ${hubAddresses.length} hub + ${(dvpOperatorAddresses ?? []).length} dvp-operator = ${relayerAddresses.length} total`);

      try {
        console.log(`📊 Authorising Private Relayer addresses: [${relayerAddresses}], authorizationRegistryAddress: ${authorizationRegistryAddress}, signer: ${operator.address}`);
        await authorizeRelayers(relayerAddresses, authorizationRegistryAddress, ethers, operator);
      }
      catch (error: any) {
        console.error('❌ Error adding authorized relay addresses:');
        console.error(error.message);

        if (error.reason) {
          console.error('Reason:', error.reason);
        }

        if (error.code) {
          console.error('Error Code:', error.code);
        }

        throw error;
      }
    }
  });

// Simple retry function for handling nonce conflicts
async function retryTransaction(transactionFn: () => Promise<any>, maxRetries = 3, baseDelay = 1000): Promise<any> {
  for (let attempt = 0; attempt < maxRetries; attempt++) {
    try {
      console.log(`🔄 Transaction attempt ${attempt + 1}/${maxRetries}`);
      return await transactionFn();
    } catch (error: any) {
      console.log(`⚠️ Attempt ${attempt + 1} failed:`, error.message);

      const isNonceError = error.code === 'NONCE_EXPIRED' ||
        error.message.includes('nonce too low') ||
        error.message.includes('nonce has already been used');

      if (isNonceError && attempt < maxRetries - 1) {
        const delay = baseDelay * Math.pow(2, attempt); // Exponential backoff
        console.log(`🕐 Waiting ${delay}ms before retry...`);
        await new Promise(resolve => setTimeout(resolve, delay));
        continue;
      }

      throw error; // Re-throw if not nonce error or out of retries
    }
  }
}

// Function to authorize relayers by granting RELAYER via RaylsAccessManagerV1.
// Sends all grantRole TXs in parallel with explicit nonces, then waits for all receipts.
async function authorizeRelayers(
  relayerAddresses: string[],
  managerAddress: string,
  ethers: any,
  signer: any
): Promise<void> {
  const manager = await ethers.getContractAt('RaylsAccessManagerV1', managerAddress, signer);

  const chainId = await signer.provider.getNetwork().then((n: any) => n.chainId);
  console.log(`📊 Connected to chain ${chainId} (manager: ${managerAddress})`);
  if (chainId !== 1337n) {
    throw new Error(`CRITICAL: PNH relay authorization connected to chain ${chainId} instead of PNH (1337). Aborting to prevent granting roles on wrong chain.`);
  }
  const relayerRoleId = await manager.getRoleIdByName('RELAYER');
  console.log(`📊 RELAYER ID: ${relayerRoleId}`);

  let nonce = await signer.getNonce('pending');
  console.log(`⏳ Granting RELAYER to ${relayerAddresses.length} addresses (parallel, starting nonce ${nonce})...`);
  const txPromises = relayerAddresses.map(addr =>
    manager.grantRole(relayerRoleId, addr, 0, { nonce: nonce++ })
  );
  const txResponses = await Promise.all(txPromises);
  const receipts = await Promise.all(txResponses.map((tx: any) => tx.wait()));

  for (let i = 0; i < receipts.length; i++) {
    if (receipts[i]?.status === 0) {
      throw new Error(`grantRole TX failed for ${relayerAddresses[i]}`);
    }
  }

  console.log('============================================================');
  console.log(`✅ Relayer authorization completed — ${relayerAddresses.length} grants in 1 batch`);

  // Verify grants
  for (const addr of relayerAddresses) {
    const [isMember] = await manager.hasRole(relayerRoleId, addr);
    console.log(`  ${isMember ? '✓' : '✗'} ${addr}`);
  }
}

// Function to fetch raw address data from CTS (Cryptographic Trust Suite) endpoint
async function fetchAddressesFromCTS(pn: string, service: string): Promise<RelayerAddresses> {
  const ctsUrlEnvVar = `CTS_SERVICE_${pn}_URL`;
  const ctsUrl = process.env[ctsUrlEnvVar];

  if (!ctsUrl) {
    throw new Error(`Environment variable ${ctsUrlEnvVar} is not set`);
  }

  const endpoint = `${ctsUrl}/public/addresses?service=${service}`;
  console.log(`📡 Fetching relayer addresses from: ${endpoint}`);

  try {
    const response = await axios.get<RelayerAddresses>(endpoint, {
      timeout: 10000, // 10 second timeout
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      }
    });

    const data = response.data;

    // Check for API error
    if (data.error) {
      throw new Error(`CTS API error: ${data.error}`);
    }

    return data;

  } catch (error: any) {
    if (error.response) {
      // HTTP error response
      throw new Error(`HTTP error ${error.response.status}: ${error.response.statusText}`);
    } else if (error.request) {
      // Network error
      throw new Error(`Network error: Could not reach CTS endpoint at ${endpoint}`);
    } else {
      // Other errors
      throw error;
    }
  }
}
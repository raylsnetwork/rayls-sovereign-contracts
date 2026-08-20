import { task } from 'hardhat/config';
import { sendWithAllocatedNonces } from '../../utils/sendWithAllocatedNonces';
import { getEnvVariableOrFlag } from '../../../utils/getEnvOrFlag';
import { ethers as ethersLib } from 'ethers';
import axios from 'axios';


interface RelayerAddresses {
  public_chain_addresses: string[];
  private_chain_addresses: string[];
  error: string;
}



task('add-authorized-relayers', 'Grant RELAYER to relayer addresses via RaylsAccessManagerV1')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('withPublicRelayer', 'Whether to authorize public relayer addresses or not (defaults to false)', 'false')
  .addOptionalParam('rpcUrl', 'The URL of the JSON-RPC API')
  .addOptionalParam('privateKey', 'The private key used for signing transactions')
  .setAction(async (taskArgs, { ethers }) => {
    console.log('🚀 Granting RELAYER to relayer addresses via RaylsAccessManagerV1...');
    console.log('============================================================');

    // Load environment or CLI parameters
    const privateRpcUrl = getEnvVariableOrFlag('RPC URL', `PRIVACY_NODE_${taskArgs.pn}_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    const shouldAuthorizePublicRelayer = taskArgs.withPublicRelayer?.toLowerCase() === 'true';
    const pn = taskArgs.pn;
    if (!pn) {
      throw new Error('The --pn parameter must be provided');
    }

    console.log(`🔍 Authorizing public relayer: ${shouldAuthorizePublicRelayer}`);

    // Get deployment registry addresses
    const privateDeploymentRegistryAddress = getEnvVariableOrFlag('Private Deployment Registry Address', `PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`, 'privateDeploymentRegistryAddress', '--private-deployment-registry-address', taskArgs);

    // Setup providers and signers
    const privateProvider = new ethers.JsonRpcProvider(privateRpcUrl);
    const privateWallet = new ethers.Wallet(privateKey);
    const privateSigner = privateWallet.connect(privateProvider);

    // Fetch RaylsAccessManagerV1 addresses from deployment registries
    console.log('🔍 Fetching RaylsAccessManagerV1 addresses from deployment registries...');
    const privateDeploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', privateDeploymentRegistryAddress, privateSigner);
    const privateManagerAddress = await privateDeploymentRegistry.getContract('RaylsAccessManager');

    // Validate manager addresses
    if (!ethersLib.isAddress(privateManagerAddress)) {
      throw new Error(`Invalid private manager address: ${privateManagerAddress}`);
    }

    let privateRelayerAddresses: RelayerAddresses;
    let publicRelayerAddresses: RelayerAddresses;

    console.log(`🔍 Fetching Private Relayer addresses from CTS for PN: ${pn}`);
    try {
      privateRelayerAddresses = await fetchAddressesFromCTS(pn, 'private_relayer');

      if (privateRelayerAddresses.private_chain_addresses.length === 0) {
        throw new Error('No Private Relayer private chain keys found in CTS response');
      }

    } catch (error: any) {
      console.error('❌ Failed to fetch Private Relayer addresses from CTS:');
      console.error(error.message);
      throw error;
    }

    if (shouldAuthorizePublicRelayer) {
      const publicRpcUrl = getEnvVariableOrFlag('RPC URL', `PUBLIC_CHAIN_RPC_URL`, 'rpcUrl', '--rpc-url', taskArgs);
      const publicDeploymentRegistryAddress = getEnvVariableOrFlag('Public Deployment Registry Address', `PRIVACY_NODE_${pn}_PUBLIC_CHAIN_DEPLOYMENT_PROXY_REGISTRY`, 'publicDeploymentRegistryAddress', '--public-deployment-registry-address', taskArgs);

      const publicProvider = new ethers.JsonRpcProvider(publicRpcUrl);
      // The public-chain contracts are deployed/owned by PUBLIC_CHAIN_PRIVATE_KEY,
      // so grants on the public chain must be signed by that key (fall back to
      // PRIVATE_KEY_SYSTEM). PN-side grants keep using PRIVATE_KEY_SYSTEM below.
      let publicChainKey = (process.env['PUBLIC_CHAIN_PRIVATE_KEY'] || privateKey).trim();
      if (!publicChainKey.startsWith('0x')) publicChainKey = '0x' + publicChainKey;
      const publicWallet = new ethers.Wallet(publicChainKey);
      const publicSigner = publicWallet.connect(publicProvider);

      const publicDeploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', publicDeploymentRegistryAddress, publicSigner);
      const publicManagerAddress = await publicDeploymentRegistry.getContract('RaylsAccessManager');

      if (!ethersLib.isAddress(publicManagerAddress)) {
        throw new Error(`Invalid public manager address: ${publicManagerAddress}`);
      }

      // Fetch addresses from CTS endpoint
      console.log(`🔍 Fetching public relayer addresses from CTS for PN: ${pn}`);

      try {
        publicRelayerAddresses = await fetchAddressesFromCTS(pn, 'public_relayer');

        if (publicRelayerAddresses.private_chain_addresses.length === 0) {
          throw new Error('No Public Relayer private chain keys found in CTS response');
        }
        if (publicRelayerAddresses.public_chain_addresses.length === 0) {
          throw new Error('No Public Relayer public chain keys found in CTS response');
        }

        // Step 3: Fund public relayer keys
        console.log('💸 Funding public relayer addresses...');
        await fundPublicRelayerTxSignKeysFromDeployer(publicRelayerAddresses.public_chain_addresses);
      } catch (error: any) {
        console.error('❌ Failed to fund public relayer addresses:');
        console.error(error.message);
        throw error;
      }

      console.log(`📝 Public Relayer Private Chain Addresses to add: ${publicRelayerAddresses.private_chain_addresses.length}`);

      // Validate all addresses
      for (const address of publicRelayerAddresses.private_chain_addresses) {
        if (!ethersLib.isAddress(address)) {
          throw new Error(`Invalid Ethereum address: ${address}`);
        }
        console.log(`   ✓ ${address}`);
      }

      console.log(`👤 Public Relayer Private Signer Address: ${privateSigner.address}`);
      console.log('============================================================');

      try {
        console.log(`📊 Granting RELAYER to Public Relayer Private Chain Addresses: [${publicRelayerAddresses.private_chain_addresses}], privateManagerAddress: ${privateManagerAddress}, signer: ${privateSigner.address}`);
        await authorizeRelayers(publicRelayerAddresses.private_chain_addresses, privateManagerAddress, ethers, privateSigner);
      } catch (error: any) {
        console.error('❌ Error granting RELAYER:');
        console.error(error.message);

        if (error.reason) {
          console.error('Reason:', error.reason);
        }

        if (error.code) {
          console.error('Error Code:', error.code);
        }

        throw error;
      }

      console.log(`📋 Public Manager Address: ${publicManagerAddress}`);
      console.log(`📝 Public Relayer Public Chain Addresses to add: ${publicRelayerAddresses.public_chain_addresses.length}`);

      // Validate all addresses
      for (const address of publicRelayerAddresses.public_chain_addresses) {
        if (!ethersLib.isAddress(address)) {
          throw new Error(`Invalid Ethereum address: ${address}`);
        }
        console.log(`✓    ${address}`);
      }

      console.log(`👤 Public Relayer Public Signer Address: ${publicSigner.address}`);
      console.log('============================================================');

      try {
        console.log(`📊 Granting RELAYER to Public Relayer Public Chain Addresses: [${publicRelayerAddresses.public_chain_addresses}], publicManagerAddress: ${publicManagerAddress}, signer: ${publicSigner.address}`);
        await authorizeRelayers(publicRelayerAddresses.public_chain_addresses, publicManagerAddress, ethers, publicSigner);
      }
      catch (error: any) {
        console.error('❌ Error granting RELAYER:');
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

    console.log(`📋 Private Manager Address: ${privateManagerAddress}`);
    console.log(`📝 Private Relayer Private Chain Addresses to add: ${privateRelayerAddresses.private_chain_addresses.length}`);

    // Validate all addresses
    for (const address of privateRelayerAddresses.private_chain_addresses) {
      if (!ethersLib.isAddress(address)) {
        throw new Error(`Invalid Ethereum address: ${address}`);
      }
      console.log(`   ✓ ${address}`);
    }

    console.log(`👤 Private Relayer Signer Address: ${privateSigner.address}`);
    console.log('============================================================');

    try {
      console.log(`📊 Granting RELAYER to Private Relayer Private Chain Addresses: [${privateRelayerAddresses.private_chain_addresses}], privateManagerAddress: ${privateManagerAddress}, signer: ${privateSigner.address}`);
      await authorizeRelayers(privateRelayerAddresses.private_chain_addresses, privateManagerAddress, ethers, privateSigner);
    } catch (error: any) {
      console.error('❌ Error granting RELAYER:');
      console.error(error.message);

      if (error.reason) {
        console.error('Reason:', error.reason);
      }

      if (error.code) {
        console.error('Error Code:', error.code);
      }

      throw error;
    }
  });

// Function to authorize relayers by granting RELAYER via RaylsAccessManagerV1.
// Sends all grantRole TXs in parallel under allocated nonces, resending any the
// chain rejects as too low — see sendWithAllocatedNonces.
async function authorizeRelayers(
  relayerAddresses: string[],
  managerAddress: string,
  ethers: any,
  signer: any
): Promise<void> {
  const manager = await ethers.getContractAt('RaylsAccessManagerV1', managerAddress, signer);

  const relayerRoleId = await manager.getRoleIdByName('RELAYER');
  console.log(`📊 RELAYER ID: ${relayerRoleId}`);

  console.log(`⏳ Granting RELAYER to ${relayerAddresses.length} addresses (parallel)...`);
  const receipts = await sendWithAllocatedNonces(
    () => signer.getNonce('pending'),
    relayerAddresses.length,
    (nonce, i) => manager.grantRole(relayerRoleId, relayerAddresses[i], 0, { nonce }),
    i => relayerAddresses[i]
  );

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

// Function to fund public relayer keys directly from the deployer (system) account on the public chain.
// Sends all funding TXs in parallel under allocated nonces, resending any the
// chain rejects as too low — see sendWithAllocatedNonces.
async function fundPublicRelayerTxSignKeysFromDeployer(PublicRelayerTxSignKeys: string[]): Promise<void> {
  const publicRpcUrl = process.env["PUBLIC_CHAIN_RPC_URL"];
  // Fund from the funded public-chain key (PUBLIC_CHAIN_PRIVATE_KEY, what CLI
  // stacks deploy the testnet contracts with), falling back to
  // PRIVATE_KEY_SYSTEM (the remote dev flow funds it per developer).
  let systemPrivateKey = process.env["PUBLIC_CHAIN_PRIVATE_KEY"] || process.env["PRIVATE_KEY_SYSTEM"];
  // Per-key budget. PUBLIC_RELAYER_FUND_AMOUNT_ETH is the CLI compose knob
  // (0.5 there: each bridge tx costs ~0.005 ETH, wallets are fresh every
  // deploy and stranded on down -v). The 5 ETH default is a generous runtime
  // budget at the chain's 48 Gwei base-fee floor; the remote-mode
  // deployer-funding math in rayls-privacy-relayer-api/start_dev.sh assumes it
  // (5 keys x 5 ETH per participant) — keep them in sync.
  const amountEthStr = process.env['PUBLIC_RELAYER_FUND_AMOUNT_ETH'] ?? process.env['PUBLIC_RELAYER_FUND_ETH'] ?? '5';

  if (!publicRpcUrl) {
    throw new Error('PUBLIC_CHAIN_RPC_URL environment variable is not set');
  }
  if (!systemPrivateKey) {
    throw new Error('Neither PUBLIC_CHAIN_PRIVATE_KEY nor PRIVATE_KEY_SYSTEM is set');
  }
  systemPrivateKey = systemPrivateKey.trim();
  if (!systemPrivateKey.startsWith('0x')) {
    systemPrivateKey = '0x' + systemPrivateKey;
  }

  const provider = new ethersLib.JsonRpcProvider(publicRpcUrl);
  const wallet = new ethersLib.Wallet(systemPrivateKey, provider);
  const amountWei = ethersLib.parseEther(amountEthStr);

  console.log(`👛 Funding from deployer ${wallet.address} on public chain (Signer ETH: ${ethersLib.formatEther(await provider.getBalance(wallet.address))})`);
  console.log(`🔢 Amount per address: ${amountEthStr} ETH`);

  // Validate all addresses first
  for (const addr of PublicRelayerTxSignKeys) {
    if (!ethersLib.isAddress(addr)) {
      throw new Error(`Invalid address: ${addr}`);
    }
  }

  const feeData = await provider.getFeeData();
  const maxFeePerGas = feeData.maxFeePerGas ?? ethersLib.parseUnits('50', 'gwei');
  const maxPriorityFeePerGas = feeData.maxPriorityFeePerGas ?? ethersLib.parseUnits('2', 'gwei');

  console.log(`💸 Sending ${amountEthStr} ETH to ${PublicRelayerTxSignKeys.length} addresses (parallel)...`);
  const receipts = await sendWithAllocatedNonces(
    () => provider.getTransactionCount(wallet.address, 'pending'),
    PublicRelayerTxSignKeys.length,
    (nonce, i) => wallet.sendTransaction({
      to: PublicRelayerTxSignKeys[i],
      value: amountWei,
      nonce,
      maxFeePerGas,
      maxPriorityFeePerGas,
      gasLimit: 100000
    }),
    i => PublicRelayerTxSignKeys[i]
  );

  let successCount = 0;
  let failureCount = 0;
  for (let i = 0; i < receipts.length; i++) {
    if (receipts[i]?.status === 1) {
      successCount++;
    } else {
      failureCount++;
      console.log(`   ❌ Failed to fund ${PublicRelayerTxSignKeys[i]}`);
    }
  }

  console.log(`💰 Deployer funding completed: ${successCount} successful, ${failureCount} failed`);
}

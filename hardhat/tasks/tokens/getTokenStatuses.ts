import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';

// Enum -> name maps, mirrored from
// src/rayls-protocol/TokenRegistry/libraries/TokenStructs.sol
const PRIVACY_NODE_STATUS = ['UNDEFINED', 'WAITING_APPROVAL', 'AUTHORIZED', 'UNAUTHORIZED', 'FROZEN'];
const HUB_STATUS = ['UNDEFINED', 'WAITING_APPROVAL', 'AUTHORIZED', 'UNAUTHORIZED', 'FROZEN'];
const PUBLIC_CHAIN_STATUS = ['UNDEFINED', 'PENDING_DEPLOYMENT', 'DEPLOYED', 'FROZEN', 'DEPRECATED'];

function decode(names: string[], value: bigint | number): string {
    const index = Number(value);
    const name = names[index] ?? 'UNKNOWN';
    return `${name} (${index})`;
}

task('tokens:statuses', 'Gets a PN token statuses across privacy node, hub and public chain')
    .addParam('tokenAddress', 'The token address on the privacy node')
    .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
    .setAction(async (taskArgs, hre) => {
        const normalizedPn: string = String(taskArgs.pn).toUpperCase();
        const rpcUrl = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];
        const registryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_TOKEN_REGISTRY_ADDRESS`] as string;

        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = wallet.connect(provider);

        const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', registryAddress, signer);

        const spinner: Spinner = new Spinner();
        console.log(`Fetching token statuses on PN ${normalizedPn}...`);
        spinner.start();

        let token;
        try {
            token = await tokenRegistry.getTokenByAddress(taskArgs.tokenAddress);
        } catch {
            spinner.stop();
            console.log(`Token ${taskArgs.tokenAddress} not found on PN ${normalizedPn}`);
            return;
        }

        spinner.stop();
        console.log(`- Token:          ${token.name} (${token.symbol})`);
        console.log(`- Resource ID:    ${token.resourceId}`);
        console.log(`- PN address:     ${token.tokenAddress}`);
        console.log(`- Public address: ${token.publicTokenAddress}`);
        console.log(`- Privacy Node:   ${decode(PRIVACY_NODE_STATUS, token.privacyNodeStatus)}`);
        console.log(`- Hub:            ${decode(HUB_STATUS, token.hubStatus)}`);
        console.log(`- Public Chain:   ${decode(PUBLIC_CHAIN_STATUS, token.publicChainStatus)}`);
    });

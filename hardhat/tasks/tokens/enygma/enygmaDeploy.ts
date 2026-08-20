import { task } from "hardhat/config";
import * as path from "node:path";
import { Spinner } from "../../../utils/spinner";
import { getEnvVariableFromFile, upsertEnvVariable } from "../../../utils/envFile";
import { getDeploymentProxyRegistryAddress } from "../../utils/deploymentProxyHelper";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

/**
 * Builds the deploy action, parameterized by the concrete Enygma contract to instantiate.
 * Production uses `ProductionEnygmaToken` (canonical handler surface, matches the factory-seeded
 * template); the `_test` task uses `EnygmaTokenExample` (test-only hooks) for local testing.
 */
function makeEnygmaDeployAction(contractName: string) {
    return async (taskArgs: any, hre: any) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        const pn = String(taskArgs.pn).toUpperCase();
        const envFilePath = path.resolve(process.cwd(), ".env");
        console.log(`Deploying ${contractName} token on ${pn}...`);
        const randString = genRanHex(6);
        taskArgs.name = taskArgs.name || `Token ${randString}`
        taskArgs.symbol = taskArgs.symbol || `T_${randString}`
        const envKey = `TOKEN_${String(taskArgs.symbol).toUpperCase()}_ADDRESS`;
        const existingTokenAddress = getEnvVariableFromFile(envFilePath, envKey);

        if (existingTokenAddress) {
            throw new Error(
                `Token symbol "${taskArgs.symbol}" is already configured in ${envFilePath}: ` +
                `${envKey}=${existingTokenAddress}. Refusing to overwrite existing token address.`,
            );
        }

        spinner.start();
        const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);

        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

        const signer = new hre.ethers.NonceManager(wallet.connect(provider));

        const token = await hre.ethers.getContractFactory(contractName, signer);

        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const tokenPN = await token.connect(signer).deploy(
            taskArgs.name,
            taskArgs.symbol,
            contracts[0],
            { gasLimit: 10000000 }
        );
        await tokenPN.waitForDeployment();
        const tokenAddress = await tokenPN.getAddress();
        upsertEnvVariable(envFilePath, envKey, tokenAddress);
        process.env[envKey] = tokenAddress;
        spinner.stop();

        console.log(`Token Deployed At Address ${tokenAddress}`);
        console.log(`Stored ${envKey}=${tokenAddress} in ${envFilePath}`);

        // ENDPOINT_SENDER_ROLE is now granted automatically by the PN TokenRegistryV1.activateToken()
        // after PNH approves the token registration. No manual grant needed at deploy time.

        console.log('Next step — register the token:');
        console.log(`npx hardhat tokens:register --pn ${pn} --token-address ${tokenAddress}`);
    };
}

task("tokens:enygma:deploy", "Deploys Enygma (ProductionEnygmaToken) on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addOptionalParam("name", "Token Name")
    .addOptionalParam("symbol", "symbol")
    .setAction(makeEnygmaDeployAction("ProductionEnygmaToken"));

task("tokens:enygma:deploy_test", "Deploys the test Enygma token (EnygmaTokenExample) on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addOptionalParam("name", "Token Name")
    .addOptionalParam("symbol", "symbol")
    .setAction(makeEnygmaDeployAction("EnygmaTokenExample"));

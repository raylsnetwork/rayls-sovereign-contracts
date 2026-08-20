import { task } from "hardhat/config";
import * as path from "node:path";
import { Spinner } from "../../../utils/spinner";
import { getEnvVariableFromFile, upsertEnvVariable } from "../../../utils/envFile";
import { getDeploymentProxyRegistryAddress } from "../../utils/deploymentProxyHelper";


export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


/**
 * Builds the deploy action, parameterized by the concrete ERC1155 DvP contract to instantiate.
 * Production uses `ProductionErc1155Dvp`; the `_test` task uses `Erc1155DvpExample`.
 */
function makeDvp1155DeployAction(contractName: string) {
    return async (taskArgs: any, hre: any) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        const pn = String(taskArgs.pn).toUpperCase();
        const randString = genRanHex(6);
        taskArgs.uri = taskArgs.uri || `${randString}`
        const envFilePath = path.resolve(process.cwd(), ".env");
        const envKey = `TOKEN_${String(taskArgs.name).toUpperCase()}_ADDRESS`;
        const existingTokenAddress = getEnvVariableFromFile(envFilePath, envKey);

        if (existingTokenAddress) {
            throw new Error(
                `Token name "${taskArgs.name}" is already configured in ${envFilePath}: ` +
                `${envKey}=${existingTokenAddress}. Refusing to overwrite existing token address.`,
            );
        }

        console.log(`Deploying token on ${pn}...`);
        spinner.start();
        const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = new hre.ethers.NonceManager(wallet.connect(provider));

        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const token = await hre.ethers.getContractFactory(contractName, signer);

        const tokenPN = await token.connect(signer).deploy(taskArgs.uri, taskArgs.name, contracts[0], { gasLimit: 8000000 });
        await tokenPN.waitForDeployment();
        const tokenAddress = await tokenPN.getAddress();
        upsertEnvVariable(envFilePath, envKey, tokenAddress);
        process.env[envKey] = tokenAddress;

        console.log(`Token Deployed At Address ${tokenAddress}`);
        console.log(`Stored ${envKey}=${tokenAddress} in ${envFilePath}`);
        console.log("Token Deployer Address: ", wallet.address);
        console.log("Token uri: ", taskArgs.uri);
        console.log("Token name: ", taskArgs.name);

        // ENDPOINT_SENDER_ROLE is now granted automatically by the PN TokenRegistryV1.activateToken()
        // after PNH approves the token registration. No manual grant needed at deploy time.

        console.log('Next step — register the token:');
        console.log(`npx hardhat tokens:register --pn ${pn} --token-address ${tokenAddress}`);

        spinner.stop();
    };
}

task("dvp:erc1155:deploy", "Deploys ERC1155 DvP (ProductionErc1155Dvp) on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addOptionalParam("uri", "The ERC 1155 URI")
    .addParam("name", "The name of the ERC 1155 contract")
    .setAction(makeDvp1155DeployAction("ProductionErc1155Dvp"));

task("dvp:erc1155:deploy_test", "Deploys the test ERC1155 DvP (Erc1155DvpExample) on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addOptionalParam("uri", "The ERC 1155 URI")
    .addParam("name", "The name of the ERC 1155 contract")
    .setAction(makeDvp1155DeployAction("Erc1155DvpExample"));

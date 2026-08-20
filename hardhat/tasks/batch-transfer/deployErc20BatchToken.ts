import { task } from "hardhat/config";
import { Spinner } from "../../utils/spinner";
import { getDeploymentProxyRegistryAddress } from "../utils/deploymentProxyHelper";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task("batch-transfer:erc20-deploy", "Deploys token on the PN")
    .addParam("pn", "The Privacy Node identification e.g. A, B, ...")
    .addParam("name", "Token Name")
    .addParam("symbol", "symbol")
    .setAction(async (taskArgs, hre) => {

    await hre.run("compile");
    const spinner: Spinner = new Spinner();
    console.log(`Deploying token on ${taskArgs.pn}...`);
    spinner.start();

    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    console.log(`Owner address ${await signer.getAddress()}`);

    const token = await hre.ethers.getContractFactory("Erc20BatchTeleport", signer);
    const tokenName = taskArgs.name;
    const tokenSymbol = taskArgs.symbol;
    const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
    const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);
    const endpointAddress = contracts[0];

    const tokenPN = await token.connect(signer).deploy(tokenName, tokenSymbol, endpointAddress, { gasLimit: 5000000 });
    await tokenPN.waitForDeployment();

    spinner.stop();

    console.log(`Token deployed at address ${await tokenPN.getAddress()}`);
    await tokenPN.submitTokenRegistration(0);
    console.log(`Token registration submitted, don't forget to approve the token`);
    console.log("");
    });
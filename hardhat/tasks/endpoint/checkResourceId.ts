import { task } from "hardhat/config";
import { Spinner } from "../../utils/spinner";
import { getDeploymentProxyRegistryAddress } from "../utils/deploymentProxyHelper";

task("endpoint:check-resource-id", "Deploys all the PN's contracts and retrieve contracts addresses")
    .addParam("privacyNode", "The Privacy Node identification (ex: A, B, C, D)")
    .addParam("resourceId", "The resource id in hex string")
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        console.log("Checking contract...");
        spinner.start();
        const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.privacyNode}_RPC_URL`];
        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = wallet.connect(provider);

        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.privacyNode}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const endpoint = await hre.ethers.getContractAt("EndpointV1", contracts[0], signer);
        console.log(`Mapped Address on PN ${taskArgs.privacyNode}: ${await endpoint.connect(signer).getAddressByResourceId(taskArgs.resourceId)}`);
    });
import { task } from "hardhat/config";
import { Spinner } from "../../utils/spinner";
import { getDeploymentProxyRegistryAddress } from "../utils/deploymentProxyHelper";

task("endpoint:check-nonce-parity", "Checks the nonce parity between two PNs")
    .addParam("pn1", "The PN (ex: A, B, C, D)")
    .addParam("pn2", "The PN (ex: A, B, C, D)")
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        console.log("Checking contracts...");
        spinner.start();
        const rpcUrl1 = process.env[`PRIVACY_NODE_${taskArgs.pn1}_RPC_URL`];
        const rpcUrl2 = process.env[`PRIVACY_NODE_${taskArgs.pn2}_RPC_URL`];
        const provider1 = new hre.ethers.JsonRpcProvider(rpcUrl1);
        const provider2 = new hre.ethers.JsonRpcProvider(rpcUrl2);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer1 = wallet.connect(provider1);
        const signer2 = wallet.connect(provider2);
        const chainIdPn1 = process.env[`PRIVACY_NODE_${taskArgs.pn1}_CHAIN_ID`] as string
        const chainIdPn2 = process.env[`PRIVACY_NODE_${taskArgs.pn2}_CHAIN_ID`] as string

        const deploymentRegistryAddress1 = process.env[`PRIVACY_NODE_${taskArgs.pn1}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const deploymentRegistryAddress2 = process.env[`PRIVACY_NODE_${taskArgs.pn2}_DEPLOYMENT_PROXY_REGISTRY`] as string;

        const contracts1 = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress1, signer1, hre.ethers);
        const contracts2 = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress2, signer2, hre.ethers);

        const endpoint1 = await hre.ethers.getContractAt("EndpointV1", contracts1[0], signer1);
        const endpoint2 = await hre.ethers.getContractAt("EndpointV1", contracts2[0], signer2);

        const inboundOf1InPn2 = await endpoint2.getInboundNonce(chainIdPn1);
        const outboundOf1InPn2 = await endpoint1.getOutboundNonce(chainIdPn1);

        const inboundOf2InPn1 = await endpoint1.getInboundNonce(chainIdPn2);
        const outboundOf2InPn1 = await endpoint1.getOutboundNonce(chainIdPn2);

        console.log(`Inbound of PN ${taskArgs.pn1} on PN ${taskArgs.pn2}: ${inboundOf1InPn2}`);
        console.log(`Outbound of PN ${taskArgs.pn2} on PN ${taskArgs.pn1}: ${outboundOf2InPn1}`);
        console.log(`Sucess: ${inboundOf1InPn2 == outboundOf2InPn1}`)
        console.log("\n")
        console.log(`Inbound of PN ${taskArgs.pn2} on PN ${taskArgs.pn1}: ${inboundOf2InPn1}`);
        console.log(`Outbound of PN ${taskArgs.pn1} on PN ${taskArgs.pn2}: ${outboundOf1InPn2}`);
        console.log(`Sucess: ${inboundOf2InPn1 == outboundOf1InPn2}`)

    });

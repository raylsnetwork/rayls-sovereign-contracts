import { task } from "hardhat/config";
import { Spinner } from "../../utils/spinner";
import { getDeploymentProxyRegistryAddress } from "../utils/deploymentProxyHelper";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task("communicator:deploy", "Deploys PN communicator example on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")    
    .setAction(async (taskArgs, hre) => {
        const { ethers, upgrades } = hre;

        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        console.log(`Deploying communicator on ${taskArgs.pn}...`);
        spinner.start();
        
        const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        
        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = new hre.ethers.NonceManager(wallet.connect(provider));        

        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const factory = await ethers.getContractFactory('PNCommunicatorV1', signer);

        const contract = await upgrades.deployProxy(factory, [contracts[0]], {
          kind: 'uups',
          initializer: 'initialize(address)'
        });
      
        await contract.deploymentTransaction()?.wait(2);
      
        const address = await contract.getAddress();
      
        spinner.stop();

        console.log(`PN Communicator deployed at ${address}`);

    });
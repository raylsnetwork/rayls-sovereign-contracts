import {task} from 'hardhat/config';

task('check-frozen-token', 'Checks if a token is frozen')
    .addParam("pn", "The PN to check the token on")
    .addParam("resourceId", "The resourceId of the token")
    .addParam("participant", "The participant to check if the token is frozen for")
    .addParam("registry", "The address of the PN TokenRegistry")
    .setAction(async (taskArgs, hre) => {
        const {participant, resourceId, registry} = taskArgs;
        const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = wallet.connect(provider);
        const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', registry, signer);

        console.log(await tokenRegistry.getFrozenTokenForParticipant(hre.ethers.keccak256(hre.ethers.toUtf8Bytes(resourceId)), participant));

    });

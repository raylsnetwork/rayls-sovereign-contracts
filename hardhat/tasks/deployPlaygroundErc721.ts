import { task } from 'hardhat/config';
import { ethers } from 'hardhat';
import { Spinner } from '../utils/spinner';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('deployPlaygroundErc721', 'Deploys Playground Erc721 on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addOptionalParam('uri', 'uri')
  .addOptionalParam('name', 'name')
  .addOptionalParam('symbol', 'symbol')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Deploying token on ${taskArgs.pn}...`);
    spinner.start();
    const randString = genRanHex(6);
    taskArgs.uri = taskArgs.uri || `${randString}`;
    taskArgs.name = taskArgs.name || `Playground Erc721 ${randString}`;
    taskArgs.symbol = taskArgs.symbol || `PgErc721_${randString}`;
    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = new hre.ethers.NonceManager(wallet.connect(provider));

    const token = await hre.ethers.getContractFactory('PlaygroundErc721', signer);

    const endpointAddress = process.env[`PRIVACY_NODE_${taskArgs.pn}_ENDPOINT_ADDRESS`] as string;
    const endpoint = await hre.ethers.getContractAt('EndpointV1', endpointAddress, signer);

    const tokenPN = await token.connect(signer).deploy(taskArgs.uri, taskArgs.name, taskArgs.symbol, endpointAddress, process.env[`PRIVACY_NODE_${taskArgs.pn}_RAYLS_NODE_ENDPOINT_ADDRESS`] as string, process.env[`PRIVACY_NODE_${taskArgs.pn}_RAYLS_NODE_USER_GOVERNANCE`] as string, { gasLimit: 5000000 });
    await tokenPN.waitForDeployment();
    const tokenAddress = await tokenPN.getAddress();

    // ENDPOINT_SENDER_ROLE is now granted automatically by the PN TokenRegistryV1.activateToken()

    spinner.stop();

    console.log(`Token Deployed At Address ${await tokenPN.getAddress()}`);
    console.log('Token Deployer Address: ', wallet.address);

    let tx = await tokenPN.mint(wallet.address, 0, { gasLimit: 5000000 });
    await tx.wait();
    console.log(`Minted token with id 0 to ${wallet.address}`);

    const regitrationTx = await tokenPN.submitTokenRegistration(2);
    await regitrationTx.wait();
    console.log(`Token Registration Submitted, wait until relayer retrieves the generated resource`);
    console.log('');
    console.log("To check if it's registered, please use the following command:");
    console.log(`\$ npx hardhat checkTokenResourceId --pn ${taskArgs.pn} --token-address ${await tokenPN.getAddress()}`);

    console.log("To use the token on the public chain, please submit it for approval by the PN operator with the command:");
    console.log(`\$ npx hardhat tokens:register --pn ${taskArgs.pn} --token-address ${await tokenPN.getAddress()}`);
    console.log("Then approve it using:");
    console.log(`\$ npx hardhat tokens:approve-pn --pn ${taskArgs.pn} --token-address ${await tokenPN.getAddress()}`);

    return tokenPN;
  });

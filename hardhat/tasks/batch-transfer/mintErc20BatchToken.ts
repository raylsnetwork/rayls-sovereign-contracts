import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';

task('batch-transfer:erc20-mint', 'Mint token')
  .addParam('pn', 'The privacy node to mint the token in e.g.: A, B, ...')
  .addParam('address', 'The address to mint the token')
  .addParam('resourceId', 'The resourceId of the token')
  .addParam('amount', 'The amount to mint')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    spinner.start();

    const { pn, address, resourceId, amount } = taskArgs;

    const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);
    
    const endpointAddress = process.env[`PRIVACY_NODE_${pn}_ENDPOINT_ADDRESS`] as string;
    const endpoint = await hre.ethers.getContractAt('EndpointV1', endpointAddress, signer);
    const tokenAddress = await endpoint.connect(signer).getAddressByResourceId(resourceId);
    
    spinner.stop();
    
    if (tokenAddress == '0x0000000000000000000000000000000000000000') {
      console.log(`Token not implemented on PN ${pn}`);
      return;
    }

    const token = await hre.ethers.getContractAt('Erc20BatchTeleport', tokenAddress, signer);

    console.log('Minting token...');
    spinner.start();

    await token.connect(signer).mint(address, BigInt(amount));

    const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
    await sleep(5000);

    spinner.stop();
    console.log('Minting successful!');

    console.log('');
    console.log('Token Data:');
    console.log(`- Symbol: ${await token.symbol()}`);
    console.log(`- Name: ${await token.name()}`);
    console.log(`- Balance of ${address}: ${await token.balanceOf(address)}`);
  });

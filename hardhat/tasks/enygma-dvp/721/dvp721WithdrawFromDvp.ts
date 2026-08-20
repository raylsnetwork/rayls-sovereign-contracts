import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp721BySymbol } from '../../tokens/checkTokenAllChains';

task('dvp:erc721:withdraw', 'Withdraw NFT from Dvp')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('id', 'The NFT Id')
  .addParam('symbol', 'symbol')  
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Withdraw token ${taskArgs.id} on ${taskArgs.pn} ...`);
    spinner.start();

    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const pnId = process.env[`PRIVACY_NODE_${taskArgs.pn}_CHAIN_ID`];

    if (!pnId) {
      throw new Error(`Chain ID for ${taskArgs.pn} is not defined in environment variables`);
    }

    const token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.symbol);

    const txSwap = await token.withdrawFromDvp(taskArgs.id,  { gasLimit: 5000000 });
    await txSwap.wait();

    spinner.stop();

    console.log(`✅ Withdraw on PN ${taskArgs.pn} completed`);
  });

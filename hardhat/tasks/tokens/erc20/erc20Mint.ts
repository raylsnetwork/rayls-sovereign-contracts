import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc20BySymbol } from '../checkTokenAllChains';

task('tokens:erc20:mint', 'Mint ERC20 token')
  .addParam(
    'pn',
    'The Privacy Node identification (ex: A, B, C, D)'
  )
  .addParam('symbol', 'symbol')
  .addParam('to', 'amount')
  .addParam('amount', 'amount')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log(`Minting token ${taskArgs.symbol} to address ${taskArgs.to}`);
    spinner.start();
    const token = await getTokenErc20BySymbol(hre, taskArgs.pn, taskArgs.symbol);
    const tx = await token.mint(taskArgs.to, taskArgs.amount);
    await tx.wait();
    spinner.stop();
    console.log(`✅ Minted token ${taskArgs.symbol} to address ${taskArgs.to}`);
  });

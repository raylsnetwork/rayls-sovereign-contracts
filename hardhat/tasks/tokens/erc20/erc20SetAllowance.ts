import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc20BySymbol } from '../checkTokenAllChains';

task('tokens:erc20:set-allowance', 'Set allowance to a spender on a ERC-20 token')
  .addParam(
    'pn',
    'The Privacy Node identification (ex: A, B, C, D)'
  )
  .addParam('symbol', 'The ERC-20 token symbol')
  .addParam('to', 'The spender address')
  .addParam('amount', 'The amount of allowance to grant')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    spinner.start();
    const token = await getTokenErc20BySymbol(hre, taskArgs.pn, taskArgs.symbol);
    const tx = await token.approve(taskArgs.to, taskArgs.amount);
    await tx.wait();
    console.log(`Set allowance of ${taskArgs.amount} in token ${taskArgs.symbol} to spender ${taskArgs.to}`);
    spinner.stop();
  });

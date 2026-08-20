import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc20BySymbol } from '../checkTokenAllChains';

task('tokens:erc20:burn', 'Burn ERC20 token')
  .addParam(
    'pn',
    'The Privacy Node identification (ex: A, B, C, D)'
  )
  .addParam('symbol', 'symbol')
  .addParam('from', 'amount')
  .addParam('amount', 'amount')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log(
      `Burning ${taskArgs.amount} token ${taskArgs.symbol} from address ${taskArgs.from}`
    );
    spinner.start();
    const token = await getTokenErc20BySymbol(hre, taskArgs.pn, taskArgs.symbol);
    const tx = await token.burn(taskArgs.from, taskArgs.amount);
    await tx.wait();
    spinner.stop();
    console.log(
      `✅ Burned ${taskArgs.amount} token ${taskArgs.symbol} from address ${taskArgs.from}`
    );
  });

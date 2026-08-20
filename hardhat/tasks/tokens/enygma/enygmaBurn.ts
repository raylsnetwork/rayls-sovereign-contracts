import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getEnygmaBySymbol } from '../checkTokenAllChains';

task('tokens:enygma:burn', 'Burn Enygma token')
  .addParam(
    'pn',
    'The Privacy Node identification (ex: A, B, C, D)'
  )
  .addParam('symbol', 'symbol')
  .addParam('from', 'address')
  .addParam('amount', 'Human-readable amount to burn (e.g. "100" for 100 tokens)')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    spinner.start();

    try {
      const parsedAmount = Number(taskArgs.amount);
      if (isNaN(parsedAmount) || parsedAmount <= 0) {
        throw new Error(`Invalid amount: "${taskArgs.amount}". Amount must be a positive number.`);
      }

      const token = await getEnygmaBySymbol(hre, taskArgs.pn, taskArgs.symbol);
      const decimals = await token.decimals();
      const amount = hre.ethers.parseUnits(taskArgs.amount.toString(), decimals);
      const tx = await token.burn(taskArgs.from, amount);
      console.log(`Burning ${taskArgs.amount} (${amount} base units) of token ${taskArgs.symbol} from address ${taskArgs.from}`);
      await tx.wait();
    } catch (error) {
      console.error('Error during burn:', error instanceof Error ? error.message : error);
    } finally {
      spinner.stop();
    }
  });

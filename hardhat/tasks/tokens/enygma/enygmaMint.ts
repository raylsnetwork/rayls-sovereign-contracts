import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getEnygmaBySymbol } from '../checkTokenAllChains';

task('tokens:enygma:mint', 'Mint Enygma token')
  .addParam(
    'pn',
    'The Privacy Node identification (ex: A, B, C, D)'
  )
  .addParam('symbol', 'symbol')
  .addParam('to', 'Recipient address')
  .addParam('amount', 'Human-readable amount to mint (e.g. "100" for 100 tokens)')
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
      const tx = await token.mint(taskArgs.to, amount);

      await tx.wait();
      console.log(`Minted ${taskArgs.amount} (${amount} base units) of token ${taskArgs.symbol} to address ${taskArgs.to}`);
    } catch (error) {
      console.error('Error during mint:', error instanceof Error ? error.message : error);
    } finally {
      spinner.stop();
    }
  });

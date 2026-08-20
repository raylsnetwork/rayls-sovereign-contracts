import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getEnygmaBySymbol } from '../../tokens/checkTokenAllChains';

task('dvp:enygma:deposit', 'Deposit Enygma token to Dvp')
  .addParam(
    'pn',
    'The Privacy Node identification (ex: A, B, C, D)'
  )
  .addParam('symbol', 'Symbol of the Enygma token')
  .addParam('amount', 'Human-readable amount to deposit (e.g. "100" for 100 tokens)')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    spinner.start();

    try {
      const parsedAmount = Number(taskArgs.amount);
      if (isNaN(parsedAmount) || parsedAmount <= 0) {
        throw new Error(`Invalid amount: "${taskArgs.amount}". Amount must be a positive number.`);
      }

      // Get the Enygma token
      const token = await getEnygmaBySymbol(hre, taskArgs.pn, taskArgs.symbol);

      // Convert human-readable amount to base units using token decimals
      const decimals = await token.decimals();
      const amount = hre.ethers.parseUnits(taskArgs.amount.toString(), decimals);

      console.log(`Depositing ${taskArgs.amount} (${amount} base units) of token ${taskArgs.symbol} to Dvp`);

      // Call depositToDvp with the base unit amount
      const tx = await token.depositToDvp(amount);
      console.log(`Transaction hash: ${tx.hash}`);

      // Wait for transaction confirmation
      const receipt = await tx.wait();

      if (receipt) {
        console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
        console.log('Deposit completed successfully');
      } else {
        console.log('Transaction was submitted but receipt is not available');
      }
    } catch (error) {
      console.error(`Error during deposit:`, error instanceof Error ? error.message : error);
    }

    spinner.stop();
  });

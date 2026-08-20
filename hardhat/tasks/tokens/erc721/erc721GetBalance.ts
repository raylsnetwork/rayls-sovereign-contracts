import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc721BySymbol } from "../checkTokenAllChains";


task('tokens:erc721:get-balance', 'Prints the balance of and a tokenId on the Privacy Node')
  .addParam('pn', 'The PN (ex: A, B, C, D)')
  .addParam('symbol', 'The ERC 721 contract symbol')
  .addParam("address", "The account address to check the balance")  
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log('Checking balance information...');
    spinner.start();

    const token = await getTokenErc721BySymbol(hre, taskArgs.pn, taskArgs.symbol);

    const balance = await token.balanceOf(taskArgs.address)

    spinner.stop();
    console.log(`Balance of ${taskArgs.address}: ${balance.toString()}`);

  });

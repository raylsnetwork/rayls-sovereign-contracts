import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp1155ByName } from "../../tokens/checkTokenAllChains";


task('dvp:erc1155:get-balance', 'Prints the balance of and a tokenId on the Privacy Node')
  .addParam('pn', 'The PN (ex: A, B, C, D)')
  .addParam('name', 'The ERC 1155 contract name')
  .addParam("address", "The account address to check the balance")
  .addParam("id", "The token Id")
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log('Checking balance information...');
    spinner.start();

    const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);

    const balance = await token.balanceOf(taskArgs.address, taskArgs.id)

    spinner.stop();
    console.log(`Balance of ${taskArgs.address} for token ID ${taskArgs.id}: ${balance.toString()}`);

  });

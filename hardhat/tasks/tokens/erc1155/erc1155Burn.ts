import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc1155BySymbol } from "../checkTokenAllChains";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('tokens:erc1155:burn', 'Burn Erc1155 example on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('from', 'The address to burn from')
  .addParam('id', 'The token Id')
  .addParam('value', 'The amount to burn')
  .addParam('name', 'name')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Burning token ${taskArgs.id} on ${taskArgs.pn} `);
    spinner.start();
    
    const token = await getTokenErc1155BySymbol(hre, taskArgs.pn, taskArgs.name);

    await token.burn(taskArgs.from, taskArgs.id, taskArgs.value, { gasLimit: 5000000 });

    console.log(`✅ Burn on PN ${taskArgs.pn} completed`);

    spinner.stop();
  });

import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp1155ByName } from '../../tokens/checkTokenAllChains';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('dvp:erc1155:burn', 'Burn Erc1155Dvp example on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('from', 'The address to burn from')
  .addParam('id', 'The token Id')
  .addParam('amount', 'The amount to burn')
  .addParam('name', 'name')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Burning token ${taskArgs.id} on ${taskArgs.pn} `);
    spinner.start();

    const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);

    const tx = await token.burn(taskArgs.from, taskArgs.id, taskArgs.amount, { gasLimit: 5000000 });
    await tx.wait();

    console.log(`✅ Burn on PN ${taskArgs.pn} completed`);

    spinner.stop();
  });

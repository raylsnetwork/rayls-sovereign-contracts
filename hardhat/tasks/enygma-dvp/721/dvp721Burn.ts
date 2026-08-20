import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp721BySymbol } from '../../tokens/checkTokenAllChains';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('dvp:erc721:burn', 'Burn Erc721Dvp example on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('id', 'The NFT Id')
  .addParam('symbol', 'symbol')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Burning token ${taskArgs.id} on ${taskArgs.pn} `);
    spinner.start();

    const token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.symbol);

    const tx = await token.burn(taskArgs.id, { gasLimit: 5000000 });
    await tx.wait();

    console.log(`✅ Burn on PN ${taskArgs.pn} completed`);

    spinner.stop();

  });

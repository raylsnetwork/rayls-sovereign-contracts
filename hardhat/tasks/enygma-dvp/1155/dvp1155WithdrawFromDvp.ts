import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp1155ByName } from '../../tokens/checkTokenAllChains';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('dvp:erc1155:withdraw', 'Withdraw NFT from Dvp')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('id', 'The token Id')
  .addParam('value', 'The token value')
  .addOptionalParam('data', 'The token data')
  .addParam('name', 'name')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Withdraw token ${taskArgs.id} on ${taskArgs.pn} ...`);
    spinner.start();

    const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);

    const txSwap = await token.withdrawFromDvp(taskArgs.id, taskArgs.value, taskArgs.data || "", { gasLimit: 5000000 });
    await txSwap.wait();

    spinner.stop();

    console.log(`✅ Withdraw on PN ${taskArgs.pn} completed`);
    // todo: check relayer receives event.
  });

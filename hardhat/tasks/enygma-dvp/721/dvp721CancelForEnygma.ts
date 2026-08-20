import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp721BySymbol } from '../../tokens/checkTokenAllChains';

task('dvp:erc721:enygma:cancel', 'Cancel swap of Erc721 Enygma DvP on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('sharedId', 'shared id')
  .addParam('nftId', 'The NFT Id')
  .addParam('nftSymbol', 'The NFT symbol')
  .addParam('destChainId', 'The chainId of the destination chain')
  .addParam('enygmaAmount', 'Amount of Enygma to receive')
  .addParam('enygmaResourceId', 'Resource Id of the Enygma to receive')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Cancelling swap of ERC721 -> Enygma id=${taskArgs.nftId} on ${taskArgs.pn} ...`);
    spinner.start();

    const token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.nftSymbol);

    console.log(`Swapping ERC721 -> Enygma id=${taskArgs.nftId} with chain=${taskArgs.destChainId} sharedId=${taskArgs.sharedId}`);
    const txSwap = await token.cancelSwap(taskArgs.sharedId, taskArgs.destChainId, taskArgs.nftId, taskArgs.enygmaAmount, taskArgs.enygmaResourceId, { gasLimit: 5000000 });
    await txSwap.wait();

    spinner.stop();

    console.log(`✅ Cancel swap of ERC721 -> Enygma on PN ${taskArgs.pn} completed`);
  });

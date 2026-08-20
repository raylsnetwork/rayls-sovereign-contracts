import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp721BySymbol } from '../../tokens/checkTokenAllChains';
import { ethers } from 'ethers';
task('dvp:erc721:enygma:swap', 'Swap for Enygma Erc721Dvp example on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('nftId', 'The NFT Id')
  .addParam('nftSymbol', 'symbol')
  .addParam('enygmaAmount', 'Amount of Enygma to receive')
  .addParam('enygmaResourceId', 'Resource Id of the Enygma to receive')
  .addParam('destChainId', 'The chainId of the destination chain')
  .addParam('sharedId', 'shared id')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Swap token ${taskArgs.nftId} on ${taskArgs.pn} ...`);
    spinner.start();

    const pnId = process.env[`PRIVACY_NODE_${taskArgs.pn}_CHAIN_ID`];

    if (!pnId) {
      throw new Error(`Chain ID for ${taskArgs.pn} is not defined in environment variables`);
    }
    
    // shared id is not provided, generate a random bytes32 shared Id
    if (taskArgs.sharedId === "0x") {
        taskArgs.sharedId = ethers.keccak256(ethers.randomBytes(32));
    }

    const token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.nftSymbol);

    console.log(`Swapping ERC721 -> Enygma id=${taskArgs.nftId} with chain=${taskArgs.destChainId} sharedId=${taskArgs.sharedId}`);
    const txSwap = await token.swapWithDvpForEnygma(taskArgs.nftId, taskArgs.enygmaAmount, taskArgs.enygmaResourceId, taskArgs.destChainId, taskArgs.sharedId, 0, { gasLimit: 5000000 });
    await txSwap.wait();

    spinner.stop();

    console.log(`✅ Swap on PN ${taskArgs.pn} completed`);
  });

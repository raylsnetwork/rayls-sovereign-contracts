import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp1155ByName } from '../../tokens/checkTokenAllChains';
import { ethers } from 'ethers';
export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

task('dvp:erc1155:enygma:swap', 'Swap for Enygma Erc1155Dvp example on the PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('tokenId', 'The Token Id')
  .addParam('tokenValue', 'The amount of Token')
  .addOptionalParam('tokenData', 'The token data')
  .addParam('tokenName', 'token name')
  .addParam('enygmaAmount', 'Amount of Enygma to receive')
  .addParam('enygmaResourceId', 'Resource Id of the Enygma to receive')
  .addParam('destChainId', 'The chainId of the destination chain')
  .addParam('sharedId', 'shared id')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();
    console.log(`Swap token ${taskArgs.tokenId} on ${taskArgs.pn} ...`);
    spinner.start();

    // shared id is not provided, generate a random bytes32 shared Id
    if (taskArgs.sharedId === "0x") {
      taskArgs.sharedId = ethers.keccak256(ethers.randomBytes(32));
    }    

    const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.tokenName);

    console.log(`Swapping ERC1155 -> Enygma id=${taskArgs.tokenId} with chain=${taskArgs.destChainId} sharedId=${taskArgs.sharedId}`);
    const txSwap = await token.swapWithDvpForEnygma(
      taskArgs.tokenId,
      taskArgs.tokenValue,
      taskArgs.tokenData || "",
      taskArgs.enygmaAmount,
      taskArgs.enygmaResourceId,
      taskArgs.destChainId,
      taskArgs.sharedId,
      0,
      { gasLimit: 5000000 }
    );
    await txSwap.wait();

    spinner.stop();

    console.log(`✅ Swap on PN ${taskArgs.pn} completed`);
  });

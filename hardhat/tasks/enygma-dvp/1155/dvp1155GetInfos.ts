import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp1155ByName, getDvp1155ByUriOnPNH } from '../../tokens/checkTokenAllChains';
import { SharedObjects } from '../../../../typechain-types/src/rayls-protocol-sdk/tokens/RaylsErc1155DvpHandler';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');

type TokensWithSupply = {
  tokenIds: bigint[];
  supplies: bigint[];
};

task('dvp:erc1155:get-infos', 'Get 1155 on PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('name', 'name')
  .addOptionalParam('id', 'Token id')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();

    spinner.start();

    let token;

    if (taskArgs.pn === 'PNH') {
      token = await getDvp1155ByUriOnPNH(hre, taskArgs.pn, taskArgs.name);
    } else {
      token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);
      const pnCommunicatorAddress = await token.getPNCommunicatorAddress();

      console.log(`PN Communicator Address  ${pnCommunicatorAddress}`);

    }

    let extraDataResult;

    if (taskArgs.id) {
      extraDataResult = await token.getTokenExtraData(taskArgs.id);
    }

    spinner.stop();

    const allTokens = await token.getAllTokenIdsWithSupply();
    console.log(`# Token Ids ${allTokens.length}`);
    console.log(`Token Ids and balances:`);

    for (let i = 0; i < allTokens.length; i++) {
      const tokenWithSUpply = allTokens[i] as SharedObjects.ERC1155SupplyStructOutput;
      const tokenId = tokenWithSUpply.id;
      const supply = tokenWithSUpply.amount;
      console.log(`  Token Id: ${tokenId}, Supply: ${supply}`);
    }


    if (extraDataResult) {
      extraDataResult.forEach((data: any, index: number) => {
        console.log(`Extra Data index -> [${index + 1}]:`);
        console.log(`  Key: ${data[0]}`);
        console.log(`  Value: ${data[1]}`);
        console.log(`  Is Public: ${data[2]}`);
      });
    }
  });

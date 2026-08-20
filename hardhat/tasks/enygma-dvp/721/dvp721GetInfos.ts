import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getDvp721BySymbol, getDvp721BySymbolOnPNH } from '../../tokens/checkTokenAllChains';

task('dvp:erc721:get-infos', 'Get 721 on PN')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('symbol', 'symbol')
  .addOptionalParam('id', 'nft id')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();

    spinner.start();

    let token;

    if (taskArgs.pn === 'PNH') {
      token = await getDvp721BySymbolOnPNH(hre, taskArgs.pn, taskArgs.symbol);
    } else {
      token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.symbol);
      const pnCommunicatorAddress = await token.getPNCommunicatorAddress();
      
      console.log(`PN Communicator Address  ${await token.getPNCommunicatorAddress()}`);

    }

    let extraDataResult;

    if (taskArgs.id) {
      extraDataResult = await token.getNftExtradaData(taskArgs.id);         
    }

    spinner.stop();    

    console.log(`Token Name  ${await token.name()}`);
    console.log(`Token Symbol  ${await token.symbol()}`);
    console.log(`Token Nfts Ids  ${await token.getTotalSupply()}`);   

    if (extraDataResult) {

      extraDataResult.forEach((data: any, index: number) => {
        
        console.log(`Extra Data index -> [${index + 1}]:`);
        console.log(`  Key: ${data[0]}`);
        console.log(`  Value: ${data[1]}`);
        console.log(`  Is Public: ${data[2]}`);
        
      });
    }    
  });

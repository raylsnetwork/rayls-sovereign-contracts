import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc20BySymbol } from '../checkTokenAllChains';

task('tokens:erc20:get-infos', 'Retrives token infos')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D, PNH)')
  .addParam('symbol', 'The token symbol')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log('Checking token infos...');
    spinner.start();
    const token = await getTokenErc20BySymbol(hre, taskArgs.pn, taskArgs.symbol);
    const tokenAddress = await token.getAddress();

    const endpointAddress = await token.getEndpointAddress();

    spinner.stop();
    console.log(`- Resource ID: ${await token.resourceId()}`);
    console.log(`- Address: ${tokenAddress}`);
    console.log(`- Total Supply: ${await token.totalSupply()}`);
    console.log(`- Decimals: ${await token.decimals()}`);
    console.log(`- Symbol: ${await token.symbol()}`);
    console.log(`- Name: ${await token.name()}`);
    console.log(`- Endpoint Address: ${endpointAddress}`);
  });

import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc1155BySymbol } from "../checkTokenAllChains";


task('tokens:erc1155:get-balance', 'Prints the balance of and a tokenId on the Privacy Node')
  .addParam('pn', 'The PN (ex: A, B, C, D)')
  .addParam('symbol', 'The ERC 1155 contract symbol')
  .addParam("address", "The account address to check the balance")
  .addParam("id", "The token Id")
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log('Checking balance information...');
    spinner.start();

    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const pnId = process.env[`PRIVACY_NODE_${taskArgs.pn}_CHAIN_ID`];

    if (!pnId) {
      throw new Error(`Chain ID for ${taskArgs.pn} is not defined in environment variables`);
    }

    const token = await getTokenErc1155BySymbol(hre, taskArgs.pn, taskArgs.symbol);

    const balance = await token.balanceOf(taskArgs.address, taskArgs.id)

    spinner.stop();
    console.log(`Balance of ${taskArgs.address} for token ID ${taskArgs.id}: ${balance.toString()}`);

  });

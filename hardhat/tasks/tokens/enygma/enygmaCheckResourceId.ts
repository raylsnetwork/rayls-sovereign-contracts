import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';

task(
  'tokens:enygma:check-resource-id',
  'Checks the resource Id of a token on the Privacy Node',
)
  .addParam(
    'tokenAddress',
    'The address of token contract on origin Privacy Node',
  )
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    console.log('Checking token information...');
    spinner.start();
    const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];

    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(
      process.env['PRIVATE_KEY_SYSTEM'] as string,
    );
    const signer = wallet.connect(provider);

    const token = await hre.ethers.getContractAt(
      'EnygmaTokenExample',
      taskArgs.tokenAddress,
      signer,
    );
    const resourceId = await token.resourceId();
    const symbol = await token.symbol();
    const normalizedSymbol = String(symbol).toUpperCase();

    spinner.stop();
    if (
      resourceId !=
      '0x0000000000000000000000000000000000000000000000000000000000000000'
    ) {
      console.log(
        `The token got successfully registered with the resourceId ${resourceId}`,
      );
      console.log(``);
      console.log(
        `👉 Add the variable below in .env to interact with this token. Always mention by symbol with flag --token ${symbol} `,
      );
      console.log(`TOKEN_${normalizedSymbol}_RESOURCE_ID=${resourceId}`);
    } else {
      console.log(
        `No resource id generated! Wait until Ven Operator approves the token. If so, check if relayer is working properly`,
      );
    }
  });

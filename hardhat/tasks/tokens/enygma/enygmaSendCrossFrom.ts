import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getEnygmaBySymbol } from '../checkTokenAllChains';
import { SharedObjects } from '../../../../typechain-types/RaylsEnygmaHandler';
import { loadProgramData } from './programData';

task('tokens:enygma:send-cross-from', 'Sends enygma from one privacy node to another, on behalf of a user using a wallet with allowance')
  .addParam('symbol', 'The token symbol')
  .addParam('pnorigin', 'The origin PN (e.g., A, B, C, D)')
  .addParam('pndest', 'The primary destination PN (e.g., A, B, C, D)')
  .addParam('from', 'The primary source address. This address must grant allowance to the caller (wallet) of this script')
  .addParam('to', 'The primary destination address')
  .addParam('amount', 'The primary amount to be transferred')
  .addOptionalParam('callablesPath', 'Path to a Json file containing an array of EnygmaProgramData {resourceId, selector, args} for the primary destination')
  .addOptionalParam('pndest1', 'The optional second destination PN')
  .addOptionalParam('to1', 'The optional second destination address')
  .addOptionalParam('amount1', 'The amount for the second destination')
  .addOptionalParam('callablesPath1', 'Path to a Json file containing an array of EnygmaProgramData for the second destination')
  .addOptionalParam('pndest2', 'The optional third destination PN')
  .addOptionalParam('to2', 'The optional third destination address')
  .addOptionalParam('amount2', 'The amount for the third destination')
  .addOptionalParam('callablesPath2', 'Path to a Json file containing an array of EnygmaProgramData for the third destination')
  .addOptionalParam('pndest3', 'The optional fourth destination PN')
  .addOptionalParam('to3', 'The optional fourth destination address')
  .addOptionalParam('amount3', 'The amount for the fourth destination')
  .addOptionalParam('callablesPath3', 'Path to a Json file containing an array of EnygmaProgramData for the fourth destination')
  .addOptionalParam('pndest4', 'The optional fifth destination PN')
  .addOptionalParam('to4', 'The optional fifth destination address')
  .addOptionalParam('amount4', 'The amount for the fifth destination')
  .addOptionalParam('callablesPath4', 'Path to a Json file containing an array of EnygmaProgramData for the fifth destination')
  .setAction(
    async (
      taskArgs: {
        symbol: string;
        pnorigin: string;
        pndest: string;
        from: string;
        to: string;
        amount: string;
        callablesPath?: string;
        pndest1?: string;
        to1?: string;
        amount1?: string;
        callablesPath1?: string;
        pndest2?: string;
        to2?: string;
        amount2?: string;
        callablesPath2?: string;
        pndest3?: string;
        to3?: string;
        amount3?: string;
        callablesPath3?: string;
        pndest4?: string;
        to4?: string;
        amount4?: string;
        callablesPath4?: string;
      },
      hre
    ) => {
      const spinner = new Spinner();

      try {
        console.log('Setting up signer...');
        const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pnorigin}_RPC_URL`];
        if (!rpcUrl) throw new Error(`Missing RPC URL for PN ${taskArgs.pnorigin}.`);
        if (!hre.ethers.isAddress(taskArgs.from)) {
          throw new Error(`Invalid from address: "${taskArgs.from}"`);
        }

        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = wallet.connect(provider);

        console.log('Fetching token...');
        const token = await getEnygmaBySymbol(hre, taskArgs.pnorigin, taskArgs.symbol);
        const decimals = await token.decimals();

        const destinations: string[] = [taskArgs.to];
        const primaryAmount = hre.ethers.parseUnits(taskArgs.amount.toString(), decimals);
        if (primaryAmount <= 0n) {
          throw new Error(`Invalid primary amount: "${taskArgs.amount}". Amount must be a positive number.`);
        }
        const amounts: bigint[] = [primaryAmount];
        const chainIds: number[] = [];
        const allCallables: SharedObjects.EnygmaProgramDataStruct[][] = [];

        if (taskArgs.callablesPath) {
          allCallables.push(loadProgramData(taskArgs.callablesPath, 'callablesPath'));
        } else {
          allCallables.push([])
        }

        // Validate and add primary destination
        const primaryChainId = parseInt(process.env[`PRIVACY_NODE_${taskArgs.pndest}_CHAIN_ID`] || '', 10);
        if (isNaN(primaryChainId)) {
          throw new Error(`Invalid destinationChainId for "${taskArgs.pndest}".`);
        }
        chainIds.push(primaryChainId);

        // Dynamically process additional destinations
        for (let i = 1; i <= 4; i++) {
          const pndestKey = `pndest${i}` as keyof typeof taskArgs;
          const destKey = `to${i}` as keyof typeof taskArgs;
          const amountKey = `amount${i}` as keyof typeof taskArgs;
          const callablesPathKey = `callablesPath${i}` as keyof typeof taskArgs;

          if (taskArgs[pndestKey] && taskArgs[destKey] && taskArgs[amountKey]) {
            const pndest = taskArgs[pndestKey] as string;
            const dest = taskArgs[destKey] as string;
            const amount = hre.ethers.parseUnits((taskArgs[amountKey] as string), decimals);
            const respectiveCallablesPath = taskArgs[callablesPathKey] as string;

            if (!hre.ethers.isAddress(dest)) {
              throw new Error(`Invalid destination address for ${destKey}: "${dest}"`);
            }

            if (amount <= 0n) {
              throw new Error(`Invalid amount for ${amountKey}: "${taskArgs[amountKey]}". Amount must be a positive number.`);
            }

            const chainId = parseInt(process.env[`PRIVACY_NODE_${pndest}_CHAIN_ID`] || '', 10);
            if (isNaN(chainId)) {
              throw new Error(`Invalid destinationChainId for "${pndest}".`);
            }

            destinations.push(dest);
            amounts.push(amount);
            chainIds.push(chainId);

            if (respectiveCallablesPath) {
              allCallables.push(loadProgramData(respectiveCallablesPath, callablesPathKey));
            } else {
              allCallables.push([])
            }
          }
        }

        console.log('Transaction details:');
        console.log('  pnorigin:', taskArgs.pnorigin);
        console.log('  destinations:', destinations);
        console.log('  amounts:', amounts);
        console.log('  chainIds:', chainIds);
        console.log('  callables:', allCallables);

        console.log('Checking balance...');
        const balance = await token.balanceOf(signer.address);
        console.log('Signer address:', signer.address);
        console.log(`Signer balance: ${hre.ethers.formatUnits(balance, decimals)}`);

        console.log('Sending transaction...');
        spinner.start();

        const tx = await token.connect(signer).crossTransferFrom(taskArgs.from, destinations, amounts, chainIds, allCallables);
        const receipt = await tx.wait();
        if (!receipt || receipt.status === 0) {
          throw new Error(`Transaction failed for token "${await token.name()}" (${await token.symbol()}).`);
        }

        console.log(`Transaction successful!`);
        console.log(`Hash: ${tx.hash}`);
      } catch (error) {
        console.error('Error:', error instanceof Error ? error.message : error);
      } finally {
        spinner.stop();
      }
    }
  );

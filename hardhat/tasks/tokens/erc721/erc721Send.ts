/**
 * @deprecated Decommissioning Teleport (vanilla, atomic).
 */
import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getTokenErc721BySymbol } from '../checkTokenAllChains';

task('tokens:erc721:send', 'Sends a token from one privacy node to the other one')
  .addOptionalParam('symbol', 'The token symbol')
  .addOptionalParam('name', 'Deprecated alias for the token symbol')
  .addParam('pnOrigin', 'The origin PN (ex: A, B, C, D)')
  .addParam('pnDest', 'The destination PN (ex: A, B, C, D)')
  .addParam('destinationAddress', 'The destination Address')
  .addParam('id', 'The token Id')  
  .setAction(async (taskArgs, hre) => {
    const spinner: Spinner = new Spinner();
    const tokenSymbol = taskArgs.symbol || taskArgs.name;

    if (!tokenSymbol) {
      throw new Error('Missing token symbol. Use --symbol <SYMBOL>.');
    }

    spinner.start();
    const destinationChainId = process.env[`PRIVACY_NODE_${taskArgs.pnDest}_CHAIN_ID`] as string;

    const token = await getTokenErc721BySymbol(hre, taskArgs.pnOrigin, tokenSymbol);
    try {
      const tx = await token.teleportAtomic(taskArgs.destinationAddress as string, taskArgs.id, destinationChainId);
      let receipt = await tx.wait(2);

      if (receipt?.status === 0) {
        let err = `The token "${token.name}" failed to be sent`;
        throw new Error(err);
      }
      spinner.stop();
      console.log(`Transaction pushed on ${taskArgs.pnOrigin}'s PN`);
      console.log(`Hash: ${tx.hash}`);
    } catch (error: any) {
      spinner.stop();
      const iface = new hre.ethers.Interface(['error TokenIsFrozenForParticipant()']);
      const decodedError = error?.data ? iface.parseError(error.data) : null;
      if (decodedError?.name === 'TokenIsFrozenForParticipant') {
        console.log('Token is frozen for participant');
        return;
      }
      throw error;
    }
  });

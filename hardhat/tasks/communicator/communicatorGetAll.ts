import { task } from 'hardhat/config';
import { Spinner } from '../../utils/spinner';
import { getCommunicatorPN } from './getContract';

task('communicator:get-all', 'Get All shared infos from a PN by shared Id')
  .addParam('pn', 'The Privacy Node identification (ex: A, B, C, D)')
  .addParam('id', 'shared Id')
  .addOptionalParam('isDvp', 'if true, the shared id is a dvp and Status will be decoded')
  .setAction(async (taskArgs, hre) => {
    await hre.run('compile');
    const spinner: Spinner = new Spinner();

    spinner.start();

    const communicatorContract = await getCommunicatorPN(hre, taskArgs.pn);
    const sharedInfos = await communicatorContract.getAllSharedInfo(taskArgs.id);

    console.log(sharedInfos);

    if (taskArgs.isDvp) {

        const enumValuesStatus = [
          'NOSTATUS',
          'Swap721ForEnygmaSent',
          'Swap721ForEnygmaReceived',
          'SwapEnygmaFor721Sent',
          'SwapEnygmaFor721Received',
          'Swap721ForEnygmaProcessing',
          'SwapDoneReadyForWithdraw',
          'Swap1155ForEnygmaSent',
          'Swap1155ForEnygmaReceived',
          'SwapEnygmaFor1155Sent',
          'SwapEnygmaFor1155Received',
          'Swap1155ForEnygmaProcessing',
          'SwapError',
          'SwapCancellationInitiated',
          'SwapCancelled'
        ];

        const enumValuesContext = [
          'Dvp'          
        ];

      spinner.stop();

      sharedInfos[1].forEach((info) => {
        const status = enumValuesStatus[Number(info.status)] || '??';
        const context = enumValuesContext[Number(sharedInfos[0])] || '??';
        console.table({
          contextNumber: sharedInfos[0],
          contextDescription: context,
          statusNumber: info.status,
          statusDescription: status,
          blockNumber: info.blockNumber,
          message: info.message
        });
      });
    } else {
    
      sharedInfos.forEach((info) => {        
        sharedInfos[1].forEach((info) => {          
          console.table({
            contextNumber: sharedInfos[0],            
            statusNumber: info.status,            
            blockNumber: info.blockNumber,
            message: info.message
          });
        });
      });
    }

    spinner.stop();
    
  });
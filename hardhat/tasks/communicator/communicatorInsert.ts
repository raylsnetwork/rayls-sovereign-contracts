import { task } from "hardhat/config";
import { Spinner } from "../../utils/spinner";
import { getCommunicatorPN } from './getContract';

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task("communicator:insert", "Inserts a message into the communicator")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")    
    .addParam("status", "The status id")
    .addParam("id", "The sharedId")
    .addParam("message", "The message to insert")
    .addParam("context", "The context of the message")
    .setAction(async (taskArgs, hre) => {
      console.log(`🔄 Inserting message into the communicator...`);
      await hre.run('compile');
      const spinner: Spinner = new Spinner();
  
      spinner.start();
  
      const communicatorContract = await getCommunicatorPN(hre, taskArgs.pn);

      const tx = await communicatorContract.addSharedInfo(taskArgs.id, taskArgs.status, taskArgs.context, taskArgs.message);
      await tx.wait();

      spinner.stop();

      console.log(`✅ Message inserted into the communicator`);
    });
import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getDvp1155ByName } from "../../tokens/checkTokenAllChains";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task("dvp:erc1155:deposit", "Deposit Erc1155Dvp example on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addParam('name', 'name')
    .addParam("id", "The token Id")
    .addParam("amount", "The amount to deposit")
    .addOptionalParam("data", "The data to deposit")
    .setAction(async (taskArgs, hre) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        console.log(`Depositing token ${taskArgs.id} on ${taskArgs.pn} ...`);
        spinner.start();

        taskArgs.data = taskArgs.data || "0x";

       const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);

        const txPfDeposit = await token.depositIntoDvp(taskArgs.id, taskArgs.amount, taskArgs.data, { gasLimit: 5000000 });
        await txPfDeposit.wait();

        spinner.stop();

        console.log(`✅ Deposit on PN ${taskArgs.pn} completed`);
        // todo: check relayer receives event.
    });
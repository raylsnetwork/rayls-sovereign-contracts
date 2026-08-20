import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getDvp721BySymbol } from "../../tokens/checkTokenAllChains";

task("dvp:erc721:deposit", "Deposit Erc721Dvp example on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")    
    .addParam("id", "The NFT Id")
    .addParam('symbol', 'symbol')
    .setAction(async (taskArgs, hre) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        console.log(`Depositing token ${taskArgs.id} on ${taskArgs.pn} ...`);
        spinner.start();
        
        const token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.symbol);

       const txPfDeposit = await token.depositIntoDvp(taskArgs.id, { gasLimit: 5000000 });
       await txPfDeposit.wait();       

        spinner.stop();

        console.log(`✅ Deposit on PN ${taskArgs.pn} completed`);      

    });
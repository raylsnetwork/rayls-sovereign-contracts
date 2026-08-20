import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getTokenErc20BySymbol } from "../checkTokenAllChains";

task("tokens:erc20:get-balance", "Get the balance of a token")
    .addParam("symbol", "The token symbol")   
    .addParam("pn", "The destination PN (ex: A, B, C, D)")
    .addParam("address", "The account address")    
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        console.log("Getting infos... 🔎");
        spinner.start();        

        const token = await getTokenErc20BySymbol(hre, taskArgs.pn, taskArgs.symbol);
        const balance = await token.balanceOf(taskArgs.address as string);        
        
        spinner.stop();
        
        console.log(`balance: ${balance}`);
    });
import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getEnygmaBySymbol } from "../checkTokenAllChains";

task("tokens:enygma:get-balance", "Get the balance for Enygma in a PN")
    .addParam("symbol", "The token symbol")
    .addParam("pn", "The destination PN (ex: A, B, C, D)")
    .addParam("address", "The destination Address")    
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        console.log("Getting infos... 🔎");
        
        const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pn}_RPC_URL`];
        if (!rpcUrl) throw new Error(`Missing RPC URL for PN ${taskArgs.pn}.`);
  
        const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
        const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const signer = wallet.connect(provider);
        spinner.start();     


        const token = await getEnygmaBySymbol(hre, taskArgs.pn, taskArgs.symbol);
        const decimals = await token.decimals();
        const balance = await token.connect(signer).balanceOf(taskArgs.address as string);

        spinner.stop();

        console.log(`balance: ${hre.ethers.formatUnits(balance, decimals)}`);
    });
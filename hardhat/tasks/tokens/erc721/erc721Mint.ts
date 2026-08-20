import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getTokenErc721BySymbol } from "../checkTokenAllChains";
import * as fs from "fs";
import * as path from "path";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task("tokens:erc721:mint", "Mint Erc721 example on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addParam('name', 'name')
    .addParam("to", "The address to mint to")
    .addParam("id", "The token Id")    
    .addOptionalParam('data', 'data')    
    .setAction(async (taskArgs, hre) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        console.log(`Minting token on ${taskArgs.pn} on ${taskArgs.to} on ${taskArgs.id}...`);
        spinner.start();

        const token = await getTokenErc721BySymbol(hre, taskArgs.pn, taskArgs.name);

        taskArgs.data = taskArgs.data || "0x";
        let extraData = [];

        if (taskArgs.extraDataPath) {
            const extraDataPath = path.join(__dirname, taskArgs.extraDataPath);
            extraData = JSON.parse(fs.readFileSync(extraDataPath, "utf8"));
        }

        let tx = await token.mint(taskArgs.to, taskArgs.id, { gasLimit: 5000000 });
        await tx.wait();

        spinner.stop();

        console.log(`✅ Mint on PN ${taskArgs.pn} completed`);

    });
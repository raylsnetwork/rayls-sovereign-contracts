import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getDvp721BySymbol } from "../../tokens/checkTokenAllChains";
import * as fs from "fs";
import * as path from "path";


task("dvp:erc721:mint", "Mint Erc721Dvp example on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addParam("to", "The address to mint to")
    .addParam("id", "The NFT Id")
    .addParam('symbol', 'symbol')
    .addOptionalParam('extraDataPath', 'extra Data path')
    .setAction(async (taskArgs, hre) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        console.log(`Minting token on ${taskArgs.pn} on ${taskArgs.to} on ${taskArgs.id}...`);
        spinner.start();

        const token = await getDvp721BySymbol(hre, taskArgs.pn, taskArgs.symbol);

        let extraData = [];

        if (taskArgs.extraDataPath) {
            const extraDataPath = path.join(__dirname, taskArgs.extraDataPath);
            extraData = JSON.parse(fs.readFileSync(extraDataPath, "utf8"));
        }

        await token.mint(taskArgs.to, taskArgs.id, extraData, { gasLimit: 5000000 });

        spinner.stop();

        console.log(`✅ Mint on PN ${taskArgs.pn} completed`);

    });
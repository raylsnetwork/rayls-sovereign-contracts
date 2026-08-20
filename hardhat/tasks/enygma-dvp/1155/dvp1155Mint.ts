import { task } from "hardhat/config";
import { Spinner } from "../../../utils/spinner";
import { getDvp1155ByName, getDvp721BySymbol } from "../../tokens/checkTokenAllChains";
import * as fs from "fs";
import * as path from "path";

export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task("dvp:erc1155:mint", "Mint Erc1155Dvp example on the PN")
    .addParam("pn", "The Privacy Node identification (ex: A, B, C, D)")
    .addParam('name', 'name')
    .addParam("to", "The address to mint to")
    .addParam("id", "The token Id")
    .addParam("value", "The value to mint")
    .addOptionalParam('data', 'data')
    .addOptionalParam('extraDataPath', 'extra data path')
    .setAction(async (taskArgs, hre) => {
        await hre.run("compile");
        const spinner: Spinner = new Spinner();
        console.log(`Minting token on ${taskArgs.pn} on ${taskArgs.to} on ${taskArgs.id}...`);
        spinner.start();
        
        const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);

        const resourceId = await token.resourceId();

        console.log('🚀 ~ .setAction ~ resourceId:', resourceId);

        taskArgs.data = taskArgs.data || "0x";
        let extraData = [];

        if (taskArgs.extraDataPath) {
            const extraDataPath = path.join(__dirname, taskArgs.extraDataPath);
            extraData = JSON.parse(fs.readFileSync(extraDataPath, "utf8"));
        }

        taskArgs.data = taskArgs.data || "0x";

        let tx = await token.mint(taskArgs.to, taskArgs.id, taskArgs.value, taskArgs.data, extraData, { gasLimit: 5000000 });
        await tx.wait();

        spinner.stop();

        console.log(`✅ Mint on PN ${taskArgs.pn} completed`);

    });
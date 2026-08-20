import { task } from "hardhat/config";
import { getDvp1155ByName } from "../../tokens/checkTokenAllChains";
import { Spinner } from "../../../utils/spinner";

task('dvp:erc1155:enygma:cancel', 'Cancel swap of ERC1155 token for Enygma token')
    .addParam(
        'pn',
        'The Privacy Node identification (ex: A, B, C, D)'
    )
    .addParam('name', 'name')
    .addParam('sharedId', 'sharedId')
    .addParam('chainId', 'chainId')
    .addParam('tokenId', 'tokenId')
    .addParam('tokenValue', 'tokenValue')
    .addParam('enygmaResourceId', 'enygmaResourceId')
    .addParam('enygmaAmount', 'enygmaAmount')
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        spinner.start();

        try {
            const token = await getDvp1155ByName(hre, taskArgs.pn, taskArgs.name);

            console.log(`Cancelling swap of ERC1155 -> Enygma id=${taskArgs.tokenId} with chain=${taskArgs.chainId} sharedId=${taskArgs.sharedId}`);
            const tx = await token.cancelSwap(taskArgs.sharedId, taskArgs.chainId, taskArgs.tokenId, taskArgs.tokenValue, taskArgs.enygmaResourceId, taskArgs.enygmaAmount);
            await tx.wait(1);

            console.log(`✅ Cancel swap of ERC1155 -> Enygma on PN ${taskArgs.pn} completed`);
        } catch (error) {
            console.error(error);
        } finally {
            spinner.stop();
        }
    });
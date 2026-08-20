import { task } from "hardhat/config";
import { getEnygmaBySymbol } from "../../tokens/checkTokenAllChains";
import { Spinner } from "../../../utils/spinner";

task('dvp:enygma:erc1155:cancel', 'Cancel swap of Enygma token for ERC1155 token')
    .addParam(
        'pn',
        'The Privacy Node identification (ex: A, B, C, D)'
    )
    .addParam('symbol', 'symbol')
    .addParam('amount', 'amount')
    .addParam('sharedId', 'sharedId')
    .addParam('chainId', 'chainId')
    .addParam('nftId', 'nftId')
    .addParam('nftAmount', 'nftAmount')
    .addParam('nftResourceId', 'nftResourceId')
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        spinner.start();

        try {
            const enygmaToken = await getEnygmaBySymbol(hre, taskArgs.pn, taskArgs.symbol);

            console.log(`Cancelling swap of Enygma -> ERC721 id=${taskArgs.nftId} with chain=${taskArgs.chainId} sharedId=${taskArgs.sharedId}`);
            const tx = await enygmaToken.cancelERC1155Swap(taskArgs.sharedId, taskArgs.chainId, taskArgs.nftId, taskArgs.nftAmount, taskArgs.nftResourceId, taskArgs.amount);
            await tx.wait(1);

            console.log(`✅ Cancel swap of Enygma -> ERC721 on PN ${taskArgs.pn} completed`);
        } catch (error) {
            console.error(error);
        } finally {
            spinner.stop();
        }
    });
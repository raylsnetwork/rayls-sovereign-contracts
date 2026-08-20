import { task } from 'hardhat/config';
import { getEnygmaBySymbol } from '../../tokens/checkTokenAllChains';
import { Spinner } from '../../../utils/spinner';
import { ethers } from 'ethers';
task('dvp:enygma:erc721:swap', 'Swap Enygma token for ERC721 token')
    .addParam(
        'pn',
        'The Privacy Node identification (ex: A, B, C, D)'
    )
    .addParam('symbol', 'symbol')
    .addParam('amount', 'amount')
    .addParam('nftId', 'nftId')
    .addParam('nftResourceId', 'nftResourceId')
    .addParam('chainId', 'chainId')
    .addParam('sharedId', 'sharedId')
    .setAction(async (taskArgs, hre) => {
        const spinner: Spinner = new Spinner();
        spinner.start();

        try {
            // shared id is not provided, generate a random bytes32 shared Id
            if (taskArgs.sharedId === "0x") {
                taskArgs.sharedId = ethers.keccak256(ethers.randomBytes(32));
            }

            const enygmaToken = await getEnygmaBySymbol(hre, taskArgs.pn, taskArgs.symbol);

            console.log(`Swapping Enygma -> ERC721 id=${taskArgs.nftId} with chain=${taskArgs.chainId} sharedId=${taskArgs.sharedId}`);
            const tx = await enygmaToken.swapWithDvpForERC721(taskArgs.nftId, taskArgs.nftResourceId, taskArgs.amount, taskArgs.chainId, taskArgs.sharedId, 0, { gasLimit: 5000000 });
            await tx.wait(1);
        } catch (error) {
            console.error(error);
        } finally {
            spinner.stop();
        }
    });

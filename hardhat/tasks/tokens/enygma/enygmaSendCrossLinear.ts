import { task } from 'hardhat/config';
import { Spinner } from '../../../utils/spinner';
import { getEnygmaBySymbol } from '../checkTokenAllChains';
import { SharedObjects } from '../../../../typechain-types/RaylsEnygmaHandler';
import { SELECTOR_REGEX } from './programData';


task('tokens:enygma:send-cross-linear', 'Sends enygma from one privacy node to another')
    .addParam('symbol', 'The token symbol')
    .addParam('pnorigin', 'The origin PN (e.g., A, B, C, D)')
    .addParam('pndest', 'The destination PN (e.g., A, B, C, D)')
    .addParam('to', 'The destination address')
    .addParam('amount', 'The amount to be transferred')
    .addOptionalParam('callableResourceId', 'The resource ID of the programmability target (use this OR callableContractAddress)')
    .addOptionalParam('callableContractAddress', 'The contract address of the programmability target (use this OR callableResourceId)')
    .addOptionalParam('callableSelector', 'The 4-byte selector of the function to invoke on the target')
    .addOptionalParam('callableArgs', 'The ABI-encoded args (incl. a zero originSender slot for owner-attested selectors)')
    .setAction(
        async (
            taskArgs: {
                symbol: string;
                pnorigin: string;
                pndest: string;
                to: string;
                amount: string;
                callableResourceId?: string;
                callableContractAddress?: string;
                callableSelector?: string;
                callableArgs?: string;
            },
            hre
        ) => {
            const spinner = new Spinner();

            try {
                console.log('Setting up signer...');
                const rpcUrl = process.env[`PRIVACY_NODE_${taskArgs.pnorigin}_RPC_URL`];
                if (!rpcUrl) throw new Error(`Missing RPC URL for PN ${taskArgs.pnorigin}.`);

                const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
                console.log('rpc -->', rpcUrl);
                const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
                const signer = wallet.connect(provider);

                console.log('Fetching token...');
                const token = await getEnygmaBySymbol(hre, taskArgs.pnorigin, taskArgs.symbol);
                const decimals = await token.decimals();
                console.log('token -->', await token.symbol());
                // Validate destination address
                if (!hre.ethers.isAddress(taskArgs.to)) {
                    throw new Error(`Invalid destination address: "${taskArgs.to}"`);
                }

                // Validate amount
                const amount = hre.ethers.parseUnits(taskArgs.amount.toString(), decimals);
                if (amount <= 0n) {
                    throw new Error(`Invalid amount: "${taskArgs.amount}". Amount must be a positive number.`);
                }

                // Get destination chain ID
                const chainId = parseInt(process.env[`PRIVACY_NODE_${taskArgs.pndest}_CHAIN_ID`] || '', 10);
                if (isNaN(chainId)) {
                    throw new Error(`Invalid destinationChainId for "${taskArgs.pndest}".`);
                }

                // Optional single programmability step ([] = plain transfer). The target is set by
                // EXACTLY ONE of callableResourceId / callableContractAddress. Owner-attested
                // selectors require callableArgs to carry a zero originSender slot (executor stamps it).
                const userProgramData: SharedObjects.EnygmaProgramDataStruct[] = [];
                if (taskArgs.callableResourceId || taskArgs.callableContractAddress || taskArgs.callableSelector || taskArgs.callableArgs) {
                    if (!taskArgs.callableSelector) {
                        throw new Error('callableSelector is required when supplying a callable');
                    }
                    if (!SELECTOR_REGEX.test(taskArgs.callableSelector)) {
                        throw new Error(`callableSelector "${taskArgs.callableSelector}" must match 0x + 8 hex digits`);
                    }
                    if (!!taskArgs.callableResourceId === !!taskArgs.callableContractAddress) {
                        throw new Error('supply exactly one of callableResourceId or callableContractAddress');
                    }
                    userProgramData.push({
                        resourceId: taskArgs.callableResourceId ? hre.ethers.zeroPadValue(taskArgs.callableResourceId, 32) : hre.ethers.ZeroHash,
                        contractAddress: taskArgs.callableContractAddress ? hre.ethers.getAddress(taskArgs.callableContractAddress) : hre.ethers.ZeroAddress,
                        selector: taskArgs.callableSelector,
                        args: taskArgs.callableArgs || '0x',
                    });
                }

                console.log('Transaction details:');
                console.log('  pnorigin:', taskArgs.pnorigin);
                console.log('  destination:', taskArgs.to);
                console.log('  amount:', hre.ethers.formatUnits(amount, decimals));
                console.log('  chainId:', chainId);
                console.log('  callables:', userProgramData);


                console.log('Checking balance...');
                const balance = await token.balanceOf(signer.address);
                console.log('Signer address:', signer.address);
                console.log(`Signer balance: ${hre.ethers.formatUnits(balance, decimals)}`);

                console.log('Sending transaction...');
                spinner.start();

                const tx = await token.connect(signer).linearCrossTransfer(
                    taskArgs.to,
                    amount,
                    chainId,
                    userProgramData
                );

                const receipt = await tx.wait();
                if (!receipt || receipt.status === 0) {
                    throw new Error(`Transaction failed for token "${await token.name()}" (${await token.symbol()}).`);
                }

                console.log(`Transaction successful!`);
                console.log(`Hash: ${tx.hash}`);
            } catch (error) {
                console.log('error -->', error);
                console.error('Error:', error instanceof Error ? error.message : error);
            } finally {
                spinner.stop();
            }
        }
    );
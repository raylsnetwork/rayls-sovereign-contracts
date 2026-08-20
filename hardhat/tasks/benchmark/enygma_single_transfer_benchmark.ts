import '@nomicfoundation/hardhat-ethers';
import { task, types } from 'hardhat/config';
import fs from 'fs';
import nanoTime from 'nano-time';

import { EnygmaTokenExample, EnygmaV1 } from '../../../typechain-types';
import { collectTransferMetrics } from './traceql';
import { getDeploymentProxyRegistryAddress } from '../utils/deploymentProxyHelper';

const TEMPO_BASE_URL = process.env.TEMPO_BASE_URL ?? 'http://localhost:3200';
const RELAYER_NAME = 'relayer-a';


const GRAFANA_BASE_URL = process.env.GRAFANA_BASE_URL ?? 'http://localhost:3300';



// require('dotenv').config();
const rpcUrlA = process.env[`PRIVACY_NODE_A_RPC_URL`];
const rpcUrlB = process.env[`PRIVACY_NODE_B_RPC_URL`];
const rpcUrlPNH = process.env[`PNH_RPC_URL`];
const deploymentRegistryAddressA = process.env[`PRIVACY_NODE_A_DEPLOYMENT_PROXY_REGISTRY`] as string;
const deploymentRegistryAddressB = process.env[`PRIVACY_NODE_B_DEPLOYMENT_PROXY_REGISTRY`] as string;
const deploymentRegistryAddressPNH = process.env[`PNH_DEPLOYMENT_PROXY_REGISTRY`] as string;

const chainIdA = process.env[`PRIVACY_NODE_A_CHAIN_ID`] as string;
const chainIdB = process.env[`PRIVACY_NODE_B_CHAIN_ID`] as string;


export const genRanHex = (size: number) => [...Array(size)].map(() => Math.floor(Math.random() * 16).toString(16)).join('');


task('benchmark:enygma-single-transfer', 'Benchmarks the Enygma cross transfer by sending one tx at a time, and waiting between transfers')
    .addOptionalParam("n", "The number of transfers to perform, individually", 1, types.int)
    .setAction(async (taskArgs, hre) => {
        const TOTAL_SIM_TXS = taskArgs.n as number;
        const providerA = new hre.ethers.JsonRpcProvider(rpcUrlA);
        const providerB = new hre.ethers.JsonRpcProvider(rpcUrlB);
        const providerPNH = new hre.ethers.JsonRpcProvider(rpcUrlPNH);
        providerA.pollingInterval = 200;
        providerB.pollingInterval = 200;
        providerPNH.pollingInterval = 200;
        const venOperatorWallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
        const wallet1 = hre.ethers.Wallet.createRandom();
        const wallet2 = hre.ethers.Wallet.createRandom();

        const signerA = wallet1.connect(providerA);
        const signerB = wallet2.connect(providerB);
        const signerPNH = venOperatorWallet.connect(providerPNH);

        //const spinner = new Spinner();
        // generate random token name and symbol
        const randHex = `0x${genRanHex(6)}`;
        const tokenName = `enygma-${randHex}`;
        const tokenSymbol = `E_${randHex}`;

        // deploy a token
        const contractsPNH = await getDeploymentProxyRegistryAddress(['Endpoint', 'TokenRegistry'], deploymentRegistryAddressPNH, signerPNH, hre.ethers);
        const endpointAddressPNH = contractsPNH[0];
        const tokenRegistryAddress = contractsPNH[1];        
        

        const contractsA = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddressA, signerA, hre.ethers);
        const contractsB = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddressB, signerB, hre.ethers);

        const tokenEnygma = await hre.ethers.getContractFactory('EnygmaTokenExample', signerA);

        const tokenRegistry = await hre.ethers.getContractAt('TokenRegistryV1', tokenRegistryAddress, signerPNH);        

        const endpointA = await hre.ethers.getContractAt('EndpointV1', contractsA[0], signerA);
        const endpointB = await hre.ethers.getContractAt('EndpointV1', contractsB[0], signerB);
        const endpointPNH = await hre.ethers.getContractAt('EndpointV1', endpointAddressPNH, signerPNH);

        const tokenOnPNA = await tokenEnygma.deploy(tokenName, tokenSymbol, contractsA[0]);

        await Promise.all([tokenOnPNA.waitForDeployment()]);

        // sleep for 10s
        //await sleep(10000);
        console.log(`Token deployed with name: ${tokenName} and symbol ${tokenSymbol}`);
        let tokenResourceId: string = "";


        // register and approve last token
        let regTx = await tokenOnPNA.submitTokenRegistration(0);
        await regTx.wait()

        const isTokenRegistered = await pollCondition(
            async (): Promise<boolean> => {
                const allTokens = await tokenRegistry.getAllTokens();
                const tokenOnPNH = allTokens.find((x) => x.name == tokenName);
                if (!tokenOnPNH) return false;

                tokenResourceId = tokenOnPNH.resourceId;
                return true;
            },
            1000,
            600
        )

        if (!isTokenRegistered || tokenResourceId == "") {
            throw new Error('Token resource ID not found');
        } else {
            console.log(`Token resource ID: ${tokenResourceId}`);
        }

        const updTx = await tokenRegistry.updateStatus(tokenResourceId, 1, { gasLimit: 5000000 });
        await updTx.wait();
        let enygmaContract: undefined | EnygmaV1;

        const isTokenApproved = await pollCondition(
            async (): Promise<boolean> => {
                tokenResourceId = await tokenOnPNA.resourceId();
                if (tokenResourceId == '0x0000000000000000000000000000000000000000000000000000000000000000') return false;

                const enygmaAddr = await endpointPNH.getAddressByResourceId(tokenResourceId);

                enygmaContract = await hre.ethers.getContractAt('EnygmaV1', enygmaAddr, signerPNH);

                return true;
            },
            1000,
            600
        )

        if (!isTokenApproved || enygmaContract === undefined) {
            throw new Error('Enygma contract not found');
        }

        // mint Enygmas
        let tx = await tokenOnPNA.mint(signerA.address, 1000);
        let receipt = await tx.wait();

        if (receipt?.status !== 1) {
            throw new Error('Minting failed');
        }

        let balance = await tokenOnPNA.balanceOf(signerA.address);

        if (balance !== BigInt(1000)) {
            throw new Error(`Balance mismatch after minting. Current: ${balance.toString()}, Expected: 1000`);
        }

        // warmup with crossTransfer from A to B, and then B to A
        console.log(`🛠️ Warm up starting`);
        const initialBlockNumber = await providerPNH.getBlockNumber();

        const crossTransferStart = Date.now();
        tx = await tokenOnPNA.crossTransfer([signerB.address], [10], [chainIdB], [[]]);
        receipt = await tx.wait();

        if (receipt?.status !== 1) {
            throw new Error('Cross transfer failed');
        }

        balance = await tokenOnPNA.balanceOf(signerA.address);

        if (balance !== BigInt(990)) {
            throw new Error(`Balance mismatch after cross transfer. Current: ${balance.toString()}, Expected: 990`);
        }

        const iface = new hre.ethers.Interface(['event transactionReferenceId(bytes32 _referenceId)']);

        const eventLog = receipt?.logs.find((log) => {
            try {
                const parsedLog = iface.parseLog(log);
                return parsedLog?.name === 'transactionReferenceId';
            } catch (error) {
                return false;
            }
        });

        if (!eventLog) {
            throw new Error('transactionReferenceId event not found in transaction receipt logs');
        }

        let parsedEvent;
        try {
            parsedEvent = iface.parseLog(eventLog);
        } catch (error) {
            throw new Error('Error parsing the event log');
        }

        const referenceId = parsedEvent?.args?._referenceId;

        let blockMined = await pollCondition(
            async (): Promise<boolean> => {
                const currentBlockNumber = await providerPNH.getBlockNumber();
                return currentBlockNumber > initialBlockNumber;
            },
            1000,
            300
        );

        if (!blockMined) {
            throw new Error(`Block not mined within the timeout period`);
        }

        let maybeTokenOnPNB: undefined | EnygmaTokenExample = undefined;

        let isTokenBDeployed = await pollCondition(
            async (): Promise<boolean> => {
                const tokenBAddress = await endpointB.getAddressByResourceId(tokenResourceId);
                if (tokenBAddress == '0x0000000000000000000000000000000000000000') return false;
                maybeTokenOnPNB = await hre.ethers.getContractAt('EnygmaTokenExample', tokenBAddress, signerB);
                return true;
            },
            1000,
            300
        )

        if (!isTokenBDeployed || !maybeTokenOnPNB) {
            throw new Error('TokenOnPNB is undefined');
        }

        const tokenOnPNB: EnygmaTokenExample = maybeTokenOnPNB!

        let isBalanceSettled = await pollCondition(
            async (): Promise<boolean> => {
                try {
                    const balanceOnPnB = await tokenOnPNB.balanceOf(signerB.address);

                    if (balanceOnPnB == BigInt(10)) return true;
                    return false;
                } catch (e) {
                    return false;
                }
            },
            1000,
            300
        )

        if (!isBalanceSettled) {
            throw new Error('Balance on PNB is not settled');
        }


        console.log(`🛠️  Checking referenceIds Status`);
        const crossTransferTotalTime = Date.now() - crossTransferStart;
        console.log(`⏰ Cross transfer total time: ${crossTransferTotalTime} ms`);

        let referenceIdStatus1 = await tokenOnPNA.referenceIdStatus(referenceId)
        if (referenceIdStatus1 != BigInt(1)) {
            throw new Error(`Reference ID status1 is not 1`);
        }

        let referenceIdStatus2 = await tokenOnPNB!.referenceIdStatus(referenceId)
        if (referenceIdStatus2 != BigInt(2)) {
            throw new Error(`Reference ID status2 is not 2`);
        }

        console.log(`✅ Checking referenceIds Status`);

        // crossTransfer from B back to A
        console.log(`🛠️  Sending back the enygma tokens from B to A`);
        const txB = await tokenOnPNB!.crossTransfer([signerA.address], [10], [chainIdA], [[]]);
        const receiptB = await txB.wait();

        if (receiptB?.status != 1) {
            throw new Error(`Receipt status is not 1`);
        }

        const balanceB = await tokenOnPNB.balanceOf(signerB.address);

        if (balanceB != BigInt(0)) {
            throw new Error(`Balance B is not 0`);
        }

        // check PN A
        console.log(`🛠️  Checking balance on PN destination A`);

        isBalanceSettled = await pollCondition(
            async (): Promise<boolean> => {
                try {
                    const balanceOnPnA = await tokenOnPNA.balanceOf(signerA.address);

                    if (balanceOnPnA == BigInt(1000)) return true;
                    return false;
                } catch (e) {
                    return false;
                }
            },
            1000,
            300
        )

        if (!isBalanceSettled) {
            throw new Error(`Balance on PN A is not settled`);
        }

        console.log(`✅ Checking balance on PN destination A`);
        console.log(`✅ Warm up done`);

        // run benchmark
        const startTime = Date.now()
        const allMetrics = []
        // remove prefix 0x
        const cleanTokenResourceId = tokenResourceId.replace(/^0x/, '');
        console.log(`cleanTokenResourceId: ${cleanTokenResourceId} `)
        console.log(`🛠️ Sending ${TOTAL_SIM_TXS} cross transfers from A to B, spaced by 20s`);

        for (; allMetrics.length < TOTAL_SIM_TXS;) {
            console.log(`Cross transfer A -> B ${allMetrics.length + 1}`);
            const startTime_nano = nanoTime()
            const tx = await tokenOnPNA.crossTransfer([signerB.address], [1], [chainIdB], [[]], { gasLimit: 5000000 });
            const txSentToPNA_nano = nanoTime()
            const receipt = await tx.wait();
            const txMined_nano = nanoTime()

            if (receipt?.status != 1) {
                throw new Error("Transaction failed");
            }

            console.log(`🛠️  Checking balance on PN destination`);
            isBalanceSettled = await pollCondition(
                async (): Promise<boolean> => {
                    try {
                        const balanceOnPnB = await tokenOnPNB.balanceOf(signerB.address);
                        const balanceOnPnA = await tokenOnPNA.balanceOf(signerA.address);
                        console.log(`Balance on PN destination ${balanceOnPnB}`);
                        console.log(`Balance on PN origin ${balanceOnPnA}`);
                        console.log(`Elapsed time ${(BigInt(nanoTime()) - BigInt(startTime_nano)) / BigInt(1_000_000_000)}s`);
                        if (balanceOnPnA + balanceOnPnB == BigInt(1000)) return true;
                        return false;
                    } catch (e) {
                        return false;
                    }
                },
                100,
                3000
            )
            const endTime_nano = nanoTime()

            if (!isBalanceSettled) {
                throw new Error("Balance not settled");
            }

            console.log(`✅ Transfer settled`)

        
            for (let i = 0; i < 10; i++) { // retry collecting traces for 10 times
                await sleep(30000)

                const telemetryEndTime_nano = nanoTime()               
                // pull TraceQL metrics
                const metrics = await collectTransferMetrics(TEMPO_BASE_URL, BigInt(startTime_nano), BigInt(telemetryEndTime_nano), cleanTokenResourceId, RELAYER_NAME, GRAFANA_BASE_URL)

                if (metrics.length === 0) {
                    console.log("No measurements found. Check telemetry");
                    //didGetMetrics = false;
                    await sleep(10000) // wait 10s
                    continue
                }

                if (metrics.length > 1) {
                    //throw new Error("More than one measurement found.");
                    console.log("More than one measurement found. Using the first one.");
                    //didGetMetrics = false;
                    await sleep(10000) // wait 10s
                    continue
                }

                //didGetMetrics = true

                let metric = metrics[0];
                metric.user_tx_start_time_nano = BigInt(startTime_nano);
                metric.user_tx_ready_to_mine_time_nano = BigInt(txSentToPNA_nano);
                metric.user_tx_mined_time_nano = BigInt(txMined_nano);
                metric.user_tx_end_time_nano = BigInt(endTime_nano);
                metric.user_wait_mine_duration_nano = (BigInt(metric.user_tx_mined_time_nano) - BigInt(metric.user_tx_ready_to_mine_time_nano))
                metric.user_settlement_duration_nano = (BigInt(metric.user_tx_end_time_nano) - BigInt(metric.user_tx_start_time_nano))

                allMetrics.push(metric)
                await sleep(10000)
                break
            }
        }

        // save allMetrics to a CSV file, first line being headers
        const csvData = [Object.keys(allMetrics[0]).join(',')].concat(allMetrics.map(obj => Object.values(obj).join(',')).join('\n')).join('\n');
        // filename with date, and number of txs
        const filename = `metrics_singletx_${TOTAL_SIM_TXS}x_${new Date().toISOString().replace(/:/g, '-').replace(/\./g, '_')}_resourceId-${cleanTokenResourceId}.csv`;
        fs.writeFileSync(filename, csvData);
        console.log(`✅ Metrics saved to ${filename} `);
    })

function sleep(milliseconds: number) {
    return new Promise(resolve => setTimeout(resolve, milliseconds));
}

// Function to perform polling
export async function pollCondition(checkCondition: () => Promise<boolean>, interval: number, maxAttempts: number): Promise<boolean> {
    let attempts = 0;

    const executePoll = async (): Promise<boolean> => {
        const result = await checkCondition();
        attempts++;

        if (result) {
            return true;
        } else if (attempts < maxAttempts) {
            await delay(interval);
            return executePoll();
        } else {
            return false;
        }
    };

    return executePoll();
}

export function delay(ms: number) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

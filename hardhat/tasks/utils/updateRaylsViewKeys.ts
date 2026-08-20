import { task } from 'hardhat/config';

// npx hardhat requestNewDHKeys --pn A --plpk "67f621c48b6c45426b1dedf660446c6be2cc88ddad59bf800fbeb4c5bea4eb25"
// Or use PRIVATE_KEY_SYSTEM from environment:
// npx hardhat requestNewDHKeys --pn A

task('update-rayls-view-keys', 'Sends a request to generate new ML-KEM keys')
  .addParam('pn', `The PN (example: "A")`)
  .addOptionalParam('plpk', `The PN's private MASTER key. Falls back to PRIVATE_KEY_SYSTEM env var if not provided.`)
  .setAction(async (taskArgs, hre) => {
    const pn = taskArgs.pn;
    // Use provided plpk or fall back to PRIVATE_KEY_SYSTEM from environment
    const plpk = taskArgs.plpk || process.env['PRIVATE_KEY_SYSTEM'];
    
    if (!plpk) {
      throw new Error('No private key provided. Either pass --plpk or set PRIVATE_KEY_SYSTEM environment variable.');
    }

    const rpcUrlPl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    console.log(rpcUrlPl)
    const rpcUrlPNH = process.env['PNH_RPC_URL'];
    const providerPl = new hre.ethers.JsonRpcProvider(rpcUrlPl);
    const providerPNH = new hre.ethers.JsonRpcProvider(rpcUrlPNH);

    console.log(`With RPC ${rpcUrlPl}`);
    console.log(`Requesting new ML-KEM keys for node ${pn}`);
    console.log(`Using PNH: ${rpcUrlPNH}`);
    const wallet = new hre.ethers.Wallet(plpk as string);
    const signer = wallet.connect(providerPl);
    const endpoint = await hre.ethers.getContractAt('EndpointV1', process.env[`PRIVACY_NODE_${pn}_ENDPOINT_ADDRESS`] as string, signer);

    const blockNumber = await providerPNH.getBlockNumber();
    const blockNumberPL = await providerPl.getBlockNumber();
    const receipt = await endpoint.requestNewRaylsViewKeys(blockNumber + 30);
    // Wait for the transaction to be mined
    const minedReceipt = await receipt.wait();
    console.log('Transaction mined:', minedReceipt);

    console.log('Status:', minedReceipt?.status);

    // subscribe to the event
    const filter = endpoint.filters['UpdateRaylsViewKeysRequest(uint256)'];
    const events = await endpoint.queryFilter(filter, blockNumberPL, blockNumberPL + 5);
    console.log(events);
  });

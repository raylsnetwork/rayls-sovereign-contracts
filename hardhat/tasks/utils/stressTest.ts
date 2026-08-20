import { task } from 'hardhat/config';

// import file in hardhard/tasks/index.ts
// npx hardhat stressTest --pn-origin A --pn-dest B --token Y --destination-address 0xF9F18B3989f9d6e60c3c32C0208B6807868ae95d --amount 1

task('stressTest', 'Stress test')
  .addParam('token', 'The token symbol')
  .addParam('pnOrigin', 'The origin PN (ex: A, B, C, D)')
  .addParam('pnDest', 'The destination PN (ex: A, B, C, D)')
  .addParam('destinationAddress', 'The destination Address')
  .addParam('amount', 'The amount to be transfered')
  .setAction(async (taskArgs, hre) => {
    for (let i = 0; i < 96; i++) {
      console.log('Stress test: ' + (i + 1) + '\n');
      await hre.run('sendToken', {
        token: taskArgs.token,
        pnOrigin: taskArgs.pnOrigin,
        pnDest: taskArgs.pnDest,
        destinationAddress: taskArgs.destinationAddress,
        amount: taskArgs.amount,
      });
      console.log('Finished stress test: ' + (i + 1) + '\n');
    }
  });

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

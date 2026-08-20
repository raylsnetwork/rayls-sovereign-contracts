module.exports = {
  skipFiles: [
    // Skip test files and mock contracts (but keep mocks for inherited coverage tracking)
    // 'test/',
    // 'mocks/',
  ],
  // Configure the test command
  mocha: {
    grep: "@skip-on-coverage", // Configure a tag for skipping tests
    invert: true // Skip tests with @skip-on-coverage tag
  },
  // Configure Solidity compiler settings to match hardhat.config.ts
  solcOptimizerDetails: {
    peephole: false,
    inliner: false,
    jumpdestRemover: false,
    orderLiterals: false,
    deduplicate: false,
    cse: false,
    constantOptimizer: false,
    yul: false
  },
  // Configure which contracts to measure
  measureStatementCoverage: true,
  measureFunctionCoverage: true,
  measureBranchCoverage: true,
  measureModifierCoverage: true,
};

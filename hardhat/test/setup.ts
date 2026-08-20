// Global setup for tests - configures Chai to handle BigInt comparisons
import { expect, use } from 'chai';


function bigIntPlugin(chai: any, utils: any) {
  const Assertion = chai.Assertion;
  const originalEqual = Assertion.prototype.equal;

  function newEqual(this: any, expected: any) {
    const actual = this._obj;

    if (typeof actual === 'bigint' || typeof expected === 'bigint') {
      try {
        const actualBigInt = BigInt(actual);
        const expectedBigInt = BigInt(expected);
        return this.assert(
          actualBigInt === expectedBigInt,
          'expected #{act} to equal #{exp}',
          'expected #{act} to not equal #{exp}',
          expected,
          actual,
          true
        );
      } catch {
        // Fallback to original if conversion fails
      }
    }

    return originalEqual.apply(this, arguments);
  }

  Assertion.overwriteMethod('equal', function (_super: any) {
    return function (this: any, expected: any) {
        const actual = this._obj;

        if (typeof actual === 'bigint' || typeof expected === 'bigint') {
            try {
                const actualBigInt = BigInt(actual);
                const expectedBigInt = BigInt(expected);
                this.assert(
                    actualBigInt === expectedBigInt,
                    'expected #{act} to equal #{exp}',
                    'expected #{act} to not equal #{exp}',
                    String(expected), // Show original values in error message
                    String(actual),
                    true
                );
            } catch (error) {
                // If conversion to BigInt fails, fallback to original 'equal'
                _super.apply(this, arguments);
            }
        } else {
            _super.apply(this, arguments);
        }
    };
});
}

use(bigIntPlugin);

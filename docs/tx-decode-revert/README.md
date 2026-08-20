# tx:decode-revert — Decode a transaction revert

This Hardhat task fetches a transaction by hash, extracts the revert data, and decodes it using your compiled ABIs — including nested decoding when a `bytes errorData` parameter carries an inner error. Output is colorized for readability.

## Command

```
npx hardhat tx:decode-revert --hash <TX_HASH> [--network <NETWORK>] [--rpc-url <URL>] [--artifacts-dir <DIR>]
```

## Parameters

- `--hash`: Transaction hash to inspect (required)
- `--network`: Hardhat network name to use (optional; if omitted, Hardhat’s default is used)
- `--rpc-url`: Overrides the provider used (optional; ignores `--network` when provided)
- `--artifacts-dir`: Directory with compiled artifacts and ABIs to decode against (optional; defaults to Hardhat’s `paths.artifacts`)

## Examples

Decode on a configured network:

```
npx hardhat tx:decode-revert --hash 0xabc... --network public_chain
```

Decode using a custom RPC URL:

```
npx hardhat tx:decode-revert --hash 0xabc... --rpc-url https://your.rpc/url
```

Use a custom artifacts directory:

```
npx hardhat tx:decode-revert --hash 0xabc... --artifacts-dir ./out
```

## Output format

The task prints the outer error in this canonical form:

```
error <ErrorName>
    <type> <name>: <value>
    <type> <name>: <value>
```

If a parameter named `errorData` of type `bytes` is present and contains revert data, the task decodes that nested error and prints a second block in the same format.

Example (outer + nested):

```
error MessageFailure
    bytes32 messageId: 0x1234...
    bytes errorData: 0x08c379a0...

error Error
    string message: Revert reason string
```

## How it works

1. Loads the transaction and receipt; if the receipt succeeded, nothing to decode.
2. Runs `eth_call` with the original calldata at the transaction’s block to capture revert data.
3. Decodes using your compiled ABIs (from `artifacts` by default), handling:
   - Standard `Error(string)` and `Panic(uint256)`
   - Custom errors via `ethers.Interface.parseError`
4. If a parameter named `errorData` (type `bytes`) is present, recursively decodes the inner error and prints it.

## Raw hex usage

You can decode a revert payload directly without fetching a transaction:

```
npx hardhat tx:decode-revert --revert-data 0xREVERT_DATA_HEX [--artifacts-dir ./artifacts]
```

Alias `--data` is also accepted for parity with `tx:decode-input`.

## Notes

- If state changed after the transaction, `eth_call` at the original block might still fail to reproduce revert data; the task will report when no data can be retrieved.
- Ensure the relevant contracts are compiled so their ABIs exist in your `artifacts` folder, otherwise custom error decoding may not match.

# tx:decode-input — Decode transaction calldata

Decodes a transaction's calldata into function name and parameters using your compiled ABIs. It also recursively decodes nested payloads when parameters of type `bytes` or `bytes[]` contain ABI-encoded function calls.

## Command

```
npx hardhat tx:decode-input [--hash <TX_HASH> | --data <HEX>] [--to <ADDRESS>] [--network <NETWORK>] [--rpc-url <URL>] [--artifacts-dir <DIR>] [--abi-dirs <DIRS>]
```

## Parameters

- `--hash`: Transaction hash to fetch and decode.
- `--data`: Raw calldata hex (0x...). If provided, `--hash` is not required.
- `--to`: Optional target address for context; does not change decoding but is printed.
- `--network`: Hardhat network name.
- `--rpc-url`: Overrides provider URL (takes precedence over `--network`).
- `--artifacts-dir`: Directory with compiled artifacts (defaults to Hardhat's `paths.artifacts`).
- `--abi-dirs`: Comma-separated extra directories containing JSON ABIs to include (e.g., `./out,./deployments/mainnet`).

## Examples

Decode by hash on a configured network:

```
npx hardhat tx:decode-input --hash 0xabc... --network public_chain
```

Decode raw calldata with extra ABI sources:

```
npx hardhat tx:decode-input --data 0xabcdef... --abi-dirs ./out,./abi
```

## Output format

The task prints the function header and parameters. If a parameter contains nested ABI-encoded calldata (bytes/bytes[]), it decodes and prints those nested calls as well.

```
function transferFrom
    address from: 0x...
    address to: 0x...
    uint256 value: 1000000000000000000
```

Nested example:

```
function multicall
    bytes[] data: ["0xabcdef...", "0x1234..."]
    nested[0]:
        function approve
            address spender: 0x...
            uint256 value: 1000
    nested[1]:
        function transfer
            address to: 0x...
            uint256 value: 500
```

## How it works

1. Loads ABIs from the selected artifacts directory and any additional ABI directories.
2. Attempts `Interface.parseTransaction({ data })` across all interfaces to resolve the function by its selector and decode parameters.
3. For parameters with type `bytes` or `bytes[]`, if the value looks like calldata (starts with `0x` and has a 4-byte selector), recursively decodes those as nested function calls.

## Notes

- If multiple contracts define the same selector, the first matching interface will be used. Add more precise ABIs via `--abi-dirs` for better disambiguation.
- Proxy/implementation detection and bytecode-to-build matching are not included in this first version but can be added later if needed.


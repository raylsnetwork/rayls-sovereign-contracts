import { task } from 'hardhat/config';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';
import chalk from 'chalk';

import { ethers } from 'ethers';

type DecodedParam = { name: string; type: string; value: any };
type DecodedError = { name: string; selector: string; params: DecodedParam[]; nested?: DecodedError };

async function* walk(dir: string): AsyncGenerator<string> {
  const { readdir } = await import('fs/promises');
  const { join } = await import('path');
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else if (entry.isFile()) yield full;
  }
}

async function loadInterfaces(artifactsDir: string): Promise<ethers.Interface[]> {
  const ifaces: ethers.Interface[] = [];
  const { readFile } = await import('fs/promises');
  for await (const file of walk(artifactsDir)) {
    if (!file.endsWith('.json')) continue;
    try {
      const buf = await readFile(file, 'utf8');
      const json = JSON.parse(buf);
      if (Array.isArray(json.abi)) {
        try { ifaces.push(new ethers.Interface(json.abi)); } catch {}
      }
    } catch {}
  }
  return ifaces;
}

async function decodeErrorData(revertData: string, ifacesOrDir?: ethers.Interface[] | string): Promise<DecodedError | null> {
  try {
    if (!revertData || typeof revertData !== 'string' || !revertData.startsWith('0x') || revertData.length < 10) {
      return null;
    }
    const selector = revertData.slice(0, 10).toLowerCase();

    if (selector === '0x08c379a0') {
      const reason = ethers.AbiCoder.defaultAbiCoder().decode(['string'], ethers.dataSlice(revertData, 4))[0];
      return { name: 'Error', selector, params: [{ name: 'message', type: 'string', value: reason }] };
    }
    if (selector === '0x4e487b71') {
      const code = ethers.AbiCoder.defaultAbiCoder().decode(['uint256'], ethers.dataSlice(revertData, 4))[0];
      return { name: 'Panic', selector, params: [{ name: 'code', type: 'uint256', value: code }] };
    }

    const interfaces: ethers.Interface[] = Array.isArray(ifacesOrDir)
      ? ifacesOrDir
      : await loadInterfaces((ifacesOrDir as string) || './artifacts');

    for (const iface of interfaces) {
      try {
        const parsed = iface.parseError(revertData);
        if (!parsed) continue;
        const inputs = parsed.fragment.inputs || [];
        const values = parsed.args as any[];
        const params: DecodedParam[] = inputs.map((inp, i) => ({
          name: inp.name && inp.name.length ? inp.name : `param${i}`,
          type: inp.type,
          value: values[i],
        }));

        const errorDataIdx = params.findIndex(p => p.name === 'errorData' && /^bytes(\[\])?$/.test(p.type) && typeof p.value === 'string');
        let nested: DecodedError | undefined;
        if (errorDataIdx !== -1) {
          const inner = params[errorDataIdx].value as string;
          if (inner && inner.startsWith('0x') && inner.length >= 10) {
            const decodedNested = await decodeErrorData(inner, interfaces);
            if (decodedNested) nested = decodedNested;
          }
        }
        return { name: parsed.name, selector, params, nested };
      } catch {}
    }
    return null;
  } catch {
    return null;
  }
}

async function fetchRevertData(hre: HardhatRuntimeEnvironment, hash: string, rpcUrl?: string): Promise<{ raw: string | null; txInfo: any; }> {
  const provider = rpcUrl ? new hre.ethers.JsonRpcProvider(rpcUrl) : hre.ethers.provider;
  const tx = await provider.getTransaction(hash);
  if (!tx) {
    throw new Error(`Transaction not found: ${hash}`);
  }
  const receipt = await provider.getTransactionReceipt(hash);
  if (!receipt) {
    throw new Error(`Receipt not found for tx: ${hash}`);
  }
  if (receipt.status === 1) {
    return { raw: null, txInfo: { tx, receipt } };
  }

  // Try to reproduce the revert and capture data using eth_call at the same block
  let revertData: string | null = null;
  try {
    await provider.call(
      {
        to: tx.to!,
        from: tx.from,
        data: tx.data,
        value: tx.value
      },
      receipt.blockNumber
    );
    // If call didn't throw, no revert data obtainable
  } catch (err: any) {
    revertData = err?.data || err?.error?.data || err?.info?.error?.data || null;
  }
  return { raw: revertData, txInfo: { tx, receipt } };
}

task('tx:decode-revert', 'Fetches a transaction, extracts revert data and decodes it (or decodes raw revert bytes)')
  .addOptionalParam('hash', 'The transaction hash')
  .addOptionalParam('revertData', 'Raw revert data hex (0x...)')
  .addOptionalParam('data', 'Alias for --revert-data')
  .addOptionalParam('rpcUrl', 'Custom RPC URL (overrides selected network)')
  .addOptionalParam('artifactsDir', 'Artifacts directory to decode against (default: Hardhat artifacts path)')
  .setAction(async (taskArgs, hre) => {
    const { hash, revertData, data, rpcUrl, artifactsDir } = taskArgs as { hash?: string; revertData?: string; data?: string; rpcUrl?: string; artifactsDir?: string };

    console.log(chalk.bold('Network:'), chalk.cyan(hre.network.name));
    if (hash) console.log(chalk.bold('Tx:'), chalk.magenta(hash));

    const explicit = revertData || data;
    let raw: string | null = null;
    let txInfo: any = null;
    if (explicit) {
      raw = explicit;
    } else {
      if (!hash) throw new Error('Provide either --hash or --revert-data/--data');
      const out = await fetchRevertData(hre, hash, rpcUrl);
      raw = out.raw;
      txInfo = out.txInfo;
    }
    const artifactsPath = artifactsDir || hre.config.paths.artifacts;

    if (!raw) {
      if (txInfo?.receipt?.status === 1) {
        console.log(chalk.green('Transaction succeeded. No revert to decode.'));
      } else {
        console.log(chalk.yellow('Could not retrieve revert data (call returned no data).'));
      }
      return;
    }

    console.log(chalk.bold('Raw revert data:'), chalk.gray(raw));

    const ifaces = await loadInterfaces(artifactsPath);
    const decoded = await decodeErrorData(raw, ifaces);

    if (!decoded) {
      console.log(chalk.red('Could not match revert to any custom/standard error in artifacts.'));
      return;
    }

    // Pretty print with color
    printDecodedErrorColored(decoded);

    if (decoded.nested) {
      console.log('');
      printDecodedErrorColored(decoded.nested);
    }
  });

function stringifyVal(val: any): string {
  if (typeof val === 'bigint') return val.toString();
  if (Array.isArray(val)) return '[' + val.map(v => stringifyVal(v)).join(', ') + ']';
  if (val && typeof val === 'object' && 'toHexString' in val) {
    try { return (val as any).toHexString(); } catch {}
  }
  return String(val);
}

function printDecodedErrorColored(decoded: DecodedError): void {
  console.log(chalk.redBright.bold(`error ${decoded.name}`));
  for (const p of decoded.params) {
    const val = stringifyVal(p.value);
    console.log('    ' + chalk.gray(p.type) + ' ' + chalk.cyan(p.name) + ': ' + chalk.yellow(val));
  }
}

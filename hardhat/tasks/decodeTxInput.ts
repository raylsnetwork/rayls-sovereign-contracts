import { task } from 'hardhat/config';
import type { HardhatRuntimeEnvironment } from 'hardhat/types';
import chalk from 'chalk';
import { ethers } from 'ethers';

type DecodedFunctionParam = {
  name: string;
  type: string;
  value: any;
  nested?: DecodedFunctionCall | DecodedFunctionCall[];
};
type DecodedFunctionCall = {
  name: string;
  selector: string;
  signature: string;
  params: DecodedFunctionParam[];
};

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

async function loadInterfacesFromDirs(dirs: string[]): Promise<ethers.Interface[]> {
  const ifaces: ethers.Interface[] = [];
  const seen = new Set<string>();
  const { readFile } = await import('fs/promises');
  for (const dir of dirs) {
    try {
      for await (const file of walk(dir)) {
        if (!file.endsWith('.json')) continue;
        if (seen.has(file)) continue;
        seen.add(file);
        try {
          const buf = await readFile(file, 'utf8');
          const json = JSON.parse(buf);
          if (Array.isArray(json.abi)) {
            try { ifaces.push(new ethers.Interface(json.abi)); } catch {}
          }
        } catch {}
      }
    } catch {}
  }
  return ifaces;
}

function isHexDataLikeBytes(data: string): boolean {
  return typeof data === 'string' && data.startsWith('0x') && data.length >= 10;
}

function stringifyVal(val: any): any {
  if (typeof val === 'bigint') return val.toString();
  if (Array.isArray(val)) return val.map((v) => stringifyVal(v));
  if (val && typeof val === 'object' && 'toHexString' in val) {
    try { return (val as any).toHexString(); } catch {}
  }
  return val;
}

async function decodeCalldata(
  data: string,
  ifaces: ethers.Interface[]
): Promise<DecodedFunctionCall | null> {
  if (!isHexDataLikeBytes(data)) return null;
  const selector = data.slice(0, 10).toLowerCase();
  for (const iface of ifaces) {
    try {
      const parsed = iface.parseTransaction({ data });
      if (!parsed) continue;
      const frag = parsed.fragment;
      const signature = frag.format();
      const inputs = frag.inputs || [];
      const values = parsed.args as any[];
      const params: DecodedFunctionParam[] = [];
      for (let i = 0; i < inputs.length; i++) {
        const inp = inputs[i];
        const value = stringifyVal(values?.[i]);
        const param: DecodedFunctionParam = {
          name: inp.name && inp.name.length ? inp.name : `param${i}`,
          type: inp.type,
          value,
        };
        if (typeof value === 'string' && /^bytes(\[\])?$/.test(inp.type) && isHexDataLikeBytes(value)) {
          const nested = await decodeCalldata(value, ifaces);
          if (nested) param.nested = nested;
        } else if (Array.isArray(value) && inp.type === 'bytes[]') {
          const nestedArr: DecodedFunctionCall[] = [];
          for (const v of value) {
            if (typeof v === 'string' && isHexDataLikeBytes(v)) {
              const nested = await decodeCalldata(v, ifaces);
              if (nested) nestedArr.push(nested);
            }
          }
          if (nestedArr.length) param.nested = nestedArr;
        }
        params.push(param);
      }
      return { name: parsed.name, selector, signature, params };
    } catch {}
  }
  return null;
}

function formatDecodedFunction(call: DecodedFunctionCall, indent = 0): string {
  const pad = ' '.repeat(indent);
  const lines: string[] = [];
  lines.push(`${pad}function ${call.name}`);
  for (const p of call.params) {
    const valStr = Array.isArray(p.value) ? JSON.stringify(p.value) : String(p.value);
    const header = `${pad}    ${p.type} ${p.name}: ${valStr}`;
    lines.push(header);
    if (p.nested && !Array.isArray(p.nested)) {
      lines.push(`${pad}    └─ nested:`);
      lines.push(formatDecodedFunction(p.nested, indent + 8));
    } else if (Array.isArray(p.nested)) {
      let idx = 0;
      for (const n of p.nested) {
        lines.push(`${pad}    └─ nested[${idx++}]:`);
        lines.push(formatDecodedFunction(n, indent + 8));
      }
    }
  }
  return lines.join('\n');
}

async function resolveIfaces(hre: HardhatRuntimeEnvironment, artifactsDir?: string, abiDirsCsv?: string): Promise<import('ethers').Interface[]> {
  const dirs = new Set<string>();
  dirs.add(artifactsDir || hre.config.paths.artifacts);
  if (abiDirsCsv) {
    for (const part of abiDirsCsv.split(',').map((s) => s.trim()).filter(Boolean)) {
      dirs.add(part);
    }
  }
  return await loadInterfacesFromDirs(Array.from(dirs));
}

task('tx:decode-input', 'Decodes transaction calldata into function + args, recursively for bytes payloads')
  .addOptionalParam('hash', 'The transaction hash')
  .addOptionalParam('data', 'Raw calldata hex (0x...)')
  .addOptionalParam('to', 'Target contract address (used for context; optional)')
  .addOptionalParam('rpcUrl', 'Custom RPC URL (overrides selected network)')
  .addOptionalParam('artifactsDir', 'Artifacts directory (default: Hardhat artifacts path)')
  .addOptionalParam('abiDirs', 'Comma-separated additional ABI dirs to include')
  .setAction(async (taskArgs, hre) => {
    const { hash, data, to, rpcUrl, artifactsDir, abiDirs } = taskArgs as {
      hash?: string;
      data?: string;
      to?: string;
      rpcUrl?: string;
      artifactsDir?: string;
      abiDirs?: string;
    };

    if (!hash && !data) {
      throw new Error('Provide either --hash or --data');
    }

    console.log(chalk.bold('Network:'), chalk.cyan(hre.network.name));
    if (hash) console.log(chalk.bold('Tx:'), chalk.magenta(hash));
    if (data) console.log(chalk.bold('Data:'), chalk.gray(data.slice(0, 66) + (data.length > 66 ? '...' : '')));
    if (to) console.log(chalk.bold('To:'), chalk.yellow(to));

    let calldata = data as string | undefined;
    if (hash) {
      const provider = rpcUrl ? new hre.ethers.JsonRpcProvider(rpcUrl) : hre.ethers.provider;
      const tx = await provider.getTransaction(hash);
      if (!tx) throw new Error(`Transaction not found: ${hash}`);
      calldata = tx.data;
      if (!to && tx.to) {
        // best-effort context print
        console.log(chalk.bold('To (from tx):'), chalk.yellow(tx.to));
      }
    }

    if (!calldata) {
      throw new Error('No calldata available to decode');
    }

    const ifaces = await resolveIfaces(hre, artifactsDir, abiDirs);
    if (!ifaces.length) {
      console.log(chalk.red('No ABIs found; ensure artifacts or abiDirs are provided.'));
      return;
    }

    const decoded = await decodeCalldata(calldata, ifaces);
    if (!decoded) {
      console.log(chalk.red('Could not match selector to any function in provided ABIs.'));
      return;
    }

    // Pretty print
    console.log(chalk.greenBright.bold(`function ${decoded.name}`));
    for (const p of decoded.params) {
      const baseVal = Array.isArray(p.value) ? JSON.stringify(p.value) : String(p.value);
      console.log('    ' + chalk.gray(p.type) + ' ' + chalk.cyan(p.name) + ': ' + chalk.yellow(baseVal));
      if (p.nested && !Array.isArray(p.nested)) {
        console.log('    ' + chalk.gray('nested:'));
        const block = formatDecodedFunction(p.nested, 8);
        console.log(block);
      } else if (Array.isArray(p.nested)) {
        let idx = 0;
        for (const n of p.nested) {
          console.log('    ' + chalk.gray(`nested[${idx++}]:`));
          const block = formatDecodedFunction(n, 8);
          console.log(block);
        }
      }
    }
  });

import * as fs from 'fs';
import { SharedObjects } from '../../../../typechain-types/RaylsEnygmaHandler';

// Upper bound on program-data steps (blobs) per recipient. Mirrors the on-chain
// `ProgrammabilityExecutorV1.MAX_BLOBS` guardrail so the tooling rejects the same inputs the
// executor would revert on (`ProgramData__TooManyBlobs`). Keep in sync with the contract constant.
export const MAX_BLOBS = 256;

// A well-formed 4-byte function selector: `0x` followed by exactly 8 hex digits.
export const SELECTOR_REGEX = /^0x[0-9a-fA-F]{8}$/;

const ZERO_HASH = '0x' + '0'.repeat(64);
const ZERO_ADDRESS = '0x' + '0'.repeat(40);
const isZeroish = (v?: string): boolean => !v || v === '0x' || v === ZERO_HASH || v === ZERO_ADDRESS;

/**
 * Load and validate a per-recipient EnygmaProgramData[] JSON file, surfacing the executor's on-chain
 * constraints as clear local errors BEFORE the tx is sent:
 *  - step count <= MAX_BLOBS (else `ProgramData__TooManyBlobs` on-chain);
 *  - exactly one of resourceId / contractAddress per step (XOR; else `ProgramData__BothTargetsProvided`);
 *  - a well-formed 4-byte selector.
 *
 * @param path  Filesystem path to the JSON array.
 * @param label Parameter name used in error messages (e.g. `callablesPath1`).
 */
export function loadProgramData(path: string, label: string): SharedObjects.EnygmaProgramDataStruct[] {
  const parsed: SharedObjects.EnygmaProgramDataStruct[] = JSON.parse(fs.readFileSync(path, 'utf8'));
  if (!Array.isArray(parsed)) {
    throw new Error(`"${label}" must contain a JSON array of EnygmaProgramData.`);
  }
  if (parsed.length > MAX_BLOBS) {
    throw new Error(`Can only have up to ${MAX_BLOBS} callables in "${label}" parameter (got ${parsed.length}).`);
  }
  parsed.forEach((step, i) => {
    const hasResourceId = !isZeroish(step.resourceId as string);
    const hasContractAddress = !isZeroish(step.contractAddress as string);
    if (hasResourceId === hasContractAddress) {
      throw new Error(`"${label}" step ${i}: set exactly one of resourceId or contractAddress (got ${hasResourceId ? 'both' : 'neither'}).`);
    }
    if (!SELECTOR_REGEX.test(step.selector as string)) {
      throw new Error(`"${label}" step ${i}: selector "${step.selector}" must match 0x + 8 hex digits.`);
    }
  });
  return parsed;
}

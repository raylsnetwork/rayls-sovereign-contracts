export const ERC_STANDARD_BY_NAME = {
  erc20: 1,
  erc721: 2,
  erc1155: 3,
  enygma: 4,
  'erc721-dvp': 5,
  'erc1155-dvp': 6,
} as const;

export type SupportedTokenStandard = keyof typeof ERC_STANDARD_BY_NAME;

export const SUPPORTED_TOKEN_STANDARDS = Object.keys(ERC_STANDARD_BY_NAME) as SupportedTokenStandard[];

const ERC_STANDARD_NAME_BY_VALUE = new Map<number, SupportedTokenStandard>(
  Object.entries(ERC_STANDARD_BY_NAME).map(([name, value]) => [value, name as SupportedTokenStandard]),
);

const TOKEN_STANDARD_GETTERS = [
  {
    abi: ['function GetERCStandard() view returns (uint8)'],
    method: 'GetERCStandard',
  },
  {
    abi: ['function getErcStandard() view returns (uint8)'],
    method: 'getErcStandard',
  },
] as const;

export function parseTokenStandardName(input: string) {
  const normalizedName = String(input).toLowerCase() as SupportedTokenStandard;
  const value = ERC_STANDARD_BY_NAME[normalizedName];

  if (value === undefined) {
    throw new Error(
      `Unsupported standard "${input}". Use one of: ${SUPPORTED_TOKEN_STANDARDS.join(', ')}`,
    );
  }

  return {
    standardName: normalizedName,
    standardValue: value,
  };
}

export async function detectTokenStandardName(tokenAddress: string, signer: any, ethers: any) {
  for (const getter of TOKEN_STANDARD_GETTERS) {
    try {
      const contract = new ethers.Contract(tokenAddress, getter.abi, signer);
      const rawValue = await contract[getter.method]();
      const standardValue = Number(rawValue);
      const standardName = ERC_STANDARD_NAME_BY_VALUE.get(standardValue);
      if (standardName) {
        return {
          standardName,
          standardValue,
        };
      }
    } catch {
      // Token does not expose this helper or call failed. Try the next known getter.
    }
  }

  return null;
}

export function assertValidAddress(value: string, label: string, ethers: any) {
  if (!ethers.isAddress(value) || value === ethers.ZeroAddress) {
    throw new Error(`Invalid ${label}: ${value}`);
  }

  return value;
}

import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import {
    EnygmaTokenExample,
    Erc721DvpExample,
    Erc1155DvpExample,
    TokenExample,
    DvpErc721PNH,
    DvpErc1155PNH,
    RaylsErc1155Example,
    RaylsErc721Example,
} from "../../../typechain-types";
import { Spinner } from "../../utils/spinner";
import { getDeploymentProxyRegistryAddress } from "../utils/deploymentProxyHelper";
import { ERC_STANDARD_BY_NAME } from "../../utils/tokenStandards";


export async function getTokenErc20BySymbol(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<TokenExample> {
    const normalizedPn: string = String(pn).toUpperCase();
    const normalizedSymbol: string = String(tokenSymbol).toUpperCase();
    const rpcUrl: string | undefined = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);
    const resourceId: string | undefined = process.env[`TOKEN_${normalizedSymbol}_RESOURCE_ID`];
    const fallbackTokenAddress: string | undefined = process.env[`TOKEN_${normalizedSymbol}_ADDRESS`];

    if (resourceId) {
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);
        const endpointAddress = contracts[0];

        const endpoint = await hre.ethers.getContractAt("EndpointV1", endpointAddress, signer);
        const tokenAddress = await endpoint.getAddressByResourceId(resourceId);

        if (tokenAddress !== hre.ethers.ZeroAddress) {
            const token = await hre.ethers.getContractAt("TokenExample", tokenAddress, signer);
            return token as unknown as TokenExample;
        }
    }

    if (fallbackTokenAddress) {
        const token = await hre.ethers.getContractAt("TokenExample", fallbackTokenAddress, signer);
        return token as unknown as TokenExample;
    }

    throw new Error(
        `Could not resolve token ${normalizedSymbol} on PN ${normalizedPn}. ` +
        `Expected TOKEN_${normalizedSymbol}_RESOURCE_ID with an active endpoint mapping or TOKEN_${normalizedSymbol}_ADDRESS in .env.`,
    );
}

export async function getPublicChainTokenBySymbol(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<TokenExample> {
    const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);

    const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', process.env[`PRIVACY_NODE_${pn}_TOKEN_REGISTRY_ADDRESS`] as string, signer);

    const tokenStruct = await tokenRegistry.getTokenBySymbol(tokenSymbol);

    const token = await hre.ethers.getContractAt("TokenExample", tokenStruct.tokenAddress, signer);

    // const [owner] = await hre.ethers.getSigners();

    return token;
}

export async function getTokenByPrivateAddress(hre: HardhatRuntimeEnvironment, pn: string, tokenAddress: string): Promise<TokenExample | RaylsErc721Example | RaylsErc1155Example> {
    const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);

    const tokenRegistry = await hre.ethers.getContractAt('PNTokenRegistryV1', process.env[`PRIVACY_NODE_${pn}_TOKEN_REGISTRY_ADDRESS`] as string, signer);

    const tokenStruct = await tokenRegistry.getTokenByAddress(tokenAddress);

    // Return the appropriate contract type based on the token standard.
    // SharedObjects.ErcStandard: Custom=0, ERC20=1, ERC721=2, ERC1155=3
    const standard = Number(tokenStruct.ercStandard);
    if (standard === ERC_STANDARD_BY_NAME.erc20) {
        return await hre.ethers.getContractAt("TokenExample", tokenStruct.tokenAddress, signer);
    } else if (standard === ERC_STANDARD_BY_NAME.erc721) {
        return await hre.ethers.getContractAt("RaylsErc721Example", tokenStruct.tokenAddress, signer);
    } else if (standard === ERC_STANDARD_BY_NAME.erc1155) {
        return await hre.ethers.getContractAt("RaylsErc1155Example", tokenStruct.tokenAddress, signer);
    } else {
        throw new Error(`Unsupported token standard: ${standard}`);
    }
}

export async function getEnygmaBySymbol(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<EnygmaTokenExample> {
    const normalizedPn: string = String(pn).toUpperCase();
    const normalizedSymbol: string = String(tokenSymbol).toUpperCase();
    const rpcUrl: string | undefined = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const signer = wallet.connect(provider);

    const resourceId: string | undefined = process.env[`TOKEN_${normalizedSymbol}_RESOURCE_ID`];
    const fallbackTokenAddress: string | undefined = process.env[`TOKEN_${normalizedSymbol}_ADDRESS`];

    if (resourceId) {
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const endpoint = await hre.ethers.getContractAt("EndpointV1", contracts[0], signer);
        const tokenAddress = await endpoint.getAddressByResourceId(resourceId);

        if (tokenAddress !== hre.ethers.ZeroAddress) {
            const token = await hre.ethers.getContractAt("EnygmaTokenExample", tokenAddress, signer);
            return token as unknown as EnygmaTokenExample;
        }
    }

    if (fallbackTokenAddress) {
        const token = await hre.ethers.getContractAt("EnygmaTokenExample", fallbackTokenAddress, signer);
        return token as unknown as EnygmaTokenExample;
    }

    throw new Error(
        `Could not resolve token ${normalizedSymbol} on PN ${normalizedPn}. ` +
        `Expected TOKEN_${normalizedSymbol}_RESOURCE_ID with an active endpoint mapping or TOKEN_${normalizedSymbol}_ADDRESS in .env.`,
    );
}


export async function getDvp721BySymbol(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<Erc721DvpExample> {
    const normalizedPn: string = String(pn).toUpperCase();
    const normalizedSymbol: string = String(tokenSymbol).toUpperCase();
    const rpcUrl: string | undefined = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];

    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const signer = wallet.connect(provider);
    const resourceId: string | undefined = process.env[`TOKEN_${normalizedSymbol}_RESOURCE_ID`];
    const fallbackTokenAddress: string | undefined = process.env[`TOKEN_${normalizedSymbol}_ADDRESS`];

    if (resourceId) {
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const endpoint = await hre.ethers.getContractAt('EndpointV1', contracts[0], signer);
        const tokenAddress = await endpoint.getAddressByResourceId(resourceId);

        if (tokenAddress !== hre.ethers.ZeroAddress) {
            const token = await hre.ethers.getContractAt('Erc721DvpExample', tokenAddress, signer);
            return token as unknown as Erc721DvpExample;
        }
    }

    if (fallbackTokenAddress) {
        const token = await hre.ethers.getContractAt('Erc721DvpExample', fallbackTokenAddress, signer);
        return token as unknown as Erc721DvpExample;
    }

    throw new Error(
        `Could not resolve token ${normalizedSymbol} on PN ${normalizedPn}. ` +
        `Expected TOKEN_${normalizedSymbol}_RESOURCE_ID with an active endpoint mapping or TOKEN_${normalizedSymbol}_ADDRESS in .env.`,
    );
}

export async function getDvp1155ByName(hre: HardhatRuntimeEnvironment, pn: string, name: string): Promise<Erc1155DvpExample> {
    const normalizedPn: string = String(pn).toUpperCase();
    const normalizedName: string = String(name).toUpperCase();
    const rpcUrl: string | undefined = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);
    const resourceId: string | undefined = process.env[`TOKEN_${normalizedName}_RESOURCE_ID`];
    const fallbackTokenAddress: string | undefined = process.env[`TOKEN_${normalizedName}_ADDRESS`];

    if (resourceId) {
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const endpoint = await hre.ethers.getContractAt('EndpointV1', contracts[0], signer);
        const tokenAddress = await endpoint.getAddressByResourceId(resourceId);

        if (tokenAddress !== hre.ethers.ZeroAddress) {
            const token = await hre.ethers.getContractAt('Erc1155DvpExample', tokenAddress, signer);
            return token as unknown as Erc1155DvpExample;
        }
    }

    if (fallbackTokenAddress) {
        const token = await hre.ethers.getContractAt('Erc1155DvpExample', fallbackTokenAddress, signer);
        return token as unknown as Erc1155DvpExample;
    }

    throw new Error(
        `Could not resolve token ${normalizedName} on PN ${normalizedPn}. ` +
        `Expected TOKEN_${normalizedName}_RESOURCE_ID with an active endpoint mapping or TOKEN_${normalizedName}_ADDRESS in .env.`,
    );
}

export async function getDvp721BySymbolOnPNH(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<DvpErc721PNH> {
    const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const signer = wallet.connect(provider);

    const resourceId = process.env[`TOKEN_${tokenSymbol}_RESOURCE_ID`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', process.env.PNH_DEPLOYMENT_PROXY_REGISTRY!, signer);
    const dvpAssetsFactoryAddress = await deploymentProxyRegistry.getContract('DvpAssetFactory');

    const dvpAssetsFactory = await hre.ethers.getContractAt('DvpAssetsFactory', dvpAssetsFactoryAddress, signer);
    const dvp721AddressOnPNH = await dvpAssetsFactory.getDvpErc721PNHAddress(resourceId);
    const token = await hre.ethers.getContractAt('DvpErc721PNH', dvp721AddressOnPNH, signer);

    return token;
}

export async function getDvp1155ByUriOnPNH(hre: HardhatRuntimeEnvironment, pn: string, uri: string): Promise<DvpErc1155PNH> {
    const rpcUrl = process.env[`PRIVACY_NODE_${pn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const signer = wallet.connect(provider);

    const resourceId = process.env[`TOKEN_${uri}_RESOURCE_ID`] as string;

    const deploymentProxyRegistry = await hre.ethers.getContractAt('DeploymentProxyRegistryV1', process.env.PNH_DEPLOYMENT_PROXY_REGISTRY!, signer);
    const dvpAssetsFactoryAddress = await deploymentProxyRegistry.getContract('DvpAssetFactory');

    const dvpAssetsFactory = await hre.ethers.getContractAt('DvpAssetsFactory', dvpAssetsFactoryAddress, signer);
    const dvp1155AddressOnPNH = await dvpAssetsFactory.getDvpErc1155PNHAddress(resourceId);
    const token = await hre.ethers.getContractAt('DvpErc1155PNH', dvp1155AddressOnPNH, signer);

    return token;
}

export async function getTokenErc1155BySymbol(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<RaylsErc1155Example> {
    const normalizedPn: string = String(pn).toUpperCase();
    const normalizedSymbol: string = String(tokenSymbol).toUpperCase();
    const rpcUrl: string | undefined = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);

    const signer = wallet.connect(provider);

    const resourceId: string | undefined = process.env[`TOKEN_${normalizedSymbol}_RESOURCE_ID`];
    const fallbackTokenAddress: string | undefined = process.env[`TOKEN_${normalizedSymbol}_ADDRESS`];

    if (resourceId) {
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const endpoint = await hre.ethers.getContractAt('EndpointV1', contracts[0], signer);
        const tokenAddress = await endpoint.getAddressByResourceId(resourceId);

        if (tokenAddress !== hre.ethers.ZeroAddress) {
            const token = await hre.ethers.getContractAt('RaylsErc1155Example', tokenAddress, signer);
            return token as unknown as RaylsErc1155Example;
        }
    }

    if (fallbackTokenAddress) {
        const token = await hre.ethers.getContractAt('RaylsErc1155Example', fallbackTokenAddress, signer);
        return token as unknown as RaylsErc1155Example;
    }

    throw new Error(
        `Could not resolve token ${normalizedSymbol} on PN ${normalizedPn}. ` +
        `Expected TOKEN_${normalizedSymbol}_RESOURCE_ID with an active endpoint mapping or TOKEN_${normalizedSymbol}_ADDRESS in .env.`,
    );
}

export async function getTokenErc721BySymbol(hre: HardhatRuntimeEnvironment, pn: string, tokenSymbol: string): Promise<RaylsErc721Example> {
    const normalizedPn: string = String(pn).toUpperCase();
    const normalizedSymbol: string = String(tokenSymbol).toUpperCase();
    const rpcUrl: string | undefined = process.env[`PRIVACY_NODE_${normalizedPn}_RPC_URL`];
    const provider = new hre.ethers.JsonRpcProvider(rpcUrl);
    const wallet = new hre.ethers.Wallet(process.env['PRIVATE_KEY_SYSTEM'] as string);
    const signer = wallet.connect(provider);
    const resourceId: string | undefined = process.env[`TOKEN_${normalizedSymbol}_RESOURCE_ID`];
    const fallbackTokenAddress: string | undefined = process.env[`TOKEN_${normalizedSymbol}_ADDRESS`];

    if (resourceId) {
        const deploymentRegistryAddress = process.env[`PRIVACY_NODE_${normalizedPn}_DEPLOYMENT_PROXY_REGISTRY`] as string;
        const contracts = await getDeploymentProxyRegistryAddress(['Endpoint'], deploymentRegistryAddress, signer, hre.ethers);

        const endpoint = await hre.ethers.getContractAt('EndpointV1', contracts[0], signer);
        const tokenAddress = await endpoint.getAddressByResourceId(resourceId);

        if (tokenAddress !== hre.ethers.ZeroAddress) {
            const token = await hre.ethers.getContractAt('RaylsErc721Example', tokenAddress, signer);
            return token as unknown as RaylsErc721Example;
        }
    }

    if (fallbackTokenAddress) {
        const token = await hre.ethers.getContractAt('RaylsErc721Example', fallbackTokenAddress, signer);
        return token as unknown as RaylsErc721Example;
    }

    throw new Error(
        `Could not resolve token ${normalizedSymbol} on PN ${normalizedPn}. ` +
        `Expected TOKEN_${normalizedSymbol}_RESOURCE_ID with an active endpoint mapping or TOKEN_${normalizedSymbol}_ADDRESS in .env.`,
    );
}

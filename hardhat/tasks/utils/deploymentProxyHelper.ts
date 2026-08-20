

export async function  getDeploymentProxyRegistryAddress(contracts: string[], deploymentProxyRegistryAddress: string, signer: any, ethers: any) {
    const deploymentRegistry = await ethers.getContractAt('DeploymentProxyRegistryV1', deploymentProxyRegistryAddress, signer);
   
    const contractsAndNames = await Promise.all(contracts.map(async (contract) => {
        const contractAddress = await deploymentRegistry.getContract(contract);
        return {
            contractAddress,
            contractName: contract
        }
    }));
    //return contracts addresses that have name in contracts array
    return contractsAndNames.filter(contract => contracts.includes(contract.contractName)).map(contract => contract.contractAddress);
}
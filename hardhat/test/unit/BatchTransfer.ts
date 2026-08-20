import {
  loadFixture,
} from '@nomicfoundation/hardhat-toolbox/network-helpers';
import { basicDeploySetupUpgrade } from './utils/basicDeploySetupUpgrade';
import hre, { ethers } from "hardhat";
import { genRanHex } from '../../tasks/tokens/erc20/erc20Deploy';
import { mockRelayerEthersLastTransaction, mockRelayerEthersLastTransactionBatch } from './utils/RelayerMockEthers';
import { expect } from 'chai';
import { registerToken } from './utils/tokens';

// Helper function to grant ENDPOINT_SENDER_ROLE to a contract via AUTH-V3 manager
async function authorizeContract(contract: any, endpoint: any, owner: any, label: string) {
  const contractAddress = await contract.getAddress();
  console.log(`[BATCH] Granting ENDPOINT_SENDER_ROLE to ${label} ${contractAddress}`);
  const managerAddr = await endpoint.authority();
  const mgr = await ethers.getContractAt('RaylsAccessManagerV1', managerAddr);
  const roleId = await mgr.getRoleIdByName('ENDPOINT_SENDER');
  await (await mgr.connect(owner).grantRole(roleId, contractAddress, 0)).wait();
  return contractAddress;
}


describe('Batch Transfers', async function () {
  describe('Arbitrary Messages', async function () {
    it("Two Messages V1", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messageA = "V1 A";
      const messageB = "V1 B";

      const resourceIdA = `0x${genRanHex(64)}`;
      const resourceIdB = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceIdA, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      // Grant ENDPOINT_SENDER_ROLE to batchTransferPN1
      const batchTransferPN1Address = await batchTransferPN1.getAddress();
      await authorizeContract(batchTransferPN1, endpointPN1, owner, 'BatchTransfer PN1');

      const batchTransferPN2 = await batchTransfer.deploy(resourceIdB, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      // Grant ENDPOINT_SENDER_ROLE to batchTransferPN2
      const batchTransferPN2Address = await batchTransferPN2.getAddress();
      await authorizeContract(batchTransferPN2, endpointPN2, owner, 'BatchTransfer PN2');

      await batchTransferPN1.send2MessagesV1(messageA, messageB, chainIdPN2, resourceIdB);
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      expect(await batchTransferPN2.messageA()).to.be.equal(messageA);
      expect(await batchTransferPN2.messageB()).to.be.equal(messageB);
    }).timeout(180000);

    it("Two Messages V2", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messageA = "V2 A";
      const messageB = "V2 B";

      const resourceId = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceId, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      // Grant ENDPOINT_SENDER_ROLE to batchTransferPN1
      const batchTransferPN1Address = await batchTransferPN1.getAddress();
      await authorizeContract(batchTransferPN1, endpointPN1, owner, 'BatchTransfer PN1');

      const batchTransferPN2 = await batchTransfer.deploy(resourceId, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      // Grant ENDPOINT_SENDER_ROLE to batchTransferPN2
      const batchTransferPN2Address = await batchTransferPN2.getAddress();
      await authorizeContract(batchTransferPN2, endpointPN2, owner, 'BatchTransfer PN2');

      await batchTransferPN1.send2MessagesV2(
        messageA,
        messageB,
        [
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: ethers.id("")
          },
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: ethers.id("")
          },
        ]
      );

      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      expect(await batchTransferPN2.messageA()).to.be.equal(messageA);
      expect(await batchTransferPN2.messageB()).to.be.equal(messageB);
    }).timeout(180000);

    it("Two Messages V3", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messageA = "V3 A";
      const messageB = "V3 B";

      const resourceId = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceId, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN1, endpointPN1, owner, "BatchTransfer PN1");

      const batchTransferPN2 = await batchTransfer.deploy(resourceId, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN2, endpointPN2, owner, "BatchTransfer PN2");

      await batchTransferPN1.send2MessagesV3(
        messageA,
        messageB,
        [
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: ethers.id("")
          },
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: ethers.id("")
          },
        ]
      );

      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      expect(await batchTransferPN2.messageA()).to.be.equal(messageA);
      expect(await batchTransferPN2.messageB()).to.be.equal(messageB);
    }).timeout(180000);

    it("Two Messages V4", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messageA = "V4 A";
      const messageB = "V4 B";

      const resourceId = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceId, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN1, endpointPN1, owner, "BatchTransfer PN1");

      const batchTransferPN2 = await batchTransfer.deploy(resourceId, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN2, endpointPN2, owner, "BatchTransfer PN2");

      /*
        Obtaining the payloads was a pain. So I came up with two methods.
      */

      // Method 1: Using solidity encoding, and getting it through a event emittion
      const tx = await batchTransferPN1.generateSend2MessagesPayloads(messageA, messageB);
      const receipt = await tx.wait();
      const payloadEvent = receipt!.logs[0];
      const [solidityPayloadA, solidityPayloadB] = ethers.AbiCoder.defaultAbiCoder().decode(["bytes", "bytes"], payloadEvent.data);

      // Method 2: Using hardhat ethers encoding, but with some bytes manipulation
      const hardhatPayloadA = ethers.id("receiveMessageA(string)").slice(0, 10) + ethers.AbiCoder.defaultAbiCoder().encode(
        ["string"],
        [messageA]
      ).slice(2);
      const hardhatPayloadB = ethers.id("receiveMessageB(string)").slice(0, 10) + ethers.AbiCoder.defaultAbiCoder().encode(
        ["string"],
        [messageB]
      ).slice(2);

      // Of course, Methods 1 and 2 should result in the same
      expect(solidityPayloadA).to.be.equal(hardhatPayloadA);
      expect(solidityPayloadB).to.be.equal(hardhatPayloadB);

      await batchTransferPN1.send2MessagesV4(
        [
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: hardhatPayloadA
          },
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: solidityPayloadB
          },
        ]
      );

      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      expect(await batchTransferPN2.messageA()).to.be.equal(messageA);
      expect(await batchTransferPN2.messageB()).to.be.equal(messageB);
    }).timeout(180000);

    it("Two Messages V5", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messageA = "V5 A";
      const messageB = "V5 B";

      const resourceId = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceId, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN1, endpointPN1, owner, "BatchTransfer PN1");

      const batchTransferPN2 = await batchTransfer.deploy(resourceId, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN2, endpointPN2, owner, "BatchTransfer PN2");

      /*
        Obtaining the payloads was a pain. So I came up with two methods.
      */

      // Method 1: Using solidity encoding, and getting it through a event emittion
      const tx = await batchTransferPN1.generateSend2MessagesPayloads(messageA, messageB);
      const receipt = await tx.wait();
      const payloadEvent = receipt!.logs[0];
      const [solidityPayloadA, solidityPayloadB] = ethers.AbiCoder.defaultAbiCoder().decode(["bytes", "bytes"], payloadEvent.data);

      // Method 2: Using hardhat ethers encoding, but with some bytes manipulation
      const hardhatPayloadA = ethers.id("receiveMessageA(string)").slice(0, 10) + ethers.AbiCoder.defaultAbiCoder().encode(
        ["string"],
        [messageA]
      ).slice(2);
      const hardhatPayloadB = ethers.id("receiveMessageB(string)").slice(0, 10) + ethers.AbiCoder.defaultAbiCoder().encode(
        ["string"],
        [messageB]
      ).slice(2);

      // Of course, Methods 1 and 2 should result in the same
      expect(solidityPayloadA).to.be.equal(hardhatPayloadA);
      expect(solidityPayloadB).to.be.equal(hardhatPayloadB);

      await batchTransferPN1.send2MessagesV5(
        [
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: solidityPayloadA
          },
          {
            _dstChainId: chainIdPN2,
            _resourceId: resourceId,
            _payload: hardhatPayloadB
          },
        ]
      );

      await mockRelayerEthersLastTransactionBatch(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      expect(await batchTransferPN2.messageA()).to.be.equal(messageA);
      expect(await batchTransferPN2.messageB()).to.be.equal(messageB);
    }).timeout(180000);

    it("Many Messages", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messagesAmount = 100;
      const messages = [...new Array(messagesAmount)].map(() => genRanHex(50));

      const resourceId = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceId, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN1, endpointPN1, owner, "BatchTransfer PN1");

      const batchTransferPN2 = await batchTransfer.deploy(resourceId, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN2, endpointPN2, owner, "BatchTransfer PN2");

      const selector = ethers.id("receiveMessage(string)").slice(0, 10);
      const payloads = messages.map((message) => selector + ethers.AbiCoder.defaultAbiCoder().encode(
        ["string"],
        [message]
      ).slice(2));

      await batchTransferPN1.sendManyMessages(payloads.map((payload) => ({
        _dstChainId: chainIdPN2,
        _resourceId: resourceId,
        _payload: payload
      })));

      await mockRelayerEthersLastTransactionBatch(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      const messagesPN2 = await batchTransferPN2.getMessages();

      messagesPN2.forEach((message: string) =>
        expect(messages).to.include(message)
      );
    }).timeout(180000);

    it("Too Many Messages", async function () {
      const {
        owner,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const messagesAmount = 300;
      const messages = [...new Array(messagesAmount)].map(() => genRanHex(50));

      const resourceId = `0x${genRanHex(64)}`;

      const batchTransfer = await hre.ethers.getContractFactory("BatchTransfer");

      const batchTransferPN1 = await batchTransfer.deploy(resourceId, await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN1, endpointPN1, owner, "BatchTransfer PN1");

      const batchTransferPN2 = await batchTransfer.deploy(resourceId, await endpointPN2.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(batchTransferPN2, endpointPN2, owner, "BatchTransfer PN2");

      const selector = ethers.id("receiveMessage(string)").substring(0, 10);
      const payloads = messages.map((message) => selector + ethers.AbiCoder.defaultAbiCoder().encode(
        ["string"],
        [message]
      ).substring(2));

      try {
        await batchTransferPN1.sendManyMessages(payloads.map((payload) => ({
          _dstChainId: chainIdPN2,
          _resourceId: resourceId,
          _payload: payload
        })));
      } catch (error: any) {
        expect(error.message).to.include('The max number of transactions allowed in a batch has been exceeded');
        return;
      }

      expect.fail('Expected transaction to revert with a specific error, but it did not');

    }).timeout(180000);
  });

  /** @deprecated Decommissioning Teleport (vanilla, atomic). */
  describe('ERC20 Batch Teleport', async function () {
    it("Two Teleports to same destination (back and forth)", async function () {
      const {
        owner,
        otherAccount,
        account3,
        endpointPN1,
        endpointPN2,
        chainIdPN1,
        chainIdPN2,
        raylsContractFactoryPN2,
        endpointMappings,
        messageIdsAlreadyProcessedOnDeploy,
        tokenRegistry,
        resourceRegistry,
      } = await loadFixture(basicDeploySetupUpgrade);

      // Use fresh empty object instead of copying from deployment to avoid state pollution between tests
      const messageIdsAlreadyProcessed: { [messageIdConcatWithChainId: string]: boolean | null } = {};

      const erc20BatchTeleport = await hre.ethers.getContractFactory("Erc20BatchTeleport");

      const erc20BatchTeleportPN1: any = await erc20BatchTeleport.connect(owner).deploy("Luan Token", "LTk", await endpointPN1.getAddress());
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);
      await authorizeContract(erc20BatchTeleportPN1, endpointPN1, owner, "Erc20BatchTeleport PN1");

      const resourceId = (
        await registerToken(
          erc20BatchTeleportPN1,
          tokenRegistry,
          endpointMappings,
          messageIdsAlreadyProcessed,
          resourceRegistry,
        )
      ).resourceId;

      await erc20BatchTeleportPN1.connect(owner).mint(owner, 1000);
      await mockRelayerEthersLastTransaction(endpointMappings, messageIdsAlreadyProcessed, resourceRegistry);

      await erc20BatchTeleportPN1.batchTeleport([
        {
          to: otherAccount.address,
          value: 100,
          chainId: chainIdPN2
        },
        {
          to: otherAccount.address,
          value: 200,
          chainId: chainIdPN2
        }
      ]);

      await mockRelayerEthersLastTransactionBatch(
        endpointMappings,
        messageIdsAlreadyProcessed,
        resourceRegistry,
      );

      const deployedContractEvent = await raylsContractFactoryPN2.queryFilter(
        raylsContractFactoryPN2.filters.DeployedContract,
      );
      const deployedContractAddress = deployedContractEvent[0].args[0];
      const erc20BatchTeleportPN2 = await hre.ethers.getContractAt(
        'Erc20BatchTeleport',
        deployedContractAddress,
      );

      expect(await endpointPN1.getAddressByResourceId(resourceId)).to.be.equal(
        await erc20BatchTeleportPN1.getAddress(),
      );
      expect(await endpointPN2.getAddressByResourceId(resourceId)).to.be.equal(
        deployedContractAddress,
      );
      expect(await erc20BatchTeleportPN1.getAddressByResourceId(resourceId)).to.be.equal(
        await erc20BatchTeleportPN1.getAddress(),
      );
      expect(await erc20BatchTeleportPN1.name()).to.be.equal(await erc20BatchTeleportPN2.name());
      expect(await erc20BatchTeleportPN1.symbol()).to.be.equal(await erc20BatchTeleportPN2.symbol());
      expect(await erc20BatchTeleportPN2.balanceOf(otherAccount.address)).to.be.equal(300);

      await erc20BatchTeleportPN2
        .connect(otherAccount)
        .batchTeleport([
          {
            to: account3.address,
            value: 100,
            chainId: chainIdPN1
          },
          {
            to: account3.address,
            value: 200,
            chainId: chainIdPN1
          }
        ]);
      await mockRelayerEthersLastTransactionBatch(
        endpointMappings,
        messageIdsAlreadyProcessed,
        resourceRegistry,
      );

      expect(await erc20BatchTeleportPN1.balanceOf(account3.address)).to.be.equal(300);
      expect(await erc20BatchTeleportPN2.balanceOf(otherAccount.address)).to.be.equal(0n);
    });
  });
});
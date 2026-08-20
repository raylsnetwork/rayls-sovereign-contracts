import { expect } from "chai";
import { ethers } from "hardhat";

describe("BroadcastManager", function () {
    let broadcastManager: any;
    let participantManager: any;

    beforeEach(async function () {
        const BroadcastManager = await ethers.getContractFactory("BroadcastManager");
        const ParticipantManager = await ethers.getContractFactory("ParticipantManager");

        // Deploy the ParticipantManager
        participantManager = await ParticipantManager.deploy();
        await participantManager.waitForDeployment();
        console.log(`ParticipantManager deployed at: ${participantManager.target}`);

        // Deploy the BroadcastManager
        broadcastManager = await BroadcastManager.deploy();
        await broadcastManager.waitForDeployment();
        console.log(`BroadcastManager deployed at: ${broadcastManager.target}`);

        // Configure initial records in the BroadcastManager
        await broadcastManager.setParticipantManager(participantManager.target);
    });

    it("Should broadcast participants", async function () {
        // Add participants
        await participantManager.addParticipant(1, "Alice");
        await participantManager.addParticipant(2, "Bob");

        // Broadcast the participants
        const participants = await broadcastManager.broadcastParticipants();

        // Convert returned values to an appropriate format
        const participantNames = participants.map((p: any) => p.name);
        expect(participantNames).to.include("Alice");
        expect(participantNames).to.include("Bob");
    });

    it("Should broadcast Enygma data", async function () {
        const EnygmaManager = await ethers.getContractFactory("EnygmaManager");
        const enygmaManager = await EnygmaManager.deploy();
        await enygmaManager.waitForDeployment();

        // Configure the EnygmaManager in the BroadcastManager
        await broadcastManager.setEnygmaManager(enygmaManager.target);

        // Add Enygma data
        await enygmaManager.setEnygmaData(1, 123, 456, []);
        await enygmaManager.setEnygmaData(2, 789, 101112, []);

        // Broadcast the Enygma data
        const enygmaData = await broadcastManager.broadcastEnygmaData();

        // Verify that the returned data is correct
        const enygmaXValues = enygmaData.map((e: any) => e.babyJubjubX);
        expect(enygmaXValues).to.include(123);
        expect(enygmaXValues).to.include(789);
    });
});
# Participants Management

## Overview
The participants module provides tasks for managing participants in the system, including adding, updating, flagging, and querying participant information across different networks and storage systems.

## Available Tasks

### Add Participant
Add a new participant to the system:
```bash
npx hardhat participants:add --pn A --address 0x1234567890abcdef1234567890abcdef12345678 --role 1 --status 1
```
- `--pn`: Privacy Node identifier
- `--address`: Participant's wallet address
- `--role`: Participant role (1 = Validator, 2 = Relayer, etc.)
- `--status`: Participant status (1 = Active, 0 = Inactive)

### Get All Participants from Private Hub
Retrieve all participants from the private hub:
```bash
npx hardhat participants:get-all
```
- `--pn`: Privacy Node identifier

### Get All Participants from Replica
Retrieve all participants from the replica storage:
```bash
npx hardhat participants:get-all-from-replica --pn A
```
- `--pn`: Privacy Node identifier

### Update Participant Status
Update the status of an existing participant:
```bash
npx hardhat participants:update-status --pn A --address 0x1234567890abcdef1234567890abcdef12345678 --status 0
```
- `--pn`: Privacy Node identifier
- `--address`: Participant's wallet address
- `--status`: New status (1 = Active, 0 = Inactive)

### Update Participant Role
Update the role of an existing participant:
```bash
npx hardhat participants:update-role --pn A --address 0x1234567890abcdef1234567890abcdef12345678 --role 2
```
- `--pn`: Privacy Node identifier
- `--address`: Participant's wallet address
- `--role`: New role (1 = Validator, 2 = Relayer, etc.)

### Flag/Unflag Participant
Flag or unflag a participant:
```bash
npx hardhat participants:flag-unflag --pn A --address 0x1234567890abcdef1234567890abcdef12345678 --flag true
```
- `--pn`: Privacy Node identifier
- `--address`: Participant's wallet address
- `--flag`: Boolean flag (true = flagged, false = unflagged)

### Update Participant Storage Replica
Update participant information in the replica storage:
```bash
npx hardhat participants:update-storage-replica --pn A --address 0x1234567890abcdef1234567890abcdef12345678 --role 1 --status 1
```
- `--pn`: Privacy Node identifier
- `--address`: Participant's wallet address
- `--role`: Participant role
- `--status`: Participant status

### Update Broadcast Permission
Update broadcast permissions for a participant:
```bash
npx hardhat participants:update-broadcast-permission --pn A --address 0x1234567890abcdef1234567890abcdef12345678 --permission true
```
- `--pn`: Privacy Node identifier
- `--address`: Participant's wallet address
- `--permission`: Boolean permission (true = allowed, false = denied)

## Participant Roles
- **1**: Validator - Can validate transactions and blocks
- **2**: Relayer - Can relay messages between networks
- **3**: Observer - Read-only access to system data

## Participant Status
- **0**: Inactive - Participant is not currently active
- **1**: Active - Participant is active and can perform operations

## Important Notes
- All participant operations require appropriate permissions
- Changes to participant status and roles are immediately reflected
- Flagged participants may have restricted access to certain operations
- Replica storage operations ensure consistency across the system

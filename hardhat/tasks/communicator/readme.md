## Communication System

### Deploy communicator
```bash
npx hardhat communicator:deploy --pn A --network dev_pn_0
```
- `--pn`: Privacy Node identifier
- `--network`: Network identifier

### Get all shared information
```bash
npx hardhat communicator:get-all --pn B --id 0xc65a7bb8d6351c1cf70c95a316cc6a92839c986682d98bc35f958f4883f9d2a8
```
- `--pn`: Privacy Node identifier
- `--id`: Shared ID to query
- `--isDvp`: (Optional) If true, decodes DVP status

### Insert communication data
```bash
npx hardhat communicator:insert --pn B --network dev_pn_1 --id 0xc65a7bb8d6351c1cf70c95a316cc6a92839c986682d98bc35f958f4883f9d2a8 --status 6 --message 'error reverted by non auth' --context 0

```
- `--pn`: Privacy Node identifier
- `--network`: Network identifier
- `--id`: Shared ID
- `--status`: Status code
- `--message`: Message to insert
- `--context`: context code


## Status Codes Reference

When using `communicatorGetAll` with `--isDvp` flag, the following status codes are used:

- 0: NOSTATUS
- 1: Swap721ForEnygmaSent
- 2: Swap721ForEnygmaReceived
- 3: SwapEnygmaFor721Sent
- 4: SwapEnygmaFor721Received
- 5: Swap721ForEnygmaProcessing
- 6: SwapDoneReadyForWithdraw
- 7: Swap1155ForEnygmaSent
- 8: Swap1155ForEnygmaReceived
- 9: SwapEnygmaFor1155Sent
- 10: SwapEnygmaFor1155Received
- 11: Swap1155ForEnygmaProcessing
- 12: Error

// AUDIT — AccessManager drift detection.
// See docs/access-manager-migration.md for the operator workflow.
import './audit/check-deploy-selectors';
import './audit/check-onchain-selectors';
import './audit/check-roles';
import './audit/generate-migration';
import './audit/parents';

// DEPLOYS
import './tokens/erc20/erc20Deploy';
import './batch-transfer/deployErc20BatchToken';
import './deploy/privacy-node';
import './deploy/public-chain';
import './deploy/private-hub';
import './deploy/rayls-node';
import './rayls-node';
import './templates/seed-standard-templates';
// INTERACTIONS
import './participants/addParticipant';
import './tokens/approveToken';
import './tokens/approveAllTokens';
import './tokens/approveLastToken';
import './tokens/approveLastTokens';
import './tokens/submitTokenToHub';
import './tokens/submitTokenToPublicChain';
import './tokens/registerToken';
import './endpoint/checkNonceParity';
import './endpoint/checkResourceId';
import './tokens/checkTokenAllChains';
import './tokens/checkTokenResourceId';
import './tokens/erc1155/erc1155Deploy';
import './tokens/getAllTokens';
import './utils/mockRelayer';
import './tokens/erc20/erc20Send';
import './tokens/erc20/erc20GetInfos';
import './tokens/erc20/erc20Mint';
import './tokens/erc20/erc20SetAllowance';
import './tokens/erc20/erc20Burn';
import './utils/checkBlockchainTime';
import './tokens/erc20/erc20GetBalance';
import './batch-transfer/getErc20BatchTokenBalance';
import './batch-transfer/mintErc20BatchToken';
import './batch-transfer/batchTransferErc20BatchToken';
import './batch-transfer/batchTransferArbitraryMessages';
import './batch-transfer/getMessages';
import './participants/flagUnflagParticipant';
import './participants/updateParticipantStatus';
import './participants/updateParticipantRole';

import './participants/getAllParticipantsFromPNH';
import './participants/getAllParticipantsFromReplica';
import './participants/updateParticipantStorageReplica';
// UTILS
import './utils/decodeErrorMessage';

import './utils/stressTest';
import './tokens/erc20/erc20sendBatch';
import './utils/updateRaylsViewKeys';

//ENYGMA
import './tokens/enygma/enygmaMint';
import './tokens/enygma/enygmaBurn';
import './tokens/enygma/enygmaDeploy';
import './tokens/enygma/enygmaCheckResourceId';
import './tokens/enygma/enygmaSendCross';
import './tokens/enygma/enygmaSendCrossFrom';
import './tokens/enygma/enygmaSendCrossFromLinear';
import './tokens/enygma/enygmaSendCrossLinear';
import './tokens/enygma/getEnygmaBalance';
import './participants/updateBroadcastPermission';
import './enygma-dvp/enygma/dvpEnygmaDeposit';
import './enygma-dvp/enygma/dvpEnygmaWithdraw';
import './enygma-dvp/721/swapEnygmaForERC721';
import './enygma-dvp/721/cancelEnygmaForERC721';
import './enygma-dvp/1155/swapEnygmaForERC1155';
import './enygma-dvp/1155/cancelEnygmaForERC1155';

import './tokens/freezeToken';
import './tokens/unfreezeToken';
import './tokens/checkFrozenToken';
import './tokens/getTokenStatuses';

//Dvp
import './enygma-dvp/721/dvp721Deploy';
import './enygma-dvp/721/dvp721GetInfos';
import './enygma-dvp/721/dvp721Mint';
import './enygma-dvp/721/dvp721Burn';
import './enygma-dvp/721/dvp721CheckResourceId';
import './enygma-dvp/721/dvp721Deposit';
import './enygma-dvp/721/dvp721SwapForEnygma';
import './enygma-dvp/721/dvp721WithdrawFromDvp';
import './enygma-dvp/721/dvp721CancelForEnygma';

import './enygma-dvp/1155/dvp1155Deploy';
import './enygma-dvp/1155/dvp1155GetInfos';
import './enygma-dvp/1155/dvp1155Mint';
import './enygma-dvp/1155/dvp1155Burn';
import './enygma-dvp/1155/dvp1155CheckResourceId';
import './enygma-dvp/1155/dvp1155Deposit';
import './enygma-dvp/1155/dvp1155SwapForEnygma';
import './enygma-dvp/1155/dvp1155CancelForEnygma';
import './enygma-dvp/1155/dvp1155WithdrawFromDvp';
import './enygma-dvp/1155/dvp1155PrintAccountBalance';

//Communicator 
import './communicator/communicatorGetAll';
import './communicator/communicatorDeploy';
import './communicator/communicatorInsert';

//DeploymentProxyRegistry
import './deployment-proxy/get-all-contracts';
import './deployment-proxy/get-contract';
import './deployment-proxy/register-contract';
import './deployment-proxy/register-contracts';
import './deployment-proxy/remove-contract';
import './deployment-proxy/update-contract';
// Benchmark
import './benchmark';
// E2E
import './e2e/erc20-light';
// Debugging
import './decodeTxRevert';
import './decodeTxInput';

// Relay Authorization
import './interact/relay-authorization';

// Access Control (Business Roles)
import './interact/access-control';

// erc721
import './tokens/erc721/erc721Deploy';
import './tokens/erc721/erc721CheckResourceId';
import './tokens/erc721/erc721Mint';
import './tokens/erc721/erc721Send';
import './tokens/erc721/erc721GetBalance';
import './tokens/erc721/erc721Burn';
// erc1155
import './tokens/erc1155/erc1155Deploy';
import './tokens/erc1155/erc1155CheckResourceId';
import './tokens/erc1155/erc1155Mint';
import './tokens/erc1155/erc1155Send';
import './tokens/erc1155/erc1155GetBalance';
import './tokens/erc1155/erc1155Burn';

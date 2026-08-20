// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import '../../interfaces/IEnygmaV1.sol';
import '../../interfaces/IEnygmaVerifierk2.sol';
import '../../interfaces/IEnygmaVerifierk3.sol';
import '../../interfaces/IEnygmaVerifierk4.sol';
import '../../interfaces/IEnygmaVerifierk5.sol';
import '../../interfaces/IEnygmaVerifierk6.sol';
import '../../../privateHub/ParticipantStorage/libraries/ParticipantStructs.sol';
import '../../../privateHub/ParticipantStorage/interfaces/IParticipantStorage.sol';
import '../../../privateHub/TokenRegistry/TokenRegistryV1.sol';
import '../../interfaces/IEnygmaPNHEvents.sol';
import '../../../rayls-protocol-sdk/RaylsApp.sol';
import './EnygmaPNEvents.sol';
import './EnygmaTeleport.sol';
import './EnygmaCreator.sol';

contract EnygmaV1 is IEnygmaV1, RaylsApp {
    // Custom Errors
    error EnygmaV1__OnlyFactoryAllowed();

    string private name;
    string private symbol;
    uint8 private decimals;
    uint256 public totalSupplyX = 0;
    uint256 public totalSupplyY = 0;
    uint256 public totalSupply;

    address owner;
    uint256 public ownerChainId;
    uint256 public lastblockNum;
    uint256 public lastblockNumPending;
    address public participantStorageContract;
    address public tokenRegistryContract;
    uint256 public dvpChainId = 0;
    EnygmaTeleport public enygmaTeleport;
    address public immutable factory;

    mapping(uint256 => mapping(uint256 => EnygmaPointWithChainId)) public referenceBalance;
    mapping(uint256 => address) public transferVerifiers;
    PendingTransaction[] public pendingTransactions;
    PendingMintOrBurn[] public pendingMintsAndBurns;
    mapping(uint256 => bool) public pendingBalancesTallied;
    mapping(uint256 => uint256) public lastblockNumAtCurrentBlockNumber;
    mapping(uint256 => uint256) public nextBlockNumber;
    /// @notice Permanent record of every consumed nullifier; never cleared.
    /// @dev O(1) uniqueness ledger: rejects a same-window duplicate nullifier (which the
    ///      `blockNumber > lastblockNum` check can't — both carry the same block), preventing a
    ///      double balance application. Cross-window replay is the blockNumber check's job.
    mapping(uint256 => bool) public consumedNullifiers;

    // DVP Integration Contract
    address public dvpIntegrationContractAddress;

    constructor(EnygmaCreationParams memory params) RaylsApp(params.endpoint, address(0), address(0)) {
        name = params.name;
        symbol = params.symbol;
        decimals = params.decimals;
        lastblockNum = block.number;
        lastblockNumPending = lastblockNum;
        // Initialize the blockNumber chain
        nextBlockNumber[lastblockNum] = lastblockNum;
        owner = params.owner;
        totalSupply = 0;
        participantStorageContract = params.participantStorageContract;

        totalSupplyX = 0;
        totalSupplyY = 1;

        tokenRegistryContract = params.tokenRegistryContract;
        resourceId = params.resourceId;
        ownerChainId = params.ownerChainId;
        enygmaTeleport = EnygmaTeleport(params.enygmaTeleport);
        factory = params.factory;

        initializeBalances();
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert EnygmaV1__OnlyFactoryAllowed();
        _;
    }

    modifier onlyIssuer() {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        bool isAllowed = participantStorage.checkEnygmaIssuerAccountAllowed(msg.sender, ownerChainId);

        require(isAllowed, 'Only Issuer Accounts may perform those actions.');
        _;
    }

    modifier onlyAllowed() {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        bool isAllowed = participantStorage.checkEnygmaAccountAllowed(msg.sender);

        require(isAllowed, 'Only registered accounts can transact');
        _;
    }

    /**
     * @notice Checks if the token is frozen for the current participant
     * @dev This modifier serves as an additional security layer. The primary validation
     *      occurs at the Privacy Node level (EnygmaPNEvents) before reaching this point.
     */
    modifier checkFreeze() {
        TokenRegistryV1 tokenRegistry = TokenRegistryV1(tokenRegistryContract);
        uint256 currentChainId = IRaylsEndpoint(endpoint).getChainId();
        bool isFrozen = tokenRegistry.isTokenFrozenForParticipant(resourceId, currentChainId);

        require(!isFrozen, 'Token is in freeze status for this participant');
        _;
    }

    /// @notice True iff `nullifier` has not been consumed (is available to spend) in any settlement
    ///         window, past or pending.
    /// @dev O(1) lookup against the permanent `consumedNullifiers` ledger rather than a scan of the
    ///      transient `pendingTransactions` array, which is wiped on every finalisation.
    function isNullifierUnspent(uint256 nullifier) public view returns (bool) {
        return !consumedNullifiers[nullifier];
    }

    bool private processing;
    modifier nonReentrant() {
        require(!processing, 'Contract is processing another transaction.');
        processing = true;
        _;
        processing = false;
    }

    function initializeBalances() internal {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
            uint256[] memory enygmaParticipants = participantStorage.getEnygmaAllParticipantsChainIds();

        ensureBalanceInitialized(dvpChainId);

        for (uint256 i = 0; i < enygmaParticipants.length; i++) {
            uint256 chainId = enygmaParticipants[i];
            ensureBalanceInitialized(chainId);
        }
    }

    function updateBalances(uint256 chainId, uint256 amountX, uint256 amountY, uint256 blockNumber) internal {
        (uint256 balanceX, uint256 balanceY) = CurveBabyJubJub.pointAdd(
            referenceBalance[blockNumber][chainId].c1,
            referenceBalance[blockNumber][chainId].c2,
            amountX,
            amountY
        );

        referenceBalance[blockNumber][chainId].c1 = balanceX;
        referenceBalance[blockNumber][chainId].c2 = balanceY;
    }

    function updateSupply(uint256 _chainId, uint256 _blockNumber, SupplyUpdateTx memory _update) external onlyIssuer nonReentrant {
        require(_blockNumber > lastblockNum, 'BlockNumber is already finalised.');
        require(_blockNumber >= lastblockNumPending, 'Invalid BlockNumber.');
        require(_blockNumber <= block.number, 'BlockNumber is bigger than Current Block Number.');
        require(_update.amount > 0, 'No amount to update');
        require(_update.txType == TxType.Mint || _update.txType == TxType.Burn, 'Invalid tx type');

        finalisePendingTransactions(_blockNumber);

        uint256 amountX;
        uint256 amountY;

        if (_update.txType == TxType.Mint) {
            (amountX, amountY) = derivePk(_update.amount);
        }

        if (_update.txType == TxType.Burn) {
            require(_update.amount <= CurveBabyJubJub.P, 'Error: burnValue > P');
            (amountX, amountY) = pedCom(CurveBabyJubJub.P - _update.amount, 0);
        }

        pendingMintsAndBurns.push(
            PendingMintOrBurn({
                pointToAddToBalance: EnygmaPointWithChainId({c1: amountX, c2: amountY, chainId: _chainId}),
                blockNumber: _blockNumber,
                amount: _update.amount,
                transactionType: _update.txType
            })
        );

        lastblockNumPending = _blockNumber;
        updateBalances(_chainId, amountX, amountY, _blockNumber);

        enygmaTeleport.enygmaSupplyUpdated(resourceId, _blockNumber, _update, _chainId);
    }

  function transferBatch(
        TransferProof memory proof,
        bytes[] memory encryptedMessages
    ) public checkFreeze nonReentrant returns (bool) {
        // Extract all proof data in one place (including commitments from TxCommit)
        ExtractedProofData memory proofData = extractProofData(proof);

        validateTransferInputs(proofData);
        verifyTransferProof(proofData.k, proof);
        finalisePendingTransactions(proofData.blockNumber);

        // Add the current transaction to pending balances
        addPendingTransaction(proofData, TxType.Transfer);

        sendEventsBatch(proofData, encryptedMessages);
        lastblockNumPending = proofData.blockNumber;

        emit TransactionSuccessful(msg.sender);
        return true;
    }

    // Centralized extraction of all proof data
    // Public signal layout: [ArrayHashSecrets (k), PublicKeys (k), PreviousCommit (2*k), TxCommit (2*k), Nullifier, BlockNumber, KIndex (k), MessageTags (k)]
    function extractProofData(TransferProof memory proof) internal pure returns (ExtractedProofData memory data) {
        data.k = extractKFromProof(proof);
        data.proofLength = proof.public_signal.length;
        uint256 k = data.k;

        // Extract arrayHashSecrets (k elements starting at 0)
        data.arrayHashSecrets = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            data.arrayHashSecrets[i] = proof.public_signal[i];
        }

        // Extract public keys (k elements starting at k)
        data.publicKeys = new uint256[](k);
        uint256 pkBase = k;
        for (uint256 i = 0; i < k; i++) {
            data.publicKeys[i] = proof.public_signal[pkBase + i];
        }

        // Extract balances/PreviousCommit (k points starting at 2*k)
        data.balances = new Point[](k);
        uint256 balanceBase = 2 * k;
        for (uint256 i = 0; i < k; i++) {
            data.balances[i] = Point({
                c1: proof.public_signal[balanceBase + i * 2],
                c2: proof.public_signal[balanceBase + i * 2 + 1]
            });
        }

        // Extract TxCommit/commitments (k points starting at 4*k)
        data.commitments = new Point[](k);
        uint256 commitBase = 4 * k;
        for (uint256 i = 0; i < k; i++) {
            data.commitments[i] = Point({
                c1: proof.public_signal[commitBase + i * 2],
                c2: proof.public_signal[commitBase + i * 2 + 1]
            });
        }

        // Extract nullifier and blockNumber (after TxCommit at 6*k)
        uint256 nullifierIndex = 6 * k;
        data.nullifier = proof.public_signal[nullifierIndex];
        data.blockNumber = proof.public_signal[nullifierIndex + 1];

        // Extract chainIds/KIndex (k elements starting at 6*k + 2)
        data.chainIds = new uint256[](k);
        uint256 chainIdBase = 6 * k + 2;
        for (uint256 i = 0; i < k; i++) {
            data.chainIds[i] = proof.public_signal[chainIdBase + i];
        }

        // Extract messageTags (k elements starting at 7*k + 2)
        data.messageTags = new uint256[](k);
        uint256 tagBase = 7 * k + 2;
        for (uint256 i = 0; i < k; i++) {
            data.messageTags[i] = proof.public_signal[tagBase + i];
        }

        return data;
    }

    function extractKFromProof(TransferProof memory proof) internal pure returns (uint8) {
        uint256 length = proof.public_signal.length;
        // Formula: 8*k + 2
        // For k=2: 16 + 2 = 18
        // For k=3: 24 + 2 = 26
        // For k=4: 32 + 2 = 34
        // For k=5: 40 + 2 = 42
        // For k=6: 48 + 2 = 50

        if (length == 18) return 2;
        if (length == 26) return 3;
        if (length == 34) return 4;
        if (length == 42) return 5;
        if (length == 50) return 6;

        revert('Invalid public_signal length');
    }

    function finalisePendingTransactions(uint256 currentBlockNumber) internal {
        // Initialize block state if not already set
        if (lastblockNumAtCurrentBlockNumber[currentBlockNumber] == 0) {
            lastblockNumAtCurrentBlockNumber[currentBlockNumber] = lastblockNum;
            copyReferenceBalancesFromBlockNumberSourceToBlockNumberNew(lastblockNumPending, currentBlockNumber);
        }

        // Process pending actions
        if (currentBlockNumber > lastblockNum && (pendingTransactions.length > 0 || pendingMintsAndBurns.length > 0) && currentBlockNumber > lastblockNumPending && lastblockNumPending >= lastblockNum) {
            processPendingActions(lastblockNumPending);
            pendingBalancesTallied[lastblockNumPending] = true;


            nextBlockNumber[lastblockNum] = lastblockNumPending;
            lastblockNum = lastblockNumPending;
            nextBlockNumber[lastblockNumPending]=currentBlockNumber;

            (EnygmaPointWithChainId[] memory balances,) = getPublicValuesByBlockNumber(lastblockNum);

            enygmaTeleport.finalizeBalances(resourceId, lastblockNum, currentBlockNumber, balances);
        }
    }

    function getNextBlockNumberToFinaliseAfter(uint256 blockNumber) public view returns (uint256) {
        return nextBlockNumber[blockNumber];
    }

    function copyReferenceBalancesFromBlockNumberSourceToBlockNumberNew(uint256 blockNumberSource, uint256 blockNumberNew) internal {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        uint256[] memory enygmaParticipants = participantStorage.getEnygmaAllParticipantsChainIds();
        for (uint256 i = 0; i < enygmaParticipants.length; i++) {
            uint256 currentChainId = enygmaParticipants[i];

            ensureBalanceInitialized(currentChainId);

            referenceBalance[blockNumberNew][currentChainId].c1 = referenceBalance[blockNumberSource][currentChainId].c1;
            referenceBalance[blockNumberNew][currentChainId].c2 = referenceBalance[blockNumberSource][currentChainId].c2;
        }

        ensureBalanceInitialized(dvpChainId);

        referenceBalance[blockNumberNew][dvpChainId].c1 = referenceBalance[blockNumberSource][dvpChainId].c1;
        referenceBalance[blockNumberNew][dvpChainId].c2 = referenceBalance[blockNumberSource][dvpChainId].c2;
    }

    function processPendingActions(uint256 blockNumber) internal {
        delete pendingTransactions;

        uint256[] memory indicesToDelete = new uint256[](pendingMintsAndBurns.length);
        uint256 deleteCount = 0;

        for (uint256 i = 0; i < pendingMintsAndBurns.length; i++) {
            PendingMintOrBurn memory pending = pendingMintsAndBurns[i];

            if (pending.blockNumber <= blockNumber) {
                (totalSupplyX, totalSupplyY) = CurveBabyJubJub.pointAdd(totalSupplyX, totalSupplyY, pending.pointToAddToBalance.c1, pending.pointToAddToBalance.c2);
                if (pending.transactionType == TxType.Mint) {
                    totalSupply += pending.amount;
                    emit SupplyMinted(lastblockNum, pending.amount, pending.pointToAddToBalance.chainId);
                } else if (pending.transactionType == TxType.Burn) {
                    totalSupply -= pending.amount;
                    emit BurnSuccessful(pending.pointToAddToBalance.chainId, pending.amount);
                }

                indicesToDelete[deleteCount] = i;
                deleteCount++;
            }
        }

        for (uint256 i = 0; i < deleteCount; i++) {
            uint256 index = indicesToDelete[i];
            delete pendingMintsAndBurns[index];
        }
        uint256 length = pendingMintsAndBurns.length;
        uint256 writeIndex = 0;

        for (uint256 i = 0; i < length; i++) {
            if (pendingMintsAndBurns[i].amount != 0) {
                pendingMintsAndBurns[writeIndex] = pendingMintsAndBurns[i];
                writeIndex++;
            }
        }

        for (uint256 i = writeIndex; i < length; i++) {
            pendingMintsAndBurns.pop();
        }
    }

    function addPendingTransaction(
        ExtractedProofData memory proofData,
        TxType transactionType
    ) internal {
        // Uniqueness invariant enforced at the recording chokepoint, so every entry path is covered:
        // transferBatch re-checks here harmlessly (validateTransferInputs already gated it), and the
        // DVP entrypoint dvpAddPendingTransaction relies on this. Without it a duplicate would apply
        // its balance deltas twice. Distinct, non-retryable string: a hit here means validation was
        // bypassed (a fatal bug), not the transient collision the relayer retries on.
        require(isNullifierUnspent(proofData.nullifier), 'EnygmaV1: nullifier already consumed');

        // Record the nullifier in the permanent ledger immediately after the uniqueness check
        // (checks-effects-interactions: the effect follows the check, before any balance work) so it
        // can never be replayed in a later settlement window after `processPendingActions` clears
        // `pendingTransactions`.
        consumedNullifiers[proofData.nullifier] = true;
        emit NullifierConsumed(resourceId, proofData.nullifier, proofData.blockNumber, transactionType);

        // Create a new PendingTransaction in storage
        PendingTransaction storage newTx = pendingTransactions.push();

        // Populate pointsToAddToBalance and update balances
        for (uint256 i = 0; i < proofData.commitments.length; i++) {
            newTx.pointsToAddToBalance.push(EnygmaPointWithChainId({
                c1: proofData.commitments[i].c1,
                c2: proofData.commitments[i].c2,
                chainId: proofData.chainIds[i]
            }));

            updateBalancesWithDvp(proofData.chainIds[i], proofData.commitments[i].c1, proofData.commitments[i].c2, proofData.blockNumber, transactionType);
        }

        // Set the nullifier and transaction type
        newTx.nullifier = proofData.nullifier;
        newTx.transactionType = transactionType;
    }

    function updateBalancesWithDvp(uint256 chainId, uint256 c1, uint256 c2, uint256 currentBlockNumber, TxType transactionType) private {
        // Update regular balance
        updateBalances(chainId, c1, c2, currentBlockNumber);

        // For Dvp transactions - deposit or withdraw - update dvp balance with negated points
        //If P = (x, y), then -P = (-x, y) so when you add a point and its negation:
        //(x, y) + (-x, y) = (0, 1)
        //Where (0, 1) is the identity element (neutral point) of the curve.
        //Note that in our case -P = C(-v, -r)
        if (transactionType == TxType.Deposit || transactionType == TxType.Withdraw) {
            updateBalances(dvpChainId, negateOnCurve(c1), c2, currentBlockNumber);
            //To decode Enygma DvP Balance we need the negative of the Sum of all r involved in dvp transactions
        }
    }

    function validateTransferInputs(
        ExtractedProofData memory proofData
    ) internal view {
        uint8 k = proofData.k;
        require(k >= 2, 'Invalid value for k');
        // Validate proof length matches formula: 8*k + 2
        require(proofData.proofLength == 8 * k + 2, 'Invalid public_signal length');
        require(proofData.commitments.length == k, 'Wrong commitments length');
        require(proofData.chainIds.length == k, 'Wrong ChainIds Array length');
        require(proofData.publicKeys.length == k && proofData.balances.length == k && proofData.arrayHashSecrets.length == k && proofData.messageTags.length == k, 'Wrong public_signal length in proof');
        require(transferVerifiers[k] != address(0), 'Verifier not set for given k');
        require(proofData.blockNumber > lastblockNum, 'BlockNumber in Proof was already finalised.');
        require(proofData.blockNumber >= lastblockNumPending, 'Invalid BlockNumber Used in Proof.');
        require(proofData.blockNumber <= block.number, 'BlockNumber Used in Proof is bigger than Current Block Number.');
        // The revert string is matched verbatim by the relayer's retryable-error classifier
        // (rayls-privacy-relayer-api enygma/service/retry.go); keep it byte-for-byte unless that
        // list is updated in lockstep, or a legitimate nullifier collision would be misclassified
        // as a fatal error instead of being retried.
        require(isNullifierUnspent(proofData.nullifier), 'Nullifier already used in pending transaction.');

        // Validate public signals match stored values
        (EnygmaPointWithChainId[] memory storedBalances, EnygmaPublicKeyWithChainId[] memory storedPublicKeys) = getPublicValuesByBlockNumber(lastblockNum);

        for (uint256 i = 0; i < k; i++) {
            uint256 balanceIndex = findEnygmaPointIndex(storedBalances, proofData.chainIds[i]);
            uint256 publicKeyIndex = findEnygmaPublicKeyIndex(storedPublicKeys, proofData.chainIds[i]);

            require(balanceIndex < storedBalances.length, 'Matching balance for chainId not found');
            require(publicKeyIndex < storedPublicKeys.length, 'Matching public key for chainId not found');

            require(proofData.publicKeys[i] == storedPublicKeys[publicKeyIndex].publicKey, 'Invalid public signal for pk');
            require(proofData.balances[i].c1 == storedBalances[balanceIndex].c1 && proofData.balances[i].c2 == storedBalances[balanceIndex].c2, 'Invalid public signal for balance');
        }
    }

        function findEnygmaPublicKeyIndex(EnygmaPublicKeyWithChainId[] memory publicKeys, uint256 chainId) internal pure returns (uint256) {
        for (uint256 i = 0; i < publicKeys.length; i++) {
            if (publicKeys[i].chainId == chainId) {
                return i;
            }
        }
        revert('Chain ID not found in public keys array');
    }

    function verifyTransferProof(uint8 k, TransferProof memory proof) internal view {
        if (k == 2) {
            require(proof.public_signal.length == 18, 'Invalid public_signal length for k=2');
            require(IEnygmaVerifierk2(transferVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array18(proof.public_signal)), 'verifyProof returned false: Invalid proof');
        } else if (k == 3) {
            require(proof.public_signal.length == 26, 'Invalid public_signal length for k=3');
            require(IEnygmaVerifierk3(transferVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array26(proof.public_signal)), 'verifyProof returned false: Invalid proof');
        } else if (k == 4) {
            require(proof.public_signal.length == 34, 'Invalid public_signal length for k=4');
            require(IEnygmaVerifierk4(transferVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array34(proof.public_signal)), 'verifyProof returned false: Invalid proof');
        } else if (k == 5) {
            require(proof.public_signal.length == 42, 'Invalid public_signal length for k=5');
            require(IEnygmaVerifierk5(transferVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array42(proof.public_signal)), 'verifyProof returned false: Invalid proof');
        } else if (k == 6) {
            require(proof.public_signal.length == 50, 'Invalid public_signal length for k=6');
            require(IEnygmaVerifierk6(transferVerifiers[k]).verifyProof(proof.pi_a, proof.pi_b, proof.pi_c, convertToUint256Array50(proof.public_signal)), 'verifyProof returned false: Invalid proof');
        } else {
            revert('That value of k is not supported');
        }
    }

    function sendEventsBatch(ExtractedProofData memory proofData, bytes[] memory encryptedMessages) internal {
        // One encrypted message per destination chain; reject a mismatched array with an explicit
        // reason instead of an opaque out-of-bounds panic inside the loop.
        require(encryptedMessages.length == proofData.chainIds.length, 'EnygmaV1: encryptedMessages length mismatch');
        for (uint256 i = 0; i < proofData.chainIds.length; i++) {
            enygmaTeleport.transfer(resourceId, encryptedMessages[i], proofData.messageTags[i], proofData.blockNumber, proofData.chainIds, proofData.arrayHashSecrets, proofData.chainIds[i]);
        }
    }

    function ensureBalanceInitialized(uint256 chainId) internal {
        if (referenceBalance[lastblockNum][chainId].c1 == 0 && referenceBalance[lastblockNum][chainId].c2 == 0) {
            referenceBalance[lastblockNum][chainId].c2 = 1;
        }
        if (referenceBalance[lastblockNumPending][chainId].c1 == 0 && referenceBalance[lastblockNumPending][chainId].c2 == 0) {
            referenceBalance[lastblockNumPending][chainId].c2 = 1;
        }
    }

    function validatePublicSignals(uint256 txIndex, uint8 k, TransferProof memory proof, EnygmaPointWithChainId memory balance, EnygmaPointWithChainId memory pk) internal pure {
        // Validate public key
        require(uint256(proof.public_signal[txIndex * 2]) == pk.c1 && uint256(proof.public_signal[txIndex * 2 + 1]) == pk.c2, 'Invalid public signal for pk');

        // Validate balance
        require(uint256(proof.public_signal[txIndex * 2 + (2 * k)]) == balance.c1 && uint256(proof.public_signal[txIndex * 2 + (2 * k + 1)]) == balance.c2, 'Invalid public signal for balance');
    }

    // Checks that all the balances add up to the total supply
    function checkTotalSumOfBalances(uint256 blockNumber) public view returns (bool) {
        uint256 x;
        uint256 y;

        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        uint256[] memory enygmaParticipants = participantStorage.getEnygmaAllParticipantsChainIds();

        for (uint256 i = 0; i < enygmaParticipants.length; i = i + 1) {
            uint256 chainId = enygmaParticipants[i];
            (uint256 xBalance, uint256 yBalance) = getBalanceByBlockNumber(chainId, blockNumber);
            (x, y) = CurveBabyJubJub.pointAdd(x, y, xBalance, yBalance);
        }

        //Adding dvp balance
        (uint256 xBalanceDvp, uint256 yBalanceDvp) = getBalanceByBlockNumber(dvpChainId, blockNumber);
        (x, y) = CurveBabyJubJub.pointAdd(x, y, xBalanceDvp, yBalanceDvp);

        require(totalSupplyX == x && totalSupplyY == y, 'Values dont match');
        return true;
    }

    function addTransferVerifier(address verifier, uint8 k) public onlyFactory returns (bool) {
        transferVerifiers[k] = verifier;

        emit VerifierRegistered(verifier, k);
        return true;
    }

    function getBalanceFinalised(uint256 chainId) public view returns (uint256 x, uint256 y) {
        if (referenceBalance[lastblockNum][chainId].c1 == 0 && referenceBalance[lastblockNum][chainId].c2 == 0) {
            return (0, 1);
        } else {
            return (referenceBalance[lastblockNum][chainId].c1, referenceBalance[lastblockNum][chainId].c2);
        }
    }

    function getBalancePending(uint256 chainId) public view returns (uint256 x, uint256 y) {
        if (referenceBalance[lastblockNumPending][chainId].c1 == 0 && referenceBalance[lastblockNumPending][chainId].c2 == 0) {
            return (0, 1);
        } else {
            return (referenceBalance[lastblockNumPending][chainId].c1, referenceBalance[lastblockNumPending][chainId].c2);
        }
    }

    function getBalanceByBlockNumber(uint256 chainId, uint256 blockNumber) public view returns (uint256 x, uint256 y) {
        if (referenceBalance[blockNumber][chainId].c1 == 0 && referenceBalance[blockNumber][chainId].c2 == 0) {
            return (0, 1);
        } else {
            return (referenceBalance[blockNumber][chainId].c1, referenceBalance[blockNumber][chainId].c2);
        }
    }

     function getPublicValuesByBlockNumber(uint256 blockNumber) public view returns (EnygmaPointWithChainId[] memory, EnygmaPublicKeyWithChainId[] memory) {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        uint256[] memory chainsRegisteredForEnygma = participantStorage.getEnygmaAllParticipantsChainIds();
        uint256 totalChainsRegistered = chainsRegisteredForEnygma.length;

        EnygmaPointWithChainId[] memory refBalances = new EnygmaPointWithChainId[](totalChainsRegistered);
        for (uint256 i = 0; i < totalChainsRegistered; i++) {
            uint256 chainId = chainsRegisteredForEnygma[i];
            (uint256 xBalance, uint256 yBalance) = getBalanceByBlockNumber(chainId, blockNumber);
            refBalances[i] = EnygmaPointWithChainId(xBalance, yBalance, chainId);
        }

        ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory allPaymentSpendKeys = participantStorage.getAllPaymentSpendPublicKeys();

        EnygmaPublicKeyWithChainId[] memory publicKeys = new EnygmaPublicKeyWithChainId[](totalChainsRegistered);
        for (uint256 i = 0; i < totalChainsRegistered; i++) {
            ParticipantStructs.PrivacyNodeSpendDataSafeReturn memory paymentSpendKey = allPaymentSpendKeys[i];

            publicKeys[i].publicKey = paymentSpendKey.paymentSpendPublicKey;
            publicKeys[i].chainId = paymentSpendKey.chainId;
        }
        return (refBalances, publicKeys);
    }

    function getPublicValuesFinalised() public view returns (EnygmaPointWithChainId[] memory, EnygmaPublicKeyWithChainId[] memory) {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        uint256[] memory chainsRegisteredForEnygma = participantStorage.getEnygmaAllParticipantsChainIds();
        uint256 totalChainsRegistered = chainsRegisteredForEnygma.length;

        EnygmaPointWithChainId[] memory refBalances = new EnygmaPointWithChainId[](totalChainsRegistered);
        for (uint256 i = 0; i < totalChainsRegistered; i++) {
            uint256 chainId = chainsRegisteredForEnygma[i];
            (uint256 xBalance, uint256 yBalance) = getBalanceFinalised(chainId);
            refBalances[i] = EnygmaPointWithChainId(xBalance, yBalance, chainId);
        }

        ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory allPaymentSpendKeys = participantStorage.getAllPaymentSpendPublicKeys();

        EnygmaPublicKeyWithChainId[] memory publicKeys = new EnygmaPublicKeyWithChainId[](totalChainsRegistered);
        for (uint256 i = 0; i < totalChainsRegistered; i++) {
            ParticipantStructs.PrivacyNodeSpendDataSafeReturn memory paymentSpendKey = allPaymentSpendKeys[i];

            publicKeys[i].publicKey = paymentSpendKey.paymentSpendPublicKey;
            publicKeys[i].chainId = paymentSpendKey.chainId;
        }
        return (refBalances, publicKeys);
    }

    function getPublicValuesPending() public view returns (EnygmaPointWithChainId[] memory, EnygmaPublicKeyWithChainId[] memory) {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        uint256[] memory chainsRegisteredForEnygma = participantStorage.getEnygmaAllParticipantsChainIds();
        uint256 totalChainsRegistered = chainsRegisteredForEnygma.length;

        EnygmaPointWithChainId[] memory refBalances = new EnygmaPointWithChainId[](totalChainsRegistered);
        for (uint256 i = 0; i < totalChainsRegistered; i++) {
            uint256 chainId = chainsRegisteredForEnygma[i];
            (uint256 xBalance, uint256 yBalance) = getBalancePending(chainId);
            refBalances[i] = EnygmaPointWithChainId(xBalance, yBalance, chainId);
        }

        ParticipantStructs.PrivacyNodeSpendDataSafeReturn[] memory allPaymentSpendKeys = participantStorage.getAllPaymentSpendPublicKeys();

        EnygmaPublicKeyWithChainId[] memory publicKeys = new EnygmaPublicKeyWithChainId[](totalChainsRegistered);
        for (uint256 i = 0; i < totalChainsRegistered; i++) {
            ParticipantStructs.PrivacyNodeSpendDataSafeReturn memory paymentSpendKey = allPaymentSpendKeys[i];

            publicKeys[i].publicKey = paymentSpendKey.paymentSpendPublicKey;
            publicKeys[i].chainId = paymentSpendKey.chainId;
        }
        return (refBalances, publicKeys);
    }

    function getPendingTransactions() public view returns (PendingTransaction[] memory) {
        return pendingTransactions;
    }

    function getPendingMintsAndBurns() public view returns (PendingMintOrBurn[] memory) {
        return pendingMintsAndBurns;
    }

    function getLastblockNumAtCurrentBlockNumber(uint256 currentBlockNumber) external view returns (uint256) {
        return lastblockNumAtCurrentBlockNumber[currentBlockNumber];
    }

    function Name() public view returns (string memory) {
        return name;
    }

    function Symbol() public view returns (string memory) {
        return symbol;
    }

    function getTotalRegisteredBanks() public view returns (uint256) {
        IParticipantStorage participantStorage = IParticipantStorage(participantStorageContract);
        uint256[] memory enygmaParticipants = participantStorage.getEnygmaAllParticipantsChainIds();
        uint256 totalParticipants = enygmaParticipants.length;
        return totalParticipants;
    }

    function getTotalSupply() public view returns (uint256) {
        return totalSupply;
    }

    function getTransferVerifierAddress(uint8 k) public view returns (address) {
        return transferVerifiers[k];
    }

    function getDvpIntegrationContractAddress() public view returns (address) {
        return dvpIntegrationContractAddress;
    }

    function convertToUint256Array18(uint256[] memory dynamicArray) internal pure returns (uint256[18] memory fixedArray) {
        require(dynamicArray.length == 18, 'Input array must have exactly 18 elements');
        for (uint256 i = 0; i < 18; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array26(uint256[] memory dynamicArray) internal pure returns (uint256[26] memory fixedArray) {
        require(dynamicArray.length == 26, 'Input array must have exactly 26 elements');
        for (uint256 i = 0; i < 26; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array34(uint256[] memory dynamicArray) internal pure returns (uint256[34] memory fixedArray) {
        require(dynamicArray.length == 34, 'Input array must have exactly 34 elements');
        for (uint256 i = 0; i < 34; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array42(uint256[] memory dynamicArray) internal pure returns (uint256[42] memory fixedArray) {
        require(dynamicArray.length == 42, 'Input array must have exactly 42 elements');
        for (uint256 i = 0; i < 42; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function convertToUint256Array50(uint256[] memory dynamicArray) internal pure returns (uint256[50] memory fixedArray) {
        require(dynamicArray.length == 50, 'Input array must have exactly 50 elements');
        for (uint256 i = 0; i < 50; i++) {
            fixedArray[i] = dynamicArray[i];
        }
        return fixedArray;
    }

    function findEnygmaPointIndex(EnygmaPointWithChainId[] memory points, uint256 chainId) internal pure returns (uint256) {
        for (uint256 i = 0; i < points.length; i++) {
            if (points[i].chainId == chainId) {
                return i;
            }
        }
        revert('Chain ID not found in points array');
    }

    // Derives a set of points in the BabyJubJub curve from an input with a Generator
    function derivePk(uint256 v) public view returns (uint256 x2, uint256 y2) {
        (x2, y2) = CurveBabyJubJub.derivePk(v);
    }

    // Derives a set of points in the BabyJubJub curve from an input with an H value
    function derivePkH(uint256 r) public view returns (uint256 x2, uint256 y2) {
        (x2, y2) = CurveBabyJubJub.derivePkH(r);
    }

    function negateOnCurve(uint256 x) public pure returns (uint256) {
        // Negation of x-coordinate on BabyJubJub curve is (Q - x) % Q
        return x == 0 ? 0 : CurveBabyJubJub.submod(0, x, CurveBabyJubJub.Q);
    }

    // Prints a pederson commitment
    function pedCom(uint256 v, uint256 r) public view returns (uint256, uint256) {
        (uint256 gX, uint256 gY) = derivePk(v);
        (uint256 hX, uint256 hY) = derivePkH(r);
        (uint256 pedComX, uint256 pedComY) = CurveBabyJubJub.pointAdd(gX, gY, hX, hY);
        return (pedComX, pedComY);
    }

    error EnygmaV1__OnlyDvpIntegrationAllowed();

    modifier onlyDvpIntegration() {
        if (msg.sender != dvpIntegrationContractAddress) revert EnygmaV1__OnlyDvpIntegrationAllowed();
        _;
    }

    function setDvpIntegrationContract(address _dvpIntegrationContractAddress) public onlyFactory {
        require(_dvpIntegrationContractAddress != address(0), 'Invalid DVP integration contract address');
        dvpIntegrationContractAddress = _dvpIntegrationContractAddress;
    }

    // Public wrapper functions for DVP integration

      function dvpFinalisePendingTransactions(uint256 currentBlockNumber) public onlyDvpIntegration {
        finalisePendingTransactions(currentBlockNumber);
    }

    function dvpAddPendingTransaction(
        TransferProof memory proof,
        TxType transactionType
    ) public onlyDvpIntegration {
        ExtractedProofData memory proofData = extractProofData(proof);
        addPendingTransaction(proofData, transactionType);
    }

    function dvpSendEvents(ExtractedProofData memory proofData, bytes[] memory encryptedMessages, bytes memory encryptedUpdate) public onlyDvpIntegration {
        sendEventsBatch(proofData, encryptedMessages);
        // Send mint and burn encrypted to Private Network Hub using teleport contract
        enygmaTeleport.enygmaDvpBalanceUpdated(encryptedUpdate);
    }

    function dvpSetLastblockNumPending(uint256 newValue) public onlyDvpIntegration {
        lastblockNumPending = newValue;
    }

    function dvpValidateTransferInputs(
        TransferProof memory proof
    ) public view onlyDvpIntegration {
        ExtractedProofData memory proofData = extractProofData(proof);
        validateTransferInputs(proofData);
    }
}

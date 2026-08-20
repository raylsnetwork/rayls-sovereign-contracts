pragma solidity ^0.8.20;

// SPDX-License-Identifier: Apache-2.0

interface SharedObjects {
    /**
     * @dev Parameters required for registering a token to the VEN
     */
    struct TokenRegistrationData {
        string name;
        string symbol;
        string uri;
        bytes totalSupply;
        uint256 issuerChainId;
        address pnRegistryAddress;
        bytes bytecode;
        bytes initializerParams;
        bool isFungible;
        ErcStandard ercStandard;
        bool isCustom;
        address tokenAddress;
    }

    struct ERC1155Supply {
        uint256 id;
        uint256 amount;
    }

    enum ErcStandard {
        Custom,
        ERC20,
        ERC721,
        ERC1155,
        Enygma,
        DvpERC721,
        DvpERC1155,
        // Test-only variants. Same registration/teleport semantics as their base standard, but
        // FACTORY-mode deploys resolve to the *Example seeded bytecode. Ordinals MUST stay aligned
        // with RaylsBridgeableERC and the relayer's types.ErcStandard — append only.
        ERC20Test,
        ERC721Test,
        ERC1155Test,
        EnygmaTest,
        DvpERC721Test,
        DvpERC1155Test
    }

    enum BalanceUpdateType {
        BURN,
        MINT
    }

    struct Dvp721ExtraData {
        string key;
        string value;
        bool isPublic;
    }

    struct Dvp1155ExtraData {
        string key;
        string value;
        bool isPublic;
    }

    struct DvpSwapCompletedParams {
        uint256 tokenId;
        uint256 destinationChainId;
        address destinationOwner;
        bytes32 sharedId;
    }

    enum DvpCommunicatiorStatus {
        NOSTATUS,
        Swap721ForEnygmaSent,
        Swap721ForEnygmaReceived,
        SwapEnygmaFor721Sent,
        SwapEnygmaFor721Received,
        Swap721ForEnygmaProcessing,
        SwapDoneReadyForWithdraw,
        Swap1155ForEnygmaSent,
        Swap1155ForEnygmaReceived,
        SwapEnygmaFor1155Sent,
        SwapEnygmaFor1155Received,
        Swap1155ForEnygmaProcessing,
        SwapError,
        SwapCancellationInitiated,
        SwapCancelled
    }


    struct CommunicatiorData {
        CommunicatiorDataHistory[] History;
        uint256 context;
    }

    struct CommunicatiorDataHistory {
        uint256 status;
        uint256 blockNumber;
        string message;
    }

    enum CommunicatiorContexts {
        Dvp
    }

    /**
     * @notice A single programmability step composed into a cross-chain transfer, carried typed
     *         from the sender through `PNHTransfer` and dispatched by `ProgrammabilityExecutorV1`.
     * @dev The target is addressed by EXACTLY ONE of `resourceId` (resolved via the receiver's
     *      endpoint) or `contractAddress` (used directly) — supplying both reverts
     *      `ProgramData__BothTargetsProvided`, supplying neither reverts
     *      `ProgramData__NoTargetProvided`. The executor gates `(target.codehash, selector)`
     *      and calls `target.call(selector ‖ args)`. For owner-attested selectors the executor
     *      appends the attested origin as a trusted 20-byte calldata tail (read by the target via
     *      `_getMsgSenderOnReceiveMethod`), so `args` encode ONLY the target's leading parameters —
     *      no origin slot.
     * @param resourceId Target contract's resource id (set this OR `contractAddress`).
     * @param contractAddress Target contract address (set this OR `resourceId`).
     * @param selector 4-byte selector of the function to invoke on the target.
     * @param args ABI-encoded arguments for the target's leading parameters (the attested
     *        `originSender`, when applicable, is appended by the executor as a trusted tail).
     */
    struct EnygmaProgramData {
        bytes32 resourceId;
        address contractAddress;
        bytes4 selector;
        bytes args;
    }

    /**
     * @dev Emits an event when sending a transfer from Private Hub
     * @param resourceId The resource ID of the Enygma token
     * @param value Array of values to transfer
     * @param toChainId Array of destination chain IDs
     * @param to Array of recipient addresses
     * @param from Sender address
     * @param referenceId Reference ID for the transfer
     */
    struct PNHTransfer {
        bytes32 resourceId;
        uint256[] value;
        uint256[] toChainId;
        address[] to;
        address from;
        bytes32 referenceId;
        // One array of program-data steps per recipient (parallel to `to`/`value`/`toChainId`).
        // For a plain transfer the sender stamps a single-element [mintStep] per recipient; composed
        // transfers carry [mintStep, userStep...]. Consumed on the receiver by
        // ProgrammabilityExecutor.executeProgramData.
        EnygmaProgramData[][] programData;
    }
}

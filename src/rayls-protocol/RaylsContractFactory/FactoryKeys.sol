// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title FactoryKeys
 * @notice Well-known registry keys for the bytecode templates the Rayls factories deploy.
 *
 * @dev These are the canonical `bytes32 => bytes` registry keys used by the contract
 *      factories and by callers that resolve a {RaylsBridgeableERC} template to its
 *      registry slot (e.g. ResourceManager FACTORY-mode dispatch). Holding them in one
 *      library lets both sides reference identical compile-time constants without an
 *      instance call or duplicated keccak literals.
 */
library FactoryKeys {
    bytes32 internal constant RAYLS_ERC20_KEY = keccak256("RAYLS_ERC20");
    bytes32 internal constant RAYLS_ERC721_KEY = keccak256("RAYLS_ERC721");
    bytes32 internal constant RAYLS_ERC1155_KEY = keccak256("RAYLS_ERC1155");
    bytes32 internal constant RAYLS_ENYGMA_KEY = keccak256("RAYLS_ENYGMA");
    bytes32 internal constant RAYLS_ERC721_DVP_KEY = keccak256("RAYLS_ERC721_DVP");
    bytes32 internal constant RAYLS_ERC1155_DVP_KEY = keccak256("RAYLS_ERC1155_DVP");
    bytes32 internal constant RAYLS_STABLECOIN_KEY = keccak256("RAYLS_STABLECOIN");

    // Test-only template keys. Same init shape as the matching base standard, but seeded with the
    // *Example runtime so FACTORY-mode deploys of the test variants resolve here. Selected only when
    // an ErcStandard.*Test / RaylsBridgeableERC.*TEST value flows through the registration/teleport
    // path; normal deploys keep the production keys above.
    bytes32 internal constant RAYLS_ERC20_TEST_KEY = keccak256("RAYLS_ERC20_TEST");
    bytes32 internal constant RAYLS_ERC721_TEST_KEY = keccak256("RAYLS_ERC721_TEST");
    bytes32 internal constant RAYLS_ERC1155_TEST_KEY = keccak256("RAYLS_ERC1155_TEST");
    bytes32 internal constant RAYLS_ENYGMA_TEST_KEY = keccak256("RAYLS_ENYGMA_TEST");
    bytes32 internal constant RAYLS_ERC721_DVP_TEST_KEY = keccak256("RAYLS_ERC721_DVP_TEST");
    bytes32 internal constant RAYLS_ERC1155_DVP_TEST_KEY = keccak256("RAYLS_ERC1155_DVP_TEST");
    bytes32 internal constant RAYLS_STABLECOIN_TEST_KEY = keccak256("RAYLS_STABLECOIN_TEST");
}

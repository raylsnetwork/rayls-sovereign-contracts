// Relay Authorization Management Tasks
// 
// These tasks provide interaction with the RelayAuthorizationRegistry contract
// for managing authorized relay addresses in the Rayls Node ecosystem.
//
// Available tasks:
// - add-authorized-relayers: Add multiple relay addresses to authorization
// - remove-authorized-relayer: Remove a single relay address from authorization  
// - list-authorized-relayers: List all authorized relay addresses and check specific addresses
//
// All tasks require the --pn parameter to identify the Privacy Node (A, B, C, D, etc.)
//
// Usage examples:
//
// Add multiple relayers:
// npx hardhat add-authorized-relayers \
//   --pn A \
//   --network privacy_node
//
// Remove a relayer:
// npx hardhat remove-authorized-relayer \
//   --relayer-address 0xabc... \
//   --pn A \
//   --network privacy_node
//
// List all relayers (private registry):
// npx hardhat list-authorized-relayers \
//   --pn A \
//   --network privacy_node
//
// List all relayers (public registry):
// npx hardhat list-authorized-relayers \
//   --pn A \
//   --registry-type public \
//   --network privacy_node
//
// Check specific address:
// npx hardhat list-authorized-relayers \
//   --pn A \
//   --check-address 0xabc... \
//   --network privacy_node

import './add-authorized-relayers';
import './add-authorized-relayers-pnh';
import './remove-authorized-relayer';
import './list-authorized-relayers';
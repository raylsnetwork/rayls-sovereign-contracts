# ML-KEM Key Generation

## Overview
The mlkemgen module provides utilities for generating ML-KEM (Module-Lattice-based Key Encapsulation Mechanism) key pairs used in the encryption system. This Go-based tool generates post-quantum cryptographic keys for secure communication and privacy operations.

## Available Tools

### Go Binary
The main tool is a compiled Go binary:
```bash
# Generate new ML-KEM key pair
./mlkemgen
```

### Go Source Code
The source code can be compiled and run:
```bash
# Compile the Go source
go build -o mlkemgen main.go

# Run the compiled binary
./mlkemgen
```

## Key Generation

### Default Generation
Generate a standard ML-KEM key pair:
```bash
./mlkemgen
```
This creates a new key pair with default parameters and saves it to `keypair.json`.

## Output Format

### Key Pair Structure
The generated key pair is saved in JSON format:
```json
{
  "raylsViewSecretKey": "base64_encoded_private_key",
  "raylsViewPublicKey": "base64_encoded_public_key",
}
```

### Key Components
- **Private Key (Decapsulation Key)**: Secret key for decapsulating shared secrets
- **Public Key (Encapsulation Key)**: Public key for encapsulating shared secrets

## Security Considerations

### Key Strength
- **ML-KEM-512**: NIST Security Level 1 (equivalent to AES-128)
- **ML-KEM-768**: NIST Security Level 3 (equivalent to AES-192)
- **ML-KEM-1024**: NIST Security Level 5 (equivalent to AES-256)

### Key Management
- **Secure Storage**: Store private keys securely
- **Key Rotation**: Regularly rotate keys
- **Access Control**: Limit access to private keys
- **Backup**: Secure backup of key pairs

## Integration

### Hardhat Tasks
The generated keys can be used with Hardhat tasks:
```bash
# Update ML-KEM keys in the system
npx hardhat utils:update-mlkem-keys --pn A --new-key "generated_public_key"
```

### System Configuration
ML-KEM keys are used for:
- **Key Encapsulation**: Securely encapsulating symmetric keys
- **Key Decapsulation**: Recovering symmetric keys from ciphertexts
- **Key Exchange**: Post-quantum secure key exchange protocols
- **Hybrid Encryption**: Combined with symmetric encryption for data protection

## Dependencies

### Go Requirements
- **Go Version**: 1.19 or higher
- **Modules**: Go modules enabled
- **Dependencies**: Standard library only

### Build Requirements
- **Compiler**: Go compiler (gccgo not supported)
- **Platform**: Cross-platform compilation supported
- **Architecture**: x86_64, ARM64, and others supported

## Important Notes
- ML-KEM provides post-quantum security against quantum computer attacks
- Generated keys are cryptographically secure
- Private (decapsulation) keys must be kept confidential
- Public (encapsulation) keys can be shared safely
- Always verify key integrity before use
- Backup keys securely for disaster recovery

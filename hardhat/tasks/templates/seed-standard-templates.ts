import { task } from 'hardhat/config';
import { getEnvVariableOrFlag } from '../../utils/getEnvOrFlag';

/**
 * Seeds the standard templates on the PNH `TemplateRegistryV1`.
 *
 * The template gate on each PN checks `(target.codehash, selector)`. Because every
 * standard token is deployed by `RNContractFactoryV1` via CREATE2 + InitCodeStub, the
 * deployed instance's runtime `extcodehash` equals `keccak256(bytecodes[KEY])` =
 * `RNContractFactoryV1.getBytecodeHash(KEY)`. We therefore read the canonical hash from a
 * PN's factory and seed it on the PNH registry, so one seeded `(hash, selector)` pair
 * covers every `RaylsEnygmaHandler` instance on every PN.
 *
 * Seeds, per token standard, the programmable cross-chain mint/burn entry points that a composed
 * Enygma `crossTransfer` may target on a token's own resourceId:
 *   - Enygma: `crossMintStandard` (the auto-built settlement mint blob of every transfer) plus the
 *     programmable userBlob entries `crossMint`/`crossBurn`.
 *   - ERC20 / ERC721 / ERC1155: the RELAYER-gated `crossMint`/`crossBurn` userBlob entries, gated
 *     against each standard's own canonical FACTORY bytecode hash.
 * Each standard's hash is read from the PN factory under its own key (ENYGMA/ERC20/ERC721/ERC1155),
 * so one seeded `(hash, selector)` pair covers every deployed instance of that standard on every PN.
 */
task('seed-standard-templates', 'Seed standard templates (Enygma + ERC20/721/1155 crossMint/crossBurn) on PNH TemplateRegistry')
  .addOptionalParam('rpcUrl', 'PNH JSON-RPC URL')
  .addOptionalParam('privateKey', 'Operator key (must hold PRIVATE_NETWORK_OPERATOR)')
  .addOptionalParam('registryAddress', 'PNH DeploymentProxyRegistry address')
  .addOptionalParam('pnRpcUrl', 'A PN JSON-RPC URL (to read the canonical bytecode hash)')
  .addOptionalParam('pnFactoryAddress', 'RNContractFactoryV1 address on that PN')
  .setAction(async (taskArgs, { ethers }) => {
    console.log('🌱 Seeding standard templates on PNH...');
    console.log('============================================================');

    const rpcUrl = getEnvVariableOrFlag('PNH RPC URL', 'PNH_RPC_URL', 'rpcUrl', '--rpc-url', taskArgs);
    const privateKey = getEnvVariableOrFlag('Private Key', 'PRIVATE_KEY_SYSTEM', 'privateKey', '--private-key', taskArgs);
    const registryAddress = getEnvVariableOrFlag('Registry Address', 'PNH_DEPLOYMENT_PROXY_REGISTRY', 'registryAddress', '--registry-address', taskArgs);
    const pnRpcUrl = getEnvVariableOrFlag('PN RPC URL', 'PRIVACY_NODE_RPC_URL', 'pnRpcUrl', '--pn-rpc-url', taskArgs);
    const pnFactoryAddress = getEnvVariableOrFlag('PN Factory Address', 'PRIVACY_NODE_CONTRACT_FACTORY', 'pnFactoryAddress', '--pn-factory-address', taskArgs);

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const signer = new ethers.Wallet(privateKey).connect(provider);
    console.log(`📍 Operator: ${signer.address}`);

    // Resolve the PNH TemplateRegistry from the deployment registry.
    const registry = await ethers.getContractAt('DeploymentProxyRegistryV1', registryAddress, signer);
    const templateRegistryAddress = await registry.getContract('TemplateRegistry');
    console.log(`📍 TemplateRegistryV1: ${templateRegistryAddress}`);
    const templateRegistry = await ethers.getContractAt('TemplateRegistryV1', templateRegistryAddress, signer);

    // Read the canonical bytecode hash for each standard from a PN factory. A throwaway wallet
    // (no funds needed — these are view calls) connects to the PN provider so getContractAt has a
    // runner.
    const pnProvider = new ethers.JsonRpcProvider(pnRpcUrl);
    const pnReader = ethers.Wallet.createRandom().connect(pnProvider);
    const factory = await ethers.getContractAt('RNContractFactoryV1', pnFactoryAddress, pnReader);

    // Per-standard signatures to seed. Each is gated against that standard's OWN canonical FACTORY
    // bytecode hash, so a userBlob targeting a deployed instance of that standard clears the gate.
    const enygmaSignatures = [
      // Auto-built settlement mint blob stamped by RaylsEnygmaHandler._buildProgramData.
      // The ProgrammabilityExecutor dispatches this selector WITHOUT the origin tail
      // (settlement-mint amount is conservation-checked, not owner-gated).
      'crossMintStandard(address,uint256,bytes32)',
      // Programmable userBlob entries on the Enygma token's own resourceId. Signatures carry
      // ONLY the target's leading parameters — NO originSender slot. The executor appends the
      // attested origin as a trusted 20-byte calldata tail, which the token reads via
      // `_getMsgSenderOnReceiveMethod()`; its in-body
      // `hasContractScopedRole(TOKEN_OWNER, origin, address(this))` check rejects non-owner
      // attempts. Selectors therefore hash on the signature WITHOUT originSender.
      'crossMint(address,uint256)',
      'crossBurn(address,uint256)',
    ];

    const standards: { label: string; keyFn: 'RAYLS_ENYGMA_KEY' | 'RAYLS_ENYGMA_TEST_KEY' | 'RAYLS_ERC20_KEY' | 'RAYLS_ERC721_KEY' | 'RAYLS_ERC1155_KEY'; signatures: string[] }[] = [
      {
        label: 'Enygma',
        keyFn: 'RAYLS_ENYGMA_KEY',
        signatures: enygmaSignatures,
      },
      {
        label: 'EnygmaTest',
        keyFn: 'RAYLS_ENYGMA_TEST_KEY',
        signatures: enygmaSignatures,
      },
      {
        label: 'ERC20',
        keyFn: 'RAYLS_ERC20_KEY',
        signatures: ['crossMint(address,uint256)', 'crossBurn(address,uint256)'],
      },
      {
        label: 'ERC721',
        keyFn: 'RAYLS_ERC721_KEY',
        // Origin is appended as a trusted calldata tail (not a signature param), so selectors hash
        // on the leading params only. crossBurn on ERC721 takes just (uint256 id).
        signatures: ['crossMint(address,uint256)', 'crossBurn(uint256)'],
      },
      {
        label: 'ERC1155',
        keyFn: 'RAYLS_ERC1155_KEY',
        signatures: [
          'crossMint(address,uint256,uint256,bytes)',
          'crossBurn(address,uint256,uint256)',
        ],
      },
    ];

    // A deploy that ran before this step (or a chain reset mid-run) can leave the operator's
    // computed nonce behind the chain's, surfacing as NONCE_EXPIRED / "Nonce too low" on send.
    // Re-fetch the pending nonce from the chain and resubmit a few times before giving up, so a
    // transient desync doesn't fail the whole deploy. The send is the only retried op; tx.wait()
    // stays outside so a mined-then-reorged tx isn't silently re-sent.
    const isNonceError = (err: any): boolean =>
      err?.code === 'NONCE_EXPIRED' ||
      err?.info?.error?.code === -32001 ||
      /nonce too low|nonce has already been used/i.test(err?.shortMessage ?? err?.message ?? '');

    const sendWithNonceRetry = async (send: (overrides: { nonce?: number }) => Promise<any>): Promise<any> => {
      const maxAttempts = 5;
      for (let attempt = 1; ; attempt++) {
        // After the first attempt, pin an explicitly re-fetched nonce so ethers can't reuse a
        // stale cached value.
        const overrides = attempt === 1 ? {} : { nonce: await provider.getTransactionCount(signer.address, 'pending') };
        try {
          return await send(overrides);
        } catch (err: any) {
          if (!isNonceError(err) || attempt >= maxAttempts) throw err;
          console.log(`  ⚠️  nonce desync (attempt ${attempt}/${maxAttempts}); re-fetching nonce and retrying...`);
        }
      }
    };

    for (const standard of standards) {
      const factoryKey: string = await factory[standard.keyFn]();
      const bytecodeHash: string = await factory.getBytecodeHash(factoryKey);
      console.log(`📍 ${standard.label} ${standard.keyFn}=${factoryKey} bytecodeHash=${bytecodeHash}`);

      if (bytecodeHash === ethers.ZeroHash) {
        throw new Error(`${standard.label} bytecode is not registered on the PN factory (getBytecodeHash returned 0). Run the PN deploy with setBytecode(${standard.keyFn}, ...) first.`);
      }

      for (const signature of standard.signatures) {
        const selector = ethers.dataSlice(ethers.keccak256(ethers.toUtf8Bytes(signature)), 0, 4);
        const key: string = await templateRegistry.getKey(bytecodeHash, selector);

        const existing = await templateRegistry.getTemplate(key);
        if (existing.approved) {
          console.log(`  ⏭️  already seeded: ${standard.label} ${signature} (key ${key})`);
          continue;
        }

        console.log(`  🌱 seedStandardTemplate(${standard.label} "${signature}") selector=${selector}`);
        const tx = await sendWithNonceRetry((overrides) => templateRegistry.seedStandardTemplate(bytecodeHash, signature, overrides));
        await tx.wait();
        console.log(`  ✓ seeded (key ${key}, tx ${tx.hash})`);
      }
    }

    console.log('============================================================');
    console.log('✅ Standard templates seeded.');
  });

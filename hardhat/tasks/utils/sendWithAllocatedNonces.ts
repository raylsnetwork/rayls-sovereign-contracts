/**
 * Sending a batch of transactions under explicitly allocated nonces.
 *
 * Several tasks send N transactions at once by reading the account's next nonce
 * and handing out `nonce`, `nonce + 1`, … The read is the weak point: a nonce
 * obtained while any of this account's transactions is still in flight can be
 * too low, and the chain then rejects one transaction per in-flight
 * predecessor.
 *
 * `eth_getTransactionCount(addr, 'pending')` is supposed to account for
 * broadcast-but-unmined transactions. On the Axyl node it does not — it returns
 * the mined count, measured against a running privacy node:
 *
 *     before        {latest:153, pending:153}
 *     in-flight tx nonce 153      <- broadcast, not yet mined
 *     while pending {latest:153, pending:153}   <- invisible
 *     after mined   {latest:154, pending:154}
 *
 * Whether that is fatal depends on sub-block timing. These chains run with a
 * zero base fee, so a second transaction on the same nonce *replaces* the
 * pending one and nothing fails; but if the predecessor mines first, the
 * replacement is rejected as `nonce too low`. That is why the failure is
 * intermittent rather than constant.
 */

/**
 * Whether a rejection means the nonce we picked is not ours to use.
 *
 * The chain reports this two ways depending on what the predecessor is doing:
 * `nonce too low` once it has been mined, and `replacement transaction
 * underpriced` while it is still sitting in the pool. Both mean the same thing
 * here — allocate again, higher.
 *
 * Matched against the whole serialized error because the RPC message arrives
 * nested under `info.error.message`, and ethers sometimes wraps it in a
 * `could not coalesce error` of its own.
 */
export function isNonceCollision(error: any): boolean {
  const haystack = [
    error?.code,
    error?.message,
    error?.shortMessage,
    error?.info?.error?.message,
    (() => {
      try {
        return JSON.stringify(error?.info ?? {});
      } catch {
        return '';
      }
    })(),
  ]
    .join(' ')
    .toLowerCase();

  return (
    haystack.includes('nonce_expired') ||
    haystack.includes('nonce too low') ||
    haystack.includes('nonce has already been used') ||
    haystack.includes('replacement transaction underpriced')
  );
}

/**
 * Send `count` transactions in parallel under allocated nonces, resending the
 * ones the chain rejects as already taken.
 *
 * `send` receives the nonce to use and the index of the transaction, and
 * returns the transaction response. `describe` names an index for the error
 * message raised when a nonce cannot be secured.
 *
 * The accepted transactions of an attempt are mined before the next nonce is
 * read: re-reading while they are in flight would repeat the mistake this
 * exists to correct. Anything that is not a nonce collision is a real failure
 * and is raised immediately rather than retried.
 */
export async function sendWithAllocatedNonces(
  readNonce: () => Promise<number>,
  count: number,
  send: (nonce: number, index: number) => Promise<any>,
  describe: (index: number) => string,
  maxAttempts = 3
): Promise<any[]> {
  const receipts: any[] = new Array(count);
  let outstanding = Array.from({ length: count }, (_, i) => i);

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    let nonce = await readNonce();
    if (attempt > 1) {
      console.log(
        `   ↻ resending ${outstanding.length} transaction(s) from nonce ${nonce} (attempt ${attempt}/${maxAttempts})`
      );
    }

    const sent = await Promise.allSettled(outstanding.map(i => send(nonce++, i)));

    const collided: number[] = [];
    const accepted: { index: number; tx: any }[] = [];
    sent.forEach((result, k) => {
      const index = outstanding[k];
      if (result.status === 'fulfilled') accepted.push({ index, tx: result.value });
      else if (isNonceCollision(result.reason)) collided.push(index);
      else throw result.reason;
    });

    const mined = await Promise.allSettled(accepted.map(a => a.tx.wait()));
    mined.forEach((result, k) => {
      const { index } = accepted[k];
      if (result.status === 'fulfilled') receipts[index] = result.value;
      else if (isNonceCollision(result.reason)) collided.push(index);
      else throw result.reason;
    });

    if (collided.length === 0) return receipts;
    outstanding = collided;
  }

  throw new Error(
    `nonce collision persisted after ${maxAttempts} attempts for: ${outstanding.map(describe).join(', ')}`
  );
}

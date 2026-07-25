# eth

Talking to EVM chains from Erlang: JSON-RPC, EIP-1559 transaction signing and
an ABI codec. Replaces the `egw` HTTP service — private keys stay inside the
BEAM and every call goes straight to the node.

Depends on [keccak](https://github.com/ates/keccak) and
[secp256k1](https://github.com/ates/secp256k1) (a small rustler NIF) for the
two primitives that cannot be done in pure Erlang.

## Reading

The endpoint is always an explicit argument. Which node a call goes to depends
on chain, credentials and failover — decisions the caller owns, not this
library.

```erlang
{ok, 8453}       = eth_rpc:chain_id(Url).
{ok, Height}     = eth_rpc:block_number(Url).
{ok, Finalized}  = eth_rpc:block_number(Url, finalized).
{ok, Wei}        = eth_rpc:balance(Url, <<"0x…">>).
{ok, Block}      = eth_rpc:block_by_number(Url, 21_000_000, true).
{ok, Receipt}    = eth_rpc:transaction_receipt(Url, TxHash).
{ok, Logs}       = eth_rpc:logs(Url, #{address => Token,
                                       topics => [eth_abi:transfer_topic()],
                                       fromBlock => From, toBlock => To}).
```

`eth_rpc:call/3` is there for anything not wrapped.

Read-only contract calls go through `eth/3`:

```erlang
{ok, [Balance]} = eth:call(Url, Token,
                           {<<"balanceOf(address)">>, [Address], [<<"uint256">>]}).
```

## Sending

```erlang
{ok, TxHash} = eth:send(Url, #{
    private_key => PrivateKey,       %% 32 bytes or hex, e.g. straight from Vault
    to          => <<"0x…">>,
    value       => Wei,
    data        => eth_abi:encode_call(<<"transfer(address,uint256)">>, [To, Amount])
}).

{ok, Receipt} = eth:wait_receipt(Url, TxHash).
```

Or both at once, which is the form that keeps the nonce invariant below true:

```erlang
{ok, Receipt} = eth:send_and_wait(Url, Request).
```

Chain id, nonce, fees and gas are read from the chain when not supplied.
Gas gets a 20% buffer over the estimate; `max_fee_per_gas` defaults to
`base_fee * 2 + priority_fee`, which survives about six consecutive full
blocks. Any of them can be pinned explicitly.

A receipt with `status = 0` comes back as `{error, {reverted, Receipt}}`: the
transaction was mined but reverted, and that belongs on the failure path.

### Nonce ownership

`eth:send/2` reads the nonce from the chain on every call and keeps no state.
That is correct while **one process signs for a given address at a time**, and
waits for the previous transaction to be mined before sending the next.

Two concurrent senders on one address do not lose funds — the second is
rejected by the node with "nonce too low" rather than replacing the first. But
it does fail, so serialise per address, with one owner per address across the
cluster. Treat `nonce too low` and `replacement transaction underpriced` as
retryable.

### Transaction types

EIP-1559 (type `0x02`) only. Legacy and EIP-2930 transactions are not
supported: every chain in use is post-London, and carrying two signing schemes
doubles the surface where a chain id or a `v` value can be got wrong. In a
type `0x02` transaction the recovery id is used verbatim as `yParity` — the
EIP-155 chain id folding does not apply, since the chain id is a signed field.

## ABI

Static types (`uintN`, `intN`, `address`, `bool`, `bytesN`), the dynamic types
(`bytes`, `string`) and one-dimensional arrays of static types. Tuples, nested
arrays and fixed-size arrays raise `{unsupported_type, T}`.

```erlang
Calldata = eth_abi:encode_call(<<"sweepMany(bytes32[],address)">>, [Salts, Token]).
[Amount] = eth_abi:decode([<<"uint256">>], Data).
{ok, #{from := From, to := To, amount := Amount}} = eth_abi:decode_transfer_event(Log).
```

`decode_transfer_event/1` takes a log with either binary or atom keys and
returns `{error, _}` rather than raising on the malformed Transfer events some
tokens emit.

## Subscriptions

`eth_sub` holds one `eth_subscribe` subscription over a WebSocket and
reconnects on its own. Transport is hackney's WebSocket client, so no second
HTTP client is needed — and none of gun's QUIC build requirements.

```erlang
{ok, Sub} = eth_sub:logs(<<"wss://base-rpc.example/">>,
                         #{address => Token, topics => [eth_abi:transfer_topic()]}).
{ok, Sub} = eth_sub:new_heads(Url).
```

Events arrive as messages, so the owner stays an ordinary gen_server and
decides for itself what is blocking work:

```erlang
{eth_sub, Sub, {subscribed, SubscriptionId}}
{eth_sub, Sub, {event, Result}}
{eth_sub, Sub, {down, Reason}}
```

Options: `owner` (defaults to the caller), `reconnect_delay`,
`max_reconnect_delay`, `connect_timeout`, `ssl_options`, `headers`. Backoff is
exponential and resets when a subscription is actually established, not merely
when the socket connects.

### Closing the gap

A subscription only reports what happens while it is up, so every reconnect
leaves a hole between the last event received and the first one after
resubscribing.

`{subscribed, _}` is sent on the initial connection **and on every reconnect**
precisely so the owner can close that hole by backfilling over
`eth_rpc:logs/2`. It is not an informational message — treating it as one
loses events.

## OP Stack fees (Base, Optimism)

A transaction on an OP Stack chain costs L2 execution gas *plus* an L1 data
fee for publishing it to Ethereum. The L1 part is charged to the sender on top
of `gas * gas_price`, is not bounded by the gas limit, and is invisible to a
`gas * max_fee_per_gas + value` balance check.

Nothing is needed to *send* — the chain computes and deducts it. It matters
when deciding whether a funding wallet has enough balance:

```erlang
#{raw := Raw} = eth_tx:sign(Tx, PrivateKey),
{ok, L1Fee}   = eth_op:l1_fee(Url, Raw).
```

The fee depends on the compressed size of the serialised transaction, so it
can only be determined after signing. `eth_op:l1_gas_used/2` and
`eth_op:l1_base_fee/1` read the other `GasPriceOracle` values.

After the fact the exact amount is already on the receipt, no call needed:

```erlang
{ok, Charged} = eth_op:receipt_l1_fee(Receipt).
```

## Accounts

```erlang
Address = eth_account:address(PrivateKey).       %% EIP-55 checksummed
true    = eth_account:is_address(Address).
Bytes   = eth_account:bytes(Address).            %% raw 20 bytes
```

Private keys and addresses are accepted as raw bytes or as hex, prefixed or
not, in any casing.

## Build

```
rebar3 compile
rebar3 eunit
rebar3 dialyzer
```

Coverage is on reference vectors: RLP from the spec, EIP-55 addresses, known
private key / address pairs, the ERC-20 selectors, and a hand-derived
EIP-1559 payload. The signing test checks that the recovery id embedded as
`yParity` actually recovers the signer — the one thing a sign/verify round
trip cannot catch.

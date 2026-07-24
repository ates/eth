-module(eth_tx).

%% EIP-1559 (EIP-2718 type 0x02) transactions.
%%
%% Legacy and EIP-2930 transactions are intentionally not supported: every
%% chain we talk to is post-London, and carrying two signing schemes doubles
%% the surface where a chain id or a v value can be got wrong.
%%
%% Payload layout (EIP-1559):
%%
%%   unsigned = 0x02 || rlp([chain_id, nonce, max_priority_fee_per_gas,
%%                           max_fee_per_gas, gas, to, value, data,
%%                           access_list])
%%   sig_hash = keccak(unsigned)
%%   signed   = 0x02 || rlp(fields ++ [y_parity, r, s])
%%   tx_hash  = keccak(signed)
%%
%% Note that y_parity is the recovery id verbatim (0 or 1) — the EIP-155
%% chain id folding that legacy transactions need does not apply here, since
%% the chain id is already a signed field.

-export([sign/2]).
-export([unsigned/1]).
-export([sig_hash/1]).

-define(TX_TYPE, 2).

-type tx() :: #{
    chain_id := non_neg_integer(),
    nonce := non_neg_integer(),
    max_priority_fee_per_gas := non_neg_integer(),
    max_fee_per_gas := non_neg_integer(),
    gas := non_neg_integer(),
    to => binary() | undefined,
    value => non_neg_integer(),
    data => binary(),
    access_list => [{binary(), [binary()]}]
}.
-export_type([tx/0]).

%% @doc Sign a transaction, returning the raw payload to hand to
%% eth_sendRawTransaction along with the hash it will be known by.
-spec sign(tx(), binary()) -> #{raw := binary(), hash := binary()}.
sign(Tx, PrivateKey) ->
    Fields = fields(Tx),
    <<R:256, S:256, YParity:8>> =
        secp256k1:sign(keccak:hash_256(payload(Fields)), eth_account:private_key(PrivateKey)),
    Signed = payload(Fields ++ [YParity, R, S]),
    #{
        raw  => eth_hex:encode_data(Signed),
        hash => eth_hex:encode_data(keccak:hash_256(Signed))
    }.

%% @doc The unsigned payload, mostly useful for tests and debugging.
-spec unsigned(tx()) -> binary().
unsigned(Tx) -> payload(fields(Tx)).

%% @doc The digest that gets signed.
-spec sig_hash(tx()) -> <<_:256>>.
sig_hash(Tx) -> keccak:hash_256(unsigned(Tx)).

payload(Fields) ->
    <<?TX_TYPE, (eth_rlp:encode(Fields))/binary>>.

fields(Tx) ->
    [
        maps:get(chain_id, Tx),
        maps:get(nonce, Tx),
        maps:get(max_priority_fee_per_gas, Tx),
        maps:get(max_fee_per_gas, Tx),
        maps:get(gas, Tx),
        recipient(maps:get(to, Tx, undefined)),
        maps:get(value, Tx, 0),
        calldata(maps:get(data, Tx, <<>>)),
        access_list(maps:get(access_list, Tx, []))
    ].

%% An empty "to" is contract creation.
recipient(undefined) -> <<>>;
recipient(<<>>) -> <<>>;
recipient(To) -> eth_account:bytes(To).

%% Calldata is accepted either as a "0x" string (what eth_abi:encode_call/2
%% produces, and what a node would hand back) or as raw bytes.
calldata(<<"0x", _/binary>> = Data) -> eth_hex:decode_data(Data);
calldata(Data) when is_binary(Data) -> Data.

access_list(List) ->
    [[eth_account:bytes(Address), [eth_hex:decode_data(Key, 32) || Key <- Keys]]
     || {Address, Keys} <- List].

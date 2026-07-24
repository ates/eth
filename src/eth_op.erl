-module(eth_op).

%% OP Stack (Base, Optimism, …) specific fees.
%%
%% On an OP Stack chain the cost of a transaction has two parts: the L2
%% execution gas, which eth_estimateGas reports and gas_limit bounds, and an
%% L1 data fee for publishing the transaction to Ethereum. The L1 fee is
%% charged to the sender on top of gas * gas_price and is not covered by the
%% gas limit, so it is invisible to a "gas * max_fee_per_gas + value" balance
%% check.
%%
%% Nothing here is needed to send a transaction — the fee is computed and
%% deducted by the chain. It matters when deciding whether a funding wallet
%% has enough balance, and when accounting for what a transaction actually
%% cost.
%%
%% The GasPriceOracle is a predeploy at the same address on every OP Stack
%% chain.

-export([l1_fee/2]).
-export([l1_fee/3]).
-export([l1_gas_used/2]).
-export([l1_base_fee/1]).
-export([receipt_l1_fee/1]).
-export([gas_price_oracle/0]).

-define(GAS_PRICE_ORACLE, <<"0x420000000000000000000000000000000000000F">>).

-spec gas_price_oracle() -> binary().
gas_price_oracle() -> ?GAS_PRICE_ORACLE.

%% @doc L1 data fee, in wei, for a signed transaction.
%%
%% Takes the raw payload from eth_tx:sign/2 — the fee depends on the
%% compressed size of the serialised transaction, so it can only be
%% determined after signing:
%%
%% ```
%% #{raw := Raw} = eth_tx:sign(Tx, PrivateKey),
%% {ok, L1Fee} = eth_op:l1_fee(Url, Raw).
%% '''
-spec l1_fee(eth_rpc:endpoint(), binary()) -> {ok, non_neg_integer()} | {error, term()}.
l1_fee(Url, Raw) ->
    l1_fee(Url, Raw, ?GAS_PRICE_ORACLE).

-spec l1_fee(eth_rpc:endpoint(), binary(), binary()) ->
    {ok, non_neg_integer()} | {error, term()}.
l1_fee(Url, Raw, Oracle) ->
    oracle_call(Url, Oracle, <<"getL1Fee(bytes)">>, [Raw]).

%% @doc L1 gas the transaction is charged for. Informational: it is not a
%% limit and cannot be set on the transaction.
-spec l1_gas_used(eth_rpc:endpoint(), binary()) -> {ok, non_neg_integer()} | {error, term()}.
l1_gas_used(Url, Raw) ->
    oracle_call(Url, ?GAS_PRICE_ORACLE, <<"getL1GasUsed(bytes)">>, [Raw]).

%% @doc Current L1 base fee the oracle is pricing against.
-spec l1_base_fee(eth_rpc:endpoint()) -> {ok, non_neg_integer()} | {error, term()}.
l1_base_fee(Url) ->
    oracle_call(Url, ?GAS_PRICE_ORACLE, <<"l1BaseFee()">>, []).

%% @doc L1 fee actually charged, read from a receipt. OP Stack receipts carry
%% it directly, so this needs no extra call and is exact rather than an
%% estimate. Returns `{error, not_op_stack}' on a chain without the field.
-spec receipt_l1_fee(map()) -> {ok, non_neg_integer()} | {error, term()}.
receipt_l1_fee(Receipt) ->
    case maps:find(<<"l1Fee">>, Receipt) of
        {ok, null}  -> {error, not_op_stack};
        {ok, Fee}   -> {ok, eth_hex:decode_quantity(Fee)};
        error       -> {error, not_op_stack}
    end.

oracle_call(Url, Oracle, Signature, Args) ->
    case eth:call(Url, Oracle, {Signature, Args, [<<"uint256">>]}) of
        {ok, [Value]} -> {ok, Value};
        Error         -> Error
    end.

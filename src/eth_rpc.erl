-module(eth_rpc).

%% JSON-RPC transport over HTTP.
%%
%% The endpoint is always an explicit argument rather than application
%% config: which node a call goes to is a decision for the caller, who knows
%% about chains, credentials and failover. That also keeps this library
%% usable from more than one service without a shared config schema.
%%
%% Every function returns decoded JSON as-is; interpreting it is the caller's
%% job, except where a typed accessor is obviously more useful (block_number,
%% base_fee).

-export([call/3]).
-export([call/4]).

-export([chain_id/1]).
-export([block_number/1]).
-export([block_number/2]).
-export([block_by_number/3]).
-export([base_fee/2]).
-export([balance/2]).
-export([balance/3]).
-export([transaction_count/3]).
-export([transaction_receipt/2]).
-export([transaction_by_hash/2]).
-export([logs/2]).
-export([eth_call/3]).
-export([estimate_gas/2]).
-export([max_priority_fee_per_gas/1]).
-export([send_raw_transaction/2]).

-define(TIMEOUT, timer:seconds(30)).

-type endpoint() :: binary() | string().
-type tag() :: latest | pending | earliest | safe | finalized | non_neg_integer().
-type result() :: {ok, term()} | {error, term()}.
-export_type([endpoint/0, tag/0]).

%%%===================================================================
%%% Methods
%%%===================================================================

-spec chain_id(endpoint()) -> {ok, non_neg_integer()} | {error, term()}.
chain_id(Url) ->
    quantity(call(Url, eth_chainId, [])).

%% @doc Height of the latest block.
-spec block_number(endpoint()) -> {ok, non_neg_integer()} | {error, term()}.
block_number(Url) ->
    quantity(call(Url, eth_blockNumber, [])).

%% @doc Height of the block behind a tag, e.g. `finalized'. Unlike
%% eth_blockNumber this also tells you whether the tag exists at all, which
%% not every chain supports.
-spec block_number(endpoint(), tag()) -> {ok, non_neg_integer()} | {error, term()}.
block_number(Url, Tag) ->
    case block_by_number(Url, Tag, false) of
        {ok, null}                       -> {error, {no_block, Tag}};
        {ok, #{<<"number">> := Number}}  -> {ok, eth_hex:decode_quantity(Number)};
        Error                            -> Error
    end.

-spec block_by_number(endpoint(), tag(), boolean()) -> result().
block_by_number(Url, Tag, WithTransactions) ->
    call(Url, eth_getBlockByNumber, [tag(Tag), WithTransactions]).

-spec base_fee(endpoint(), tag()) -> {ok, non_neg_integer()} | {error, term()}.
base_fee(Url, Tag) ->
    case block_by_number(Url, Tag, false) of
        {ok, #{<<"baseFeePerGas">> := Fee}} -> {ok, eth_hex:decode_quantity(Fee)};
        {ok, _Block}                        -> {error, not_eip1559};
        Error                               -> Error
    end.

-spec balance(endpoint(), binary()) -> {ok, non_neg_integer()} | {error, term()}.
balance(Url, Address) ->
    balance(Url, Address, latest).

-spec balance(endpoint(), binary(), tag()) -> {ok, non_neg_integer()} | {error, term()}.
balance(Url, Address, Tag) ->
    quantity(call(Url, eth_getBalance, [address(Address), tag(Tag)])).

%% @doc Number of transactions sent from an address, i.e. the next nonce.
%%
%% Use `latest' when the previous transaction from this address is known to
%% be mined; `pending' is only meaningful against a single node and is
%% unreliable behind a load balanced provider.
-spec transaction_count(endpoint(), binary(), tag()) ->
    {ok, non_neg_integer()} | {error, term()}.
transaction_count(Url, Address, Tag) ->
    quantity(call(Url, eth_getTransactionCount, [address(Address), tag(Tag)])).

-spec transaction_receipt(endpoint(), binary()) -> result().
transaction_receipt(Url, TxHash) ->
    call(Url, eth_getTransactionReceipt, [TxHash]).

-spec transaction_by_hash(endpoint(), binary()) -> result().
transaction_by_hash(Url, TxHash) ->
    call(Url, eth_getTransactionByHash, [TxHash]).

%% @doc Filter keys are passed through, with `fromBlock'/`toBlock' accepting
%% integers or tags.
-spec logs(endpoint(), map()) -> result().
logs(Url, Filter) ->
    call(Url, eth_getLogs, [maps:map(fun filter_value/2, Filter)]).

-spec eth_call(endpoint(), map(), tag()) -> result().
eth_call(Url, Tx, Tag) ->
    call(Url, eth_call, [rpc_tx(Tx), tag(Tag)]).

-spec estimate_gas(endpoint(), map()) -> {ok, non_neg_integer()} | {error, term()}.
estimate_gas(Url, Tx) ->
    quantity(call(Url, eth_estimateGas, [rpc_tx(Tx)])).

-spec max_priority_fee_per_gas(endpoint()) -> {ok, non_neg_integer()} | {error, term()}.
max_priority_fee_per_gas(Url) ->
    quantity(call(Url, eth_maxPriorityFeePerGas, [])).

-spec send_raw_transaction(endpoint(), binary()) -> {ok, binary()} | {error, term()}.
send_raw_transaction(Url, Raw) ->
    call(Url, eth_sendRawTransaction, [Raw]).

%%%===================================================================
%%% Transport
%%%===================================================================

-spec call(endpoint(), atom(), list()) -> result().
call(Url, Method, Params) ->
    call(Url, Method, Params, #{}).

-spec call(endpoint(), atom(), list(), map()) -> result().
call(Url, Method, Params, Opts) ->
    Body = json:encode(#{
        jsonrpc => <<"2.0">>,
        id      => 1,
        method  => atom_to_binary(Method),
        params  => Params
    }),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    HackneyOpts = [
        {with_body, true},
        {recv_timeout, maps:get(timeout, Opts, ?TIMEOUT)}
        | maps:get(hackney_opts, Opts, [])
    ],
    case hackney:post(Url, Headers, Body, HackneyOpts) of
        {ok, 200, _Headers, Response} ->
            decode(Response);
        {ok, Code, _Headers, Response} ->
            {error, {http, Code, Response}};
        {error, Reason} ->
            {error, Reason}
    end.

decode(Response) ->
    try json:decode(Response) of
        #{<<"result">> := Result} -> {ok, Result};
        #{<<"error">> := Error}   -> {error, rpc_error(Error)};
        Other                     -> {error, {bad_response, Other}}
    catch
        _:_ -> {error, {bad_json, Response}}
    end.

%% Node error messages are far more useful than their codes, so keep both but
%% surface the message.
rpc_error(#{<<"message">> := Message} = Error) ->
    {rpc, maps:get(<<"code">>, Error, undefined), Message};
rpc_error(Error) ->
    {rpc, Error}.

%%%===================================================================
%%% Encoding helpers
%%%===================================================================

quantity({ok, Value}) when is_binary(Value) -> {ok, eth_hex:decode_quantity(Value)};
quantity({ok, Value}) -> {error, {bad_quantity, Value}};
quantity(Error) -> Error.

tag(N) when is_integer(N) -> eth_hex:encode_quantity(N);
tag(Tag) when is_atom(Tag) -> atom_to_binary(Tag);
tag(Tag) when is_binary(Tag) -> Tag.

address(Address) -> eth_account:checksum(Address).

filter_value(Key, Value) when Key =:= fromBlock; Key =:= toBlock;
                              Key =:= <<"fromBlock">>; Key =:= <<"toBlock">> ->
    tag(Value);
filter_value(_Key, Value) ->
    Value.

%% Transaction objects for eth_call/eth_estimateGas take QUANTITY hex, not
%% integers — passing a plain integer is silently rejected by some nodes and
%% loudly by others.
rpc_tx(Tx) ->
    maps:map(
        fun
            (Key, Value) when Key =:= data orelse Key =:= <<"data">>, is_binary(Value) ->
                hex_data(Value);
            (Key, Value) when is_integer(Value),
                              Key =:= value orelse Key =:= gas orelse
                              Key =:= gasPrice orelse Key =:= nonce orelse
                              Key =:= maxFeePerGas orelse Key =:= maxPriorityFeePerGas ->
                eth_hex:encode_quantity(Value);
            (_Key, Value) ->
                Value
        end,
        Tx
    ).

hex_data(<<"0x", _/binary>> = Data) -> Data;
hex_data(Data) -> eth_hex:encode_data(Data).

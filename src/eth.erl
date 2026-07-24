-module(eth).

%% High level entry points: build, sign and submit a transaction, and wait
%% for it to be mined.
%%
%% NONCE OWNERSHIP
%%
%% send/2 reads the nonce from the chain (`latest') on every call and keeps no
%% state. That is correct only while a single process is signing for a given
%% address at a time, and only while it waits for the previous transaction to
%% be mined before sending the next one — which is what send_and_wait/2 does.
%%
%% Two concurrent senders on one address do not lose funds: the second
%% transaction is rejected by the node with "nonce too low" rather than
%% replacing the first. But it does fail, so serialise per address, one owner
%% per address across the whole cluster.

-export([send/2]).
-export([send_and_wait/2]).
-export([wait_receipt/2]).
-export([wait_receipt/3]).
-export([balance/2]).
-export([transfer/2]).
-export([call/3]).

%% Base fee can rise 12.5% per block; covering two doublings leaves room for
%% roughly six consecutive full blocks before a transaction stalls.
-define(BASE_FEE_MULTIPLIER, 2).
-define(GAS_BUFFER_PERCENT, 20).
-define(DEFAULT_PRIORITY_FEE, 1_000_000_000).
-define(RECEIPT_TIMEOUT, timer:seconds(180)).
-define(RECEIPT_INTERVAL, timer:seconds(1)).

-type request() :: #{
    private_key := binary(),
    to => binary() | undefined,
    value => non_neg_integer(),
    data => binary(),
    from => binary(),
    chain_id => non_neg_integer(),
    nonce => non_neg_integer(),
    gas => non_neg_integer(),
    max_fee_per_gas => non_neg_integer(),
    max_priority_fee_per_gas => non_neg_integer()
}.
-export_type([request/0]).

%% @doc Sign and submit a transaction, returning as soon as the node accepts
%% it. Anything not supplied in the request is fetched from the chain.
-spec send(eth_rpc:endpoint(), request()) -> {ok, binary()} | {error, term()}.
send(Url, Request) ->
    maybe
        {ok, Tx} ?= build(Url, Request),
        #{raw := Raw} = eth_tx:sign(Tx, maps:get(private_key, Request)),
        {ok, _Hash} ?= eth_rpc:send_raw_transaction(Url, Raw)
    end.

%% @doc send/2 followed by wait_receipt/3. This is the form that keeps the
%% "one transaction at a time per address" invariant true.
-spec send_and_wait(eth_rpc:endpoint(), request()) -> {ok, map()} | {error, term()}.
send_and_wait(Url, Request) ->
    maybe
        {ok, Hash} ?= send(Url, Request),
        wait_receipt(Url, Hash)
    end.

%% @doc Convenience for a plain value transfer.
-spec transfer(eth_rpc:endpoint(), request()) -> {ok, binary()} | {error, term()}.
transfer(Url, Request) ->
    send(Url, maps:merge(#{data => <<>>}, Request)).

-spec balance(eth_rpc:endpoint(), binary()) -> {ok, non_neg_integer()} | {error, term()}.
balance(Url, Address) ->
    eth_rpc:balance(Url, Address).

%% @doc Read-only contract call:
%% `call(Url, Contract, {<<"balanceOf(address)">>, [Address], [<<"uint256">>]})'.
-spec call(eth_rpc:endpoint(), binary(), {binary(), [term()], [binary()]}) ->
    {ok, [term()]} | {error, term()}.
call(Url, Contract, {Signature, Args, Returns}) ->
    Tx = #{to => eth_account:checksum(Contract), data => eth_abi:encode_call(Signature, Args)},
    case eth_rpc:eth_call(Url, Tx, latest) of
        {ok, Data}  -> {ok, eth_abi:decode(Returns, Data)};
        Error       -> Error
    end.

%% @doc Poll for a receipt. A receipt with `status = 0' is returned as an
%% error: the transaction was mined but reverted, and callers almost always
%% want that on the failure path rather than silently succeeding.
-spec wait_receipt(eth_rpc:endpoint(), binary()) -> {ok, map()} | {error, term()}.
wait_receipt(Url, Hash) ->
    wait_receipt(Url, Hash, #{}).

-spec wait_receipt(eth_rpc:endpoint(), binary(), map()) -> {ok, map()} | {error, term()}.
wait_receipt(Url, Hash, Opts) ->
    Timeout = maps:get(timeout, Opts, ?RECEIPT_TIMEOUT),
    Interval = maps:get(interval, Opts, ?RECEIPT_INTERVAL),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    poll_receipt(Url, Hash, Deadline, Interval).

poll_receipt(Url, Hash, Deadline, Interval) ->
    case eth_rpc:transaction_receipt(Url, Hash) of
        {ok, null} ->
            case erlang:monotonic_time(millisecond) + Interval < Deadline of
                true ->
                    timer:sleep(Interval),
                    poll_receipt(Url, Hash, Deadline, Interval);
                false ->
                    {error, {timeout, Hash}}
            end;
        {ok, #{<<"status">> := <<"0x1">>} = Receipt} ->
            {ok, Receipt};
        {ok, #{<<"status">> := _} = Receipt} ->
            {error, {reverted, Receipt}};
        Error ->
            Error
    end.

%%%===================================================================
%%% Building
%%%===================================================================

build(Url, Request) ->
    From = sender(Request),
    maybe
        {ok, ChainId} ?= fetch(chain_id, Request, fun() -> eth_rpc:chain_id(Url) end),
        {ok, Nonce} ?= fetch(nonce, Request,
                             fun() -> eth_rpc:transaction_count(Url, From, latest) end),
        {ok, Priority} ?= fetch(max_priority_fee_per_gas, Request,
                                fun() -> priority_fee(Url) end),
        {ok, MaxFee} ?= fetch(max_fee_per_gas, Request, fun() -> max_fee(Url, Priority) end),
        {ok, Gas} ?= fetch(gas, Request, fun() -> gas(Url, From, Request) end),
        {ok, #{
            chain_id                 => ChainId,
            nonce                    => Nonce,
            max_priority_fee_per_gas => Priority,
            max_fee_per_gas          => MaxFee,
            gas                      => Gas,
            to                       => maps:get(to, Request, undefined),
            value                    => maps:get(value, Request, 0),
            data                     => maps:get(data, Request, <<>>)
        }}
    end.

sender(Request) ->
    case maps:find(from, Request) of
        {ok, From} -> From;
        error      -> eth_account:address(maps:get(private_key, Request))
    end.

fetch(Key, Request, Fun) ->
    case maps:find(Key, Request) of
        {ok, Value} -> {ok, Value};
        error       -> Fun()
    end.

%% Not every node implements eth_maxPriorityFeePerGas; fall back rather than
%% failing the send.
priority_fee(Url) ->
    case eth_rpc:max_priority_fee_per_gas(Url) of
        {ok, Fee} -> {ok, Fee};
        {error, _} -> {ok, ?DEFAULT_PRIORITY_FEE}
    end.

max_fee(Url, Priority) ->
    case eth_rpc:base_fee(Url, latest) of
        {ok, BaseFee} -> {ok, BaseFee * ?BASE_FEE_MULTIPLIER + Priority};
        Error         -> Error
    end.

gas(Url, From, Request) ->
    Tx = #{
        from  => From,
        to    => maps:get(to, Request, undefined),
        value => maps:get(value, Request, 0),
        data  => maps:get(data, Request, <<>>)
    },
    case eth_rpc:estimate_gas(Url, maps:filter(fun(_, V) -> V =/= undefined end, Tx)) of
        {ok, Estimate} -> {ok, Estimate * (100 + ?GAS_BUFFER_PERCENT) div 100};
        Error          -> Error
    end.

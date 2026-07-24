-module(eth_sub).

-behaviour(gen_server).

%% One `eth_subscribe' subscription over a WebSocket, with reconnect.
%%
%% Transport is hackney's WebSocket client, so a service already using
%% eth_rpc needs no second HTTP client (and none of gun's QUIC build
%% requirements).
%%
%% Events are delivered to an owner process rather than a callback, so the
%% owner stays an ordinary gen_server and decides for itself what is blocking
%% work and what is not:
%%
%%   {eth_sub, Pid, {subscribed, SubscriptionId}}
%%   {eth_sub, Pid, {event, Result}}
%%   {eth_sub, Pid, {down, Reason}}
%%
%% GAPS
%%
%% A subscription only reports what happens while it is up. Every reconnect
%% therefore leaves a hole between the last event received and the first one
%% after resubscribing. `{subscribed, _}' is sent on the *initial* connection
%% and on every reconnect precisely so the owner can close that hole by
%% backfilling over eth_getLogs — it is not merely an informational message,
%% and treating it as one loses deposits.

-export([start_link/1]).
-export([start_link/2]).
-export([logs/2]).
-export([logs/3]).
-export([new_heads/1]).
-export([new_heads/2]).
-export([subscription_id/1]).
-export([stop/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_continue/2]).
-export([handle_info/2]).
-export([terminate/2]).

-define(SUBSCRIBE_ID, 1).
-define(CONNECT_TIMEOUT, timer:seconds(5)).
-define(RECONNECT_DELAY, timer:seconds(1)).
-define(MAX_RECONNECT_DELAY, timer:seconds(30)).

-type opts() :: #{
    url := binary() | string(),
    params := [term()],
    owner => pid(),
    connect_timeout => timeout(),
    reconnect_delay => pos_integer(),
    max_reconnect_delay => pos_integer(),
    ssl_options => list(),
    headers => list()
}.
-export_type([opts/0]).

-record(state, {
    url :: binary() | string(),
    params :: [term()],
    owner :: pid(),
    opts :: opts(),
    ws :: undefined | pid(),
    id :: undefined | binary(),
    delay :: pos_integer()
}).

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(opts()) -> {ok, pid()} | {error, term()}.
start_link(Opts) ->
    gen_server:start_link(?MODULE, with_owner(Opts), []).

-spec start_link(gen_server:server_name(), opts()) -> {ok, pid()} | {error, term()}.
start_link(Name, Opts) ->
    gen_server:start_link(Name, ?MODULE, with_owner(Opts), []).

%% @doc Subscribe to logs matching a filter, e.g.
%% `#{address => Token, topics => [eth_abi:transfer_topic()]}'.
-spec logs(binary() | string(), map()) -> {ok, pid()} | {error, term()}.
logs(Url, Filter) ->
    logs(Url, Filter, #{}).

-spec logs(binary() | string(), map(), opts() | map()) -> {ok, pid()} | {error, term()}.
logs(Url, Filter, Opts) ->
    start_link(Opts#{url => Url, params => [<<"logs">>, Filter]}).

-spec new_heads(binary() | string()) -> {ok, pid()} | {error, term()}.
new_heads(Url) ->
    new_heads(Url, #{}).

-spec new_heads(binary() | string(), opts() | map()) -> {ok, pid()} | {error, term()}.
new_heads(Url, Opts) ->
    start_link(Opts#{url => Url, params => [<<"newHeads">>]}).

%% @doc Current subscription id, or `undefined' while disconnected.
-spec subscription_id(pid()) -> undefined | binary().
subscription_id(Pid) ->
    gen_server:call(Pid, subscription_id).

-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:stop(Pid).

with_owner(Opts) ->
    maps:merge(#{owner => self()}, Opts).

%%%===================================================================
%%% gen_server
%%%===================================================================

init(Opts) ->
    %% hackney_ws:start_link/1 links to us, so its death must arrive as a
    %% message rather than take this process down with it.
    process_flag(trap_exit, true),
    State = #state{
        url    = maps:get(url, Opts),
        params = maps:get(params, Opts),
        owner  = maps:get(owner, Opts),
        opts   = Opts,
        delay  = maps:get(reconnect_delay, Opts, ?RECONNECT_DELAY)
    },
    %% Connecting in a continue rather than in init keeps a dead endpoint from
    %% blocking the supervisor, and makes the first attempt take exactly the
    %% same path as every reconnect.
    {ok, State, {continue, connect}}.

handle_continue(connect, State) ->
    {noreply, connect(State)}.

handle_call(subscription_id, _From, State) ->
    {reply, State#state.id, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({hackney_ws, Ws, {text, Data}}, #state{ws = Ws} = State) ->
    {noreply, handle_message(Data, State)};

%% Ping and pong are answered by hackney itself; they surface here only as
%% liveness information.
handle_info({hackney_ws, Ws, Frame}, #state{ws = Ws} = State)
  when Frame =:= ping; Frame =:= pong;
       element(1, Frame) =:= ping; element(1, Frame) =:= pong;
       element(1, Frame) =:= binary ->
    {noreply, State};

handle_info({hackney_ws, Ws, {close, Code, Reason}}, #state{ws = Ws} = State) ->
    {noreply, reconnect({closed, Code, Reason}, State)};

handle_info({hackney_ws, Ws, closed}, #state{ws = Ws} = State) ->
    {noreply, reconnect(closed, State)};

handle_info({hackney_ws_error, Ws, Reason}, #state{ws = Ws} = State) ->
    {noreply, reconnect(Reason, State)};

handle_info({'EXIT', Ws, Reason}, #state{ws = Ws} = State) ->
    {noreply, reconnect(Reason, State)};

handle_info(connect, State) ->
    {noreply, connect(State)};

%% Anything from a socket we have already given up on.
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    close(State#state.ws).

%%%===================================================================
%%% Internal
%%%===================================================================

connect(State) ->
    Opts = State#state.opts,
    ConnectOpts = [
        {active, true},
        {connect_timeout, maps:get(connect_timeout, Opts, ?CONNECT_TIMEOUT)},
        {ssl_options, maps:get(ssl_options, Opts, [])},
        {headers, maps:get(headers, Opts, [])}
    ],
    case hackney:ws_connect(State#state.url, ConnectOpts) of
        {ok, Ws} ->
            subscribe(State#state{ws = Ws, id = undefined});
        {error, Reason} ->
            reconnect(Reason, State#state{ws = undefined, id = undefined})
    end.

subscribe(State) ->
    %% json:encode/1 returns iodata; a WebSocket frame needs a payload whose
    %% size is known up front.
    Request = iolist_to_binary(json:encode(#{
        jsonrpc => <<"2.0">>,
        id      => ?SUBSCRIBE_ID,
        method  => <<"eth_subscribe">>,
        params  => State#state.params
    })),
    case hackney:ws_send(State#state.ws, {text, Request}) of
        ok              -> State;
        {error, Reason} -> reconnect(Reason, State)
    end.

handle_message(Data, State) ->
    try json:decode(Data) of
        #{<<"method">> := <<"eth_subscription">>, <<"params">> := #{<<"result">> := Result}} ->
            notify({event, Result}, State),
            State;
        #{<<"id">> := ?SUBSCRIBE_ID, <<"result">> := Id} when is_binary(Id) ->
            notify({subscribed, Id}, State),
            %% Only a live subscription proves the endpoint is healthy, so the
            %% backoff resets here and not on connect.
            State#state{id = Id, delay = initial_delay(State)};
        #{<<"id">> := ?SUBSCRIBE_ID, <<"error">> := Error} ->
            reconnect({subscribe_failed, Error}, State);
        _Other ->
            State
    catch
        _:_ -> State
    end.

reconnect(Reason, State) ->
    close(State#state.ws),
    notify({down, Reason}, State),
    erlang:send_after(State#state.delay, self(), connect),
    Max = maps:get(max_reconnect_delay, State#state.opts, ?MAX_RECONNECT_DELAY),
    State#state{ws = undefined, id = undefined, delay = min(State#state.delay * 2, Max)}.

initial_delay(State) ->
    maps:get(reconnect_delay, State#state.opts, ?RECONNECT_DELAY).

notify(Message, State) ->
    State#state.owner ! {eth_sub, self(), Message},
    ok.

close(undefined) ->
    ok;
close(Ws) ->
    %% The socket may already be gone; closing it is best effort.
    catch hackney:ws_close(Ws),
    ok.

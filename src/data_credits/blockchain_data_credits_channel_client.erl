%%%-------------------------------------------------------------------
%% @doc
%% == Blockchain Data Credits Channel Client ==
%% @end
%%%-------------------------------------------------------------------
-module(blockchain_data_credits_channel_client).

-behavior(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([
    start/1,
    height/1,
    credits/1
]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-include("blockchain.hrl").
-include("../pb/blockchain_data_credits_pb.hrl").

-define(SERVER, ?MODULE).

-record(state, {
    db :: rocksdb:db_handle(),
    cf :: rocksdb:cf_handle(),
    payer :: libp2p_crypto:pubkey_bin(),
    credits = 0 :: non_neg_integer(),
    height = 0 :: non_neg_integer(),
    pending = [] :: [non_neg_integer()]
}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start(Args) ->
    gen_server:start(?SERVER, Args, []).

height(Pid) ->
    gen_statem:call(Pid, height).

credits(Pid) ->
    gen_statem:call(Pid, credits).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init([DB, CF, Payer, Amount]=Args) ->
    lager:info("~p init with ~p", [?SERVER, Args]),
    self() ! {send_payment_req, Amount},
    {ok, #state{
        db=DB,
        cf=CF,
        payer=Payer,
        pending=[Amount]
    }}.

handle_call(height, _From, #state{height=Height}=State) ->
    {reply, {ok, Height}, State};
handle_call(credits, _From, #state{credits=Credits}=State) ->
    {reply, {ok, Credits}, State};
handle_call(_Msg, _From, State) ->
    lager:warning("rcvd unknown call msg: ~p from: ~p", [_Msg, _From]),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    lager:warning("rcvd unknown cast msg: ~p", [_Msg]),
    {noreply, State}.

handle_info({send_payment_req, Amount}, #state{payer=Payer, pending=Pending}=State) ->
    Swarm = blockchain_swarm:swarm(),
    P2PAddr = libp2p_crypto:pubkey_bin_to_p2p(Payer),
    case libp2p_swarm:dial_framed_stream(Swarm,
                                         P2PAddr,
                                         ?DATA_CREDITS_PAYMENT_PROTOCOL,
                                         blockchain_data_credits_payment_stream,
                                         [])
    of
        {ok, Stream} ->
            PubKeyBin = blockchain_swarm:pubkey_bin(),	
            PaymentReq = blockchain_data_credits_utils:new_payment_req(PubKeyBin, Amount),
            EncodedPaymentReq = blockchain_data_credits_utils:encode_payment_req(PaymentReq),
            lager:info("sending payment request (~p) to ~p", [Amount, Payer]),
            Stream ! {payment_req, EncodedPaymentReq},
            ID = PaymentReq#blockchain_data_credits_payment_req_pb.id,
            {noreply, State#state{pending=[{ID, Amount}|Pending]}};
        Error ->
            lager:error("failed to dial ~p ~p", [P2PAddr, Error]),
            {stop, dial_error, State}
    end;
handle_info({update, Payment}, #state{db=DB, cf=CF, height=Height,
                                      credits=Credits, pending=_Pending}=State) ->
    lager:info("got payment update ~p", [Payment]),
    Amount = Payment#blockchain_data_credits_payment_pb.amount,
    _Payee = Payment#blockchain_data_credits_payment_pb.payee,
    ok = blockchain_data_credits_utils:store_payment(DB, CF, Payment),
    case Payment#blockchain_data_credits_payment_pb.height == 0 of
        true ->
            {noreply, State#state{height=0, credits=Amount}};
        false ->
            {noreply, State#state{height=Height+1, credits=Credits-Amount}}
    end;
handle_info(_Msg, State) ->
    lager:warning("rcvd unknown info msg: ~p", [_Msg]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
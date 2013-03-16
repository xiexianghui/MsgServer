-module(ti_handler_mon).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("ti_header.hrl").

-define(TIMEOUT, 120000). 

start_link(Socket) ->   
    gen_server:start_link(?MODULE, [Socket], []). 

init([Socket]) ->   
    inet:setopts(Socket, [{active, once}]), 
    %inet:setopts(Socket, [{active, true}, {packet, 0}, binary]),   
    {ok, #monitem{socket=Socket}}. 

handle_call(_Request, _From, State) ->
    {noreply, ok, State}.

handle_cast(_Msg, State) ->    
    {noreply, State}. 

handle_info({tcp, Socket, Data}, State) ->    
    inet:setopts(Socket, [{active, once}]),
    Bin = ti_man_data_parser:parse_data(Data),
    % Should be modified in the future
    ok = gen_tcp:send(Socket, <<"Monitor : ", Bin/binary>>),    
    {noreply, State}; 
handle_info({tcp_closed, Socket}, StateData) ->    
    case ti_common:safepeername(Socket) of
        {ok, {Address, _Port}} ->
            ti_common:loginfo("Monitor IP : ~p~n", Address);
        {error, Explain} ->
            ti_common:loginfo("Unknown monitor : ~p~n", Explain)
    end,
    ti_common:loginfo("Monitor is disconnected~n"),
    ti_common:loginfo("Monitor Pid ~p stops~n", self()),
    {stop, normal, StateData}; 
handle_info(_Info, StateData) ->    
    {noreply, StateData}. 

terminate(_Reason, #monitem{socket=Socket}) ->    
    ti_common:loginfo("Monitor Pid ~p is terminated~n", self()),
    (catch gen_tcp:close(Socket)),    
    ok.

code_change(_OldVsn, State, _Extra) ->    
    {ok, State}.



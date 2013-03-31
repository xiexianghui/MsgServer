-module(ti_handler_vdr).

-behaviour(gen_server).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("ti_header.hrl").

start_link(Socket, Addr) ->	
	gen_server:start_link(?MODULE, [Socket, Addr], []). 

init([Socket, Addr]) ->
    %process_flag(trap_exit, true),
    Pid = self(),
    VDRPid = spawn(fun() -> data2vdr_process(Pid, Socket) end),
    State=#vdritem{socket=Socket, pid=Pid, vdrpid=VDRPid, addr=Addr, msgflownum=0},
    ets:insert(vdrtable, State), 
    inet:setopts(Socket, [{active, once}]),
	{ok, State}.

handle_call(_Request, _From, State) ->
	{noreply, ok, State}.

handle_cast(_Msg, State) ->    
	{noreply, State}. 

%%%
%%% VDR handler receives date from VDR
%%% Steps :
%%%     1. Parse the data
%%%     2. Check whether it is ID reporting message
%%%         YES -> 
%%%             Update the vdritem record
%%%         NO ->
%%%             A. Check whether the VDR has reported ID or not
%%%                 YES ->
%%%                     a. Send it to the DB
%%%                     b. Check whether it is a management reporting message
%%%                         YES ->
%%%                             Report the data to the management platform
%%%                         NO ->
%%%                             Do nothing
%%%                 NO ->
%%%                     a. Discard the data
%%%                     b. Request ID reporting message (REALLY NEEDED?)
%%%
%%% Still in design
%%%
handle_info({tcp, Socket, Data}, State) ->
    case process_vdr_data(Socket, Data, State) of
        {error, NewState} ->
            {stop, dbprocerror, NewState};
        {ok, NewState} ->
            {noreply, NewState}
    end;
handle_info({tcp_closed, _Socket}, State) ->    
    ti_common:loginfo("VDR (~p) : TCP is closed~n"),
    % return stop will invoke terminate(Reason,State)
    % tcp_closed will be transfered as Reason
	{stop, tcp_closed, State}; 
handle_info(_Info, State) ->    
	{noreply, State}. 

%%%
%%% When VDR handler process is terminated, do the clean jobs here
%%%
terminate(Reason, State) ->
    VDRPid = State#vdritem.vdrpid,
    case VDRPid of
        undefined ->
            ok;
        _ ->
            VDRPid!stop
    end,
	try gen_tcp:close(State#vdritem.socket) of
        ok ->
            ok
    catch
        _:Exception ->
            ti_common:logerror("VDR (~p) : Exception when closing TCP : ~p~n", [State#vdritem.addr, Exception])
    end,
    ti_common:loginfo("VDR (~p) : VDR handler process (~p) is terminated : ~p~n", [State#vdritem.addr, State#vdritem.pid, Reason]).

code_change(_OldVsn, State, _Extra) ->    
	{ok, State}.

%%%
%%% This function should refer to the document on the mechanism
%%%
%%% Return :
%%%     {ok, State}
%%%     {error, State}          when DB connection process is not available
%%%     
%%%
%%% Still in design
%%%
process_vdr_data(Socket, Data, State) ->
    [{dbconnpid, DBProcessPid}] = ets:lookup(msgservertable, dbconnpid),
    case DBProcessPid of
        undefined ->
            ti_common:logerror("DB Client is not available~n"),
            {error, State};
        _ ->
            case ti_vdr_data_parser:process_data(Socket, State, Data) of
                {ok, {Resp, NewState}, Result} ->
                    % convert to database messages
                    DBMsg = composedbmsg(Result),
                    DBProcessPid!DBMsg,
                    case receivedbprocessmsg(DBProcessPid, 0) of
                        ok ->
                            VDRPid = NewState#vdritem.vdrpid,
                            VDRPid!Resp,
                            {ok, NewState};
                        error ->
                            {error, NewState}
                    end;
                {fail, {Resp, NewState}} ->
                    VDRPid = NewState#vdritem.vdrpid,
                    VDRPid!Resp,
                    {ok, NewState};
                {error, NewState} ->
                    {error, NewState}
            end
    end.

%%%
%%% Try to receive response from the DB connection process at most 10 times.
%%% Do we need _Resp from the DB connection process?
%%% Return : ok | error
%%%
receivedbprocessmsg(DBProcessPid, ErrorCount) ->
    if
        ErrorCount < ?DB_PROCESS_TRIAL_MAX ->
            receive
                {From, _Resp} ->
                    if
                        From == DBProcessPid ->
                            ok;
                        From =/= DBProcessPid ->
                            receivedbprocessmsg(DBProcessPid, ErrorCount+1)
                    end;
                _ ->
                    receivedbprocessmsg(DBProcessPid, ErrorCount+1)
            after ?TIMEOUT_DATA_DB ->
                    receivedbprocessmsg(DBProcessPid, ErrorCount+1)
            end;
        ErrorCount >= ?DB_PROCESS_TRIAL_MAX ->
            error
    end.
            
%%%         
%%%
%%%
composedbmsg(Msg) ->
    Msg.

%%%
%%% This process is send msg from the management to the VDR.
%%% Each time when sending msg from the management to the VDR, a flag should be set in vdritem.
%%% If the ack from the VDR is received in handle_info({tcp,Socket,Data},State), this flag will be cleared.
%%% After the defined TIMEOUT is achived, it means VDR cannot response and the TIMEOUT should be adjusted and this msg will be sent again.
%%% (Please refer to the specification for this mechanism.)
%%%
%%% Still in design
%%%
data2vdr_process(Pid, Socket) ->
    receive
        {FromPid, {data, Data}} ->
            if 
                FromPid == Pid ->
                    gen_tcp:send(Socket, Data);
                FromPid =/= Pid ->
                    ti_common:logerror("VDR server send data to VDR process : message from unknown PID ~p : ~p~n", [FromPid, Data])
            end,        
            data2vdr_process(Pid, Socket);
        {FromPid, Data} ->
            ti_common:logerror("VDR server send data to VDR process : unknown message from PID ~p : ~p~n", [FromPid, Data]),
            data2vdr_process(Pid, Socket);
        stop ->
            ok
    after ?TIMEOUT_DATA_VDR ->
        %ti_common:loginfo("VDR server send data to VDR process process : receiving PID message timeout after ~p~n", [?TIMEOUT_DB]),
        data2vdr_process(Pid, Socket)
    end.

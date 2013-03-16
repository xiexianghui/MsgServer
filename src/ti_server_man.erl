%%%
%%% Need considering how management server sends message to VDR
%%%

-module(ti_server_man).

-behaviour(gen_server).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, 
         handle_info/2, terminate/2, code_change/3]). 

-include("ti_header.hrl").

%%%
%%% In fact, we can get PortMan from msgservertable.
%%% Here, the reason that we use parameter is for efficiency.
%%%
start_link(PortMan) ->    
	gen_server:start_link({local, ?MODULE}, ?MODULE, [PortMan], []). 

%%%
%%% {backlog, 30} specifies the length of the OS accept queue. 
%%%
init([PortMan]) ->    
	process_flag(trap_exit, true),    
	Opts = [binary, {packet, 0}, {reuseaddr, true}, {keepalive, true}, {active, once}],    
	% VDR server start listening
    case gen_tcp:listen(PortMan, Opts) of	    
		{ok, LSock} -> 
            % Create first accepting process	        
			case prim_inet:async_accept(LSock, -1) of
                {ok, Ref} ->
                    {ok, #serverstate{lsock=LSock, acceptor=Ref}};
                Error ->
                    ti_common:logerror("Management server async accept fails : ~p~n", Error),
                    {stop, Error}
            end;
		{error, Reason} ->	        
            ti_common:logerror("Management server listen fails : ~p~n", Reason),
			{stop, Reason}    
	end. 

handle_call(Request, _From, State) ->    
	{stop, {unknown_call, Request}, State}.

handle_cast(_Msg, State) ->    
	{noreply, State}. 

handle_info({inet_async, LSock, Ref, {ok, CSock}}, #serverstate{lsock=LSock, acceptor=Ref}=State) ->    
    case ti_common:safepeername(CSock) of
        {ok, {Address, _Port}} ->
            ti_common:loginfo("Accepted management IP : ~p~n", Address);
        {error, Explain} ->
           ti_common:loginfo("Unknown accepted management : ~p~n", Explain)
    end,
	try        
		case set_sockopt(LSock, CSock) of	        
			ok -> 
                % New client connected
                % Spawn a new process using the simple_one_for_one supervisor.
                % Why it is "the simple_one_for_one supervisor"?
                case ti_sup:start_child_man(CSock) of
                    {ok, Pid} ->
                        case gen_tcp:controlling_process(CSock, Pid) of
                           ok ->
                                ok;
                            {error, Reason1} ->
                                ti_common:logerror("Management server gen_server:controlling_process fails when inet_async : ~p~n", Reason1)
                        end;
                    {ok, Pid, _Info} ->
                        case gen_tcp:controlling_process(CSock, Pid) of
                           ok ->
                                ok;
                            {error, Reason1} ->
                                ti_common:logerror("Management server gen_server:controlling_process fails when inet_async : ~p~n", Reason1)
                        end;
                    {error, already_present} ->
                        ti_common:logerror("Management server ti_sup:start_child_vdr fails when inet_async : already_present~n");
                    {error, {already_started, Pid}} ->
                        ti_common:logerror("Management server ti_sup:start_child_vdr fails when inet_async : already_started PID : ~p~n", Pid);
                    {error, Msg} ->
                        ti_common:logerror("Management server ti_sup:start_child_vdr fails when inet_async : ~p~n", Msg)
                end;
			{error, Reason} -> 
                ti_common:logerror("Management server set_sockopt fails when inet_async : ~p~n", Reason)%,
  				%exit({set_sockopt, Reason})       
		end,
        %% Signal the network driver that we are ready to accept another connection        
		case prim_inet:async_accept(LSock, -1) of	        
			{ok, NewRef} -> 
                {noreply, State#serverstate{acceptor=NewRef}};
			Error ->
                ti_common:logerror("Management server prim_inet:async_accept fails when inet_async : ~p~n", inet:format_error(Error)),
                {stop, Error, State}
                %exit({async_accept, inet:format_error(Error)})        
		end
	catch 
		exit:Why ->        
            ti_common:logerror("Management server error in async accept : ~p~n", Why),			
            {stop, Why, State}    
	end;
handle_info({tcp, Socket, Data}, State) ->    
    inet:setopts(Socket, [{active, once}]),
    % Should be modified in the future
    ok = gen_tcp:send(Socket, <<"Management server : ", Data/binary>>),    
    {noreply, State}; 
handle_info({inet_async, LSock, Ref, Error}, #serverstate{lsock=LSock, acceptor=Ref} = State) ->    
    ti_common:logerror("Management server error in socket acceptor : ~p~n", Error),
    {stop, Error, State}; 
handle_info(_Info, State) ->    
    {noreply, State}. 

terminate(Reason, State) ->    
    ti_common:logerror("Management server is terminated~n", Reason),
    gen_tcp:close(State#serverstate.lsock),    
    ok. 

code_change(_OldVsn, State, _Extra) ->    
	{ok, State}. 
    
%%%
%%% Taken from prim_inet.  We are merely copying some socket options from the
%%% listening socket to the new client socket.
%%%
set_sockopt(LSock, CSock) ->    
	true = inet_db:register_socket(CSock, inet_tcp),    
	case prim_inet:getopts(LSock, [active, nodelay, keepalive, delay_send, priority, tos]) of	    
		{ok, Opts} ->	        
			case prim_inet:setopts(CSock, Opts) of		        
				ok -> 
					ok;		        
				Error -> 
					ti_common:logerror("Management server prim_inet:setopts fails : ~p~n", Error),    
                    gen_tcp:close(CSock)
			end;	   
		Error ->	       
            ti_common:logerror("Management server prim_inet:getopts fails : ~p~n", Error),
			gen_tcp:close(CSock)
	end.



								
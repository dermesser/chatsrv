-module(chatsrv).
-compile(export_all).

-include_lib("stdlib/include/qlc.hrl").

-record(channels,{cnumber,pid,topic}).
-record(users,{uid,uname,pid,channels}).

%% CLI entry point
main([TrueOrFalse]) -> start_server(TrueOrFalse).

%% Start server process and DB
start_server(New) ->
	start_mnesia(New),
	spawn(fun start_client_listen/0).

%% Start DB and create schema
start_mnesia(true) ->
	mnesia:create_schema([node()]),
	mnesia:start(),
	mnesia:create_table(channels,[{attributes,record_info(fields,channels)}]),
	mnesia:create_table(users,[{attributes,record_info(fields,users)}]);

%% Only start DB
start_mnesia(false) ->
	mnesia:start().

%% Listen
start_client_listen() ->
	{ok,Socket} = gen_tcp:listen(32768,[binary,{packet,0}]),
	accept_loop(Socket).

%% Accept connections
accept_loop(Socket) ->
	{ok,ClSock} = gen_tcp:accept(Socket),
	%% Our client handler expects tcp data as messages
	gen_tcp:controlling_process(ClSock,spawn(?MODULE,handle_client,[ClSock,""])),
	accept_loop(Socket).

%% Handle clients in a loop
%% UserName is the state. It's the associated user.
handle_client(Socket,UserName) ->
	receive
		%% A new TCP message
		{tcp,Socket,Data} ->
			%% Handle the message with handle_data() - providing join, log in, sending messages etc
			try handle_data(Data,UserName) of
				%% Should always return a user name (in case of change)
				String when is_list(String) -> handle_client(Socket,String);
				deleted -> gen_tcp:close(Socket);
				parted -> handle_client(Socket,UserName)
			catch
				throw: userExistsAlready -> gen_tcp:send(Socket,"EXCEPTION: User exists already.\n");
					%handle_client(Socket,""); %% Thrown by add_user() %% Just abort communication
				throw: noSuchUser -> gen_tcp:send(Socket,"EXCEPTION: No such user. Maybe you should authenticate yourself before sending messages\n");
					%handle_client(Socket,UserName); %% Thrown by join_channel() %% Just abort communication
				throw: dbError -> gen_tcp:send(Socket,"EXCEPTION: dbError exception. Continue...\n"),
					handle_client(Socket,UserName)
			end;
		{tcp_closed,Socket} -> remove_user(UserName);
		{mesg,Message}      -> gen_tcp:send(Socket,Message), handle_client(Socket,UserName)
	end.

%% Handle received Data -- basically a dispatcher. Called on every received message
handle_data(Data,UserName) ->
	%% Separate the first byte, it's the type of message byte
	%io:format("~p~n",[Data]),
	case split_binary(Data,1) of
		{<<1>>,<<ChanNumber:64/native-unsigned>>} ->
			join_channel(ChanNumber,UserName),
			UserName;
		{<<2>>,ChanAndMesg} -> {DstChannel, OrigMessage} = parse_message(ChanAndMesg),
			send_message(DstChannel,[UserName|[": "|OrigMessage]]),
			UserName;
		{<<3>>,NewUserName} ->
			UserAsString = binary_to_list(NewUserName),
			ok = add_user(UserAsString),
			case string:equal(UserName,"") of
				false -> remove_user(UserName);
				true -> ok
			end,
			UserAsString;
		{<<4>>,<<>>} ->
			case string:equal(UserName,"") of
				false -> remove_user(UserName), deleted;
				true -> deleted
			end;
		{<<5>>,<<ChanNum:64/native-unsigned>>} ->
			remove_user_from(UserName,ChanNum),
			parted
	end.

%%%%%%%%%%%%%%%%%%%%% Functions called by the handle_data() dispatcher %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Send a message to a channel
send_message(Channel,Message) ->
	%% Obtain Channel PID
	case mnesia:transaction(fun() ->
					mnesia:read({channels,Channel})
			end) of
		{atomic,[#channels{pid=Pid}]} -> Pid ! {mesg,Message};
		_              -> throw(dbError)
	end.

%% Associate a user with a channel
join_channel(Channel,User) ->
	%% Get UID of user
	case mnesia:transaction(fun() ->
				qlc:e(qlc:q([U || U <- mnesia:table(users), string:equal(U#users.uname,User)]))
		end) of

		{atomic,[UserRecord]} -> UserRecord;
		{atomic,[]}           -> UserRecord = {}, throw(noSuchUser) %% Abort - no such user
	end,

	%% Get Channel PID, send add command or create channel.
	case mnesia:transaction(fun() ->
				case mnesia:read({channels,Channel}) of
					%% Channel exists
					[#channels{pid=Pid}] -> Pid ! {add_member,UserRecord#users.uid,User}, ok;
					%% Create new channel
					[] ->
						NewCPid = spawn(?MODULE,chanproc,[Channel,[UserRecord#users.uid]]),
						Record = #channels{cnumber=Channel, pid=NewCPid, topic=""},
						mnesia:write(Record),
						ok;
					_ -> throw(dbError)
				end
			end) of
		{atomic,ok} -> ok;
		{aborted,{throw,Exception}} -> throw(Exception)
	end,

	%% Write back the new User Record with the new channel appended
	{atomic,ok} = mnesia:transaction(fun() ->
				OldChannels = UserRecord#users.channels,
				JoinedUser = UserRecord#users{channels=[Channel|OldChannels]},
				mnesia:write(JoinedUser)
		end).

%% Add a user to the db
add_user(UserName) ->
	io:format("Adding User ~p~n",[UserName]),
	Pid = self(),

	case mnesia:transaction(fun() ->
				%% ensure that no other user of this name is registered
				case qlc:e(qlc:q([U#users.uname || U <- mnesia:table(users), string:equal(UserName,U#users.uname)])) of
					[] -> ok;
					_ -> throw(userExistsAlready)
				end,
				Record = #users{uid=make_ref(),uname=UserName, pid=Pid,channels=[]},
				mnesia:write(Record)
		end) of

		{atomic,ok}              -> ok;
		{aborted,{throw,Reason}} -> throw(Reason)
	end.

%% Remove a user from everywhere
remove_user(UserName) ->
	io:format("Removing ~p~n",[UserName]),
	%% Obtain UID
	{atomic,{UID,Channels}} = mnesia:transaction(fun() ->
				[{UID,Channels}] = qlc:e(qlc:q([{U#users.uid,U#users.channels} || U <- mnesia:table(users), string:equal(U#users.uname,UserName)])),
				%% Delete him
				mnesia:delete({users,UID}),
				{UID,Channels}
			end),

	%% Get the list of corresponding Channel PIDs
	{atomic,CPids} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([C#channels.pid || C <- mnesia:table(channels), lists:member(C#channels.cnumber,Channels)]))
		end),

	lists:foreach(fun(CPid) ->
				CPid ! {remove_member,UID,UserName}
		end,CPids).

remove_user_from(UserName,Channel) ->
	%% Obtain UID
	{atomic,[UID]} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([U#users.uid|| U <- mnesia:table(users), string:equal(U#users.uname,UserName)]))
		end),
	%% Obtain Channel PID
	{atomic,[CPid]} = mnesia:transaction(fun() ->
				qlc:e(qlc:q([C#channels.pid || C <- mnesia:table(channels), C#channels.cnumber =:= Channel]))
		end),

	CPid ! {remove_member,UID,UserName}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Channel server: This channel sends the messages appearing in a channel to all users in this channel.
chanproc(Number,Members) ->
	io:format("~p~n",[Members]),

	receive
		{mesg,Message}      ->
			{atomic,MemberPIDs} = mnesia:transaction(fun() ->
						qlc:e(qlc:q([U#users.pid || U <- mnesia:table(users), lists:member(U#users.uid,Members)]))
				end),
			lists:foreach(fun(Pid) ->
						%% Second element of tuple goes directly to gen_tcp:send() which accepts (deep) iolists
						Pid ! {mesg,[<<Number:64/unsigned-native>>,Message]}
				end,MemberPIDs),
			chanproc(Number,Members);
		{add_member,UID,NewUserName}    ->
			{atomic,MemberPIDs} = mnesia:transaction(fun() ->
						qlc:e(qlc:q([U#users.pid || U <- mnesia:table(users), lists:member(U#users.uid,Members)]))
				end),
			lists:foreach(fun(Pid) ->
						%% Second element of tuple goes directly to gen_tcp:send() which accepts (deep) iolists
						Pid ! {mesg,[<<Number:64/unsigned-native>>,NewUserName," has joined the channel\n"]}
				end,MemberPIDs),
			chanproc(Number,[UID|Members]);
		{remove_member,UID,UserName} ->
			{atomic,MemberPIDs} = mnesia:transaction(fun() ->
						qlc:e(qlc:q([U#users.pid || U <- mnesia:table(users), lists:member(U#users.uid,Members)]))
				end),
			lists:foreach(fun(Pid) ->
						%% Second element of tuple goes directly to gen_tcp:send() which accepts (deep) iolists
						Pid ! {mesg,[<<Number:64/unsigned-native>>,UserName," has left the channel\n"]}
				end,MemberPIDs),
			chanproc(Number,lists:subtract(Members,[UID]))
	end.

parse_message(Message) ->
	{Channel,ActualMessage} = split_binary(Message,8),
	<<ChanNum:64/unsigned-native>> = Channel,
	{ChanNum,binary_to_list(ActualMessage)}.

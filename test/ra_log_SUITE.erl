-module(ra_log_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

%% common ra_log tests to ensure behaviour is equivalent across
%% ra_log backends

all() ->
    [
     {group, ra_log_memory},
     {group, ra_log_file}
    ].

all_tests() ->
    [
     fetch_when_empty,
     fetch_not_found,
     append_then_fetch,
     append_then_overwrite,
     append_integrity_error,
     take,
     last,
     meta,
     snapshot
    ].

groups() ->
    [
     {ra_log_memory, [], all_tests()},
     {ra_log_file, [], [
                        init_close_init,
                        append_recover_then_overwrite,
                        append_overwrite_then_recover
                        | all_tests()]}
    ].

init_per_group(ra_log_memory, Config) ->
    InitFun = fun (_) -> ra_log:init(ra_log_memory, #{}) end,
    [{init_fun, InitFun} | Config];
init_per_group(ra_log_file, Config) ->
    PrivDir = ?config(priv_dir, Config),
    InitFun = fun (TestCase) ->
                Dir = filename:join(PrivDir, TestCase),
                ok = filelib:ensure_dir(Dir),
                ra_log:init(ra_log_file, #{directory => Dir})
              end,
    [{init_fun, InitFun} | Config].

end_per_group(_, Config) ->
    Config.

init_per_testcase(TestCase, Config) ->
    Fun = ?config(init_fun, Config),
    Log = Fun(TestCase),
    [{ra_log, Log} | Config].

fetch_when_empty(Config) ->
    Log = ?config(ra_log, Config),
    {0, 0, undefined} = ra_log:fetch(0, Log),
    ok.

fetch_not_found(Config) ->
    Log = ?config(ra_log, Config),
    undefined = ra_log:fetch(99, Log),
    ok.

append_then_fetch(Config) ->
    Log0 = ?config(ra_log, Config),
    Term = 1,
    Idx = ra_log:next_index(Log0),
    Entry = {Idx, Term, "entry"},
    {ok, Log} = ra_log:append(Entry, no_overwrite, Log0),
    {Idx, Term, "entry"} = ra_log:fetch(Idx, Log),
    ok.

append_then_overwrite(Config) ->
    Log0 = ?config(ra_log, Config),
    Term = 1,
    Idx = ra_log:next_index(Log0),
    Log1 = write_two(Idx, Term, Log0),
    % overwrite Idx
    Entry2 = {Idx, Term, "entry0_2"},
    {ok, Log} = ra_log:append(Entry2, overwrite, Log1),
    {Idx, Term, "entry0_2"} = ra_log:fetch(Idx, Log),
    ExpectedNextIndex = Idx + 1,
    % ensure last index is updated after overwrite
    ExpectedNextIndex = ra_log:next_index(Log),
    ok.

append_recover_then_overwrite(Config) ->
    Log0 = ?config(ra_log, Config),
    InitFun = ?config(init_fun, Config),
    Term = 1,
    Idx = ra_log:next_index(Log0),
    Log1 = write_two(Idx, Term, Log0),
    ok = ra_log:close(Log1),
    Log2 = InitFun(append_recover_then_overwrite),
    % overwrite Idx
    Entry2 = {Idx, Term, "entry0_2"},
    {ok, Log} = ra_log:append(Entry2, overwrite, Log2),
    {Idx, Term, "entry0_2"} = ra_log:fetch(Idx, Log),
    ExpectedNextIndex = Idx+1,
    % ensure last index is updated after overwrite
    ExpectedNextIndex = ra_log:next_index(Log),
    % ensure previous indices aren't accessible
    undefined = ra_log:fetch(Idx+1, Log),
    ok.

append_overwrite_then_recover(Config) ->
    Log0 = ?config(ra_log, Config),
    InitFun = ?config(init_fun, Config),
    Term = 1,
    Idx = ra_log:next_index(Log0),
    Log1 = write_two(Idx, Term, Log0),
    % overwrite Idx
    Entry2 = {Idx, Term, "entry0_2"},
    {ok, Log2} = ra_log:append(Entry2, overwrite, Log1),
    % close log
    ok = ra_log:close(Log2),
    % recover
    Log = InitFun(append_overwrite_then_recover),
    {Idx, Term, "entry0_2"} = ra_log:fetch(Idx, Log),
    ExpectedNextIndex = Idx+1,
    % ensure last index is updated after overwrite
    ExpectedNextIndex = ra_log:next_index(Log),
    % ensure previous indices aren't accessible
    undefined = ra_log:fetch(Idx+1, Log),
    ok.

write_two(Idx, Term, Log0) ->
    Entry0 = {Idx, Term, "entry0"},
    {ok, Log1} = ra_log:append(Entry0, no_overwrite, Log0),
    Entry1 = {ra_log:next_index(Log1), Term, "entry1"},
    {ok, Log2} = ra_log:append(Entry1, no_overwrite, Log1),
    Log2.

append_integrity_error(Config) ->
    % allow "missing entries" but do not allow overwrites
    % unless overwrite flag is set
    Log0 = ?config(ra_log, Config),
    Term = 1,
    {ok, Log1} =
        % this is ok even though entries are missing
        ra_log:append({99, Term, "entry99"}, no_overwrite, Log0),
    % going backwards should fail with integrity error unless
    % we are overwriting
    Entry = {98, Term, "entry98"},
    {error, integrity_error} = ra_log:append(Entry, no_overwrite, Log1),
    {ok, _Log} = ra_log:append(Entry, overwrite, Log1),
    ok.

-define(IDX(T), {T, _, _}).

take(Config) ->
    Log0 = ?config(ra_log, Config),
    Term = 1,
    Idx = ra_log:next_index(Log0),
    Log = lists:foldl(fun (I, L0) ->
                        Entry = {I, Term, "entry" ++ integer_to_list(I)},
                        {ok, L} = ra_log:append(Entry, no_overwrite, L0),
                        L
                      end, Log0, lists:seq(Idx, Idx + 9)),
    [?IDX(1)] = ra_log:take(1, 1, Log),
    [?IDX(1), ?IDX(2)] = ra_log:take(1, 2, Log),
    % partly out of range
    [?IDX(9), ?IDX(10)] = ra_log:take(9, 3, Log),
    % completely out of range
    [] = ra_log:take(11, 3, Log),
    % take all
    Taken = ra_log:take(1, 10, Log),
    ?assertEqual(10, length(Taken)),
    ok.


last(Config) ->
    Log0 = ?config(ra_log, Config),
    Term = 1,
    Idx = ra_log:next_index(Log0),
    Entry = {Idx, Term, "entry"},
    {ok, Log} = ra_log:append(Entry, no_overwrite, Log0),
    {Idx, Term, "entry"} = ra_log:last(Log),
    ok.

meta(Config) ->
    Log0 = ?config(ra_log, Config),
    {ok, Log} = ra_log:write_meta(current_term, 87, Log0),
    87 = ra_log:read_meta(current_term, Log),
    undefined = ra_log:read_meta(missing_key, Log),
    ok.

snapshot(Config) ->
    Log0 = ?config(ra_log, Config),
    % no snapshot yet
    undefined = ra_log:read_snapshot(Log0),
    Log1 = append_in(1, "entry1", Log0),
    Log2 = append_in(1, "entry2", Log1),
    {LastIdx, LastTerm, _} = ra_log:last(Log2),
    Cluster = #{node1 => #{}},
    Snapshot = {LastIdx, LastTerm, Cluster, "entry1+2"},
    Log = ra_log:write_snapshot(Snapshot, Log2),
    % ensure entries prior to snapshot are no longer there
    undefined = ra_log:fetch(LastIdx, Log),
    undefined = ra_log:fetch(LastIdx-1, Log),
    Snapshot = ra_log:read_snapshot(Log),
    ok.


% persistent ra_log implementations only
init_close_init(Config) ->
    InitFun = ?config(init_fun, Config),
    Log0 = ?config(ra_log, Config),
    Log1 = append_in(1, "entry1", Log0),
    Log2 = append_in(2, "entry2", Log1),
    {ok, Log} = ra_log:write_meta(current_term, 2, Log2),
    ok = ra_log:close(Log),
    LogA = InitFun(init_close_init),
    {2, 2, _} = ra_log:last(LogA),
    {2, 2, "entry2"} = ra_log:fetch(2, LogA),
    {1, 1, "entry1"} = ra_log:fetch(1, LogA),
    2 = ra_log:read_meta(current_term, LogA),
    % ensure we can append after recovery
    LogB = append_in(2, "entry3", LogA),
    {1, 1, "entry1"} = ra_log:fetch(1, LogA),
    {3, 2, "entry3"} = ra_log:fetch(3, LogB),
    {2, 2, "entry2"} = ra_log:fetch(2, LogA),
    ok.

append_in(Term, Data, Log0) ->
    Idx = ra_log:next_index(Log0),
    Entry = {Idx, Term, Data},
    {ok, Log} = ra_log:append(Entry, no_overwrite, Log0),
    Log.

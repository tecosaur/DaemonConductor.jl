precompile(Tuple{typeof(try_load_revise)})
precompile(Tuple{typeof(queue_ttl_check)})
precompile(Tuple{typeof(perform_ttl_check), Base.Timer})
precompile(Tuple{typeof(prepare_module), NamedTuple})
precompile(Tuple{typeof(getval), Vector{Pair{String, String}}, String, String})
precompile(Tuple{typeof(runclient), NamedTuple, Base.PipeEndpoint, Base.PipeEndpoint})
precompile(Tuple{typeof(Core.kwcall), NamedTuple{(:signal_exit,), Tuple{Function}}, typeof(runclient), Module, NamedTuple})
precompile(Tuple{typeof(newconnection), Base.PipeEndpoint, Int})
precompile(Tuple{typeof(runworker), String})

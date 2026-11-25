import RecordFieldInfo

HostedFunctionInfo := {
    arg_fields : List(RecordFieldInfo),
    arg_type_ids : List(U64),
    ffi_symbol : Str,
    index : U64,
    name : Str,
    ret_fields : List(RecordFieldInfo),
    ret_type_id : U64,
    ## Declared `suspending`: in a mode with tasks the host function takes
    ## the task and a result pointer and returns a `RocPoll`.
    suspending : Bool,
    type_str : Str,
}

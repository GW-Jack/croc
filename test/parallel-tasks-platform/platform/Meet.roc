Meet := [].{
    ## Block this thread, without suspending, until `count` calls are inside
    ## `all!` at once. False if the others don't come within ten seconds.
    all! : U64 => Bool

    ## How many times a whole group has met.
    rounds! : () => U64
}

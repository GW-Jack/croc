File := [].{
    ## The contents of the file at `path`, read by a worker while the task
    ## pauses. The error says why the file could not be read.
    suspending read_utf8! : Str => Try(Str, [FileErr(Str)])
}

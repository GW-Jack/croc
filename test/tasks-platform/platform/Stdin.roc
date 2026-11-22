Stdin := [].{
    ## The next line of standard input without its newline, or `""` at the end
    ## of input. The task pauses while a worker reads it.
    suspending line! : () => Str
}

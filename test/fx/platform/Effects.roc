## Effectful function values that cross the host boundary both ways.
Effects := [].{
    ## The host's own function: add the number.
    boxed_add! : I64 => Box((I64 => I64))

    ## The host's own function, which calls the given one and adds the number.
    boxed_around! : Box((I64 => I64)), I64 => Box((I64 => I64))

    ## Have the host call the function.
    call! : Box((I64 => I64)), I64 => I64
}

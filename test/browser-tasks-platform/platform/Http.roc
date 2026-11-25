Http := [].{

	## Fetch the text at a URL, pausing the task until it arrives. `Err` has the
	## host's description of what went wrong.
	suspending get! : Str => Try(Str, Str)
}

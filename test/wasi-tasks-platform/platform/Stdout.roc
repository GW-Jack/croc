Stdout := [].{

	## Write one line to standard output, pausing the task until it is written.
	## A line nothing reads is dropped.
	suspending line! : Str => {}
}

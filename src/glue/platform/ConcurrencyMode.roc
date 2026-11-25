## The platform header's `concurrency` mode. A `Tasks` platform's provided
## procedures return tasks, and its suspending hosted functions take the task
## and a result pointer (design.md "Host Contract", "Glue").
ConcurrencyMode := [
	NoConcurrency,
	Tasks,
]

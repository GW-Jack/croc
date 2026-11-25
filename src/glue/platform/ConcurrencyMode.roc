## The platform header's `concurrency` mode. In a mode with tasks, provided
## procedures return tasks, and suspending hosted functions take the task and a
## result pointer (design.md "Host Contract", "Glue").
ConcurrencyMode := [
	NoConcurrency,
	Tasks,
	ParallelTasks,
]

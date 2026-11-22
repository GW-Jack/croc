Scheduler := [].{
    ## Pause the task and let the scheduler resume it at once. No worker is
    ## involved, so the pause costs only the runtime's own work.
    suspending yield! : () => {}
}

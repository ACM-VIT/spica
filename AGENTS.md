# Spica mindset

Think like a game developer building a data-intensive desktop app for low-end hardware.

- Favor compact data, explicit ownership, reusable buffers, bounded working sets, and incremental work.
- Keep history on disk; decode and shape what the user can see. Favor event-driven idle and heavy work off the UI thread.
- Keep application logic portable; isolate OS mechanics behind small platform boundaries. Portable libraries alone do not make a portable app.
- Measure CPU, memory, GPU, and I/O on real workloads, including the pi child process. Optimize measured bottlenecks without losing correctness or source data.
- Prefer simple designs, fast iteration, and a readable UI over abstraction for its own sake.

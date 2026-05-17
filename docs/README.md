# SynCons Documentation

This directory keeps only the current design notes that are useful for reading,
maintaining, and extending the codebase.

Recommended reading order:

1. [protocol_spec.md](./protocol_spec.md)  
   End-to-end protocol model, terminology, and dataplane/control-plane split.
2. [reconfiguration.md](./reconfiguration.md)  
   Recovery triggers, coordinator election, prepare/commit workflow, and
   activation-round cutover.
3. [simulator_architecture.md](./simulator_architecture.md)  
   Package layout and responsibility boundaries across the simulator.

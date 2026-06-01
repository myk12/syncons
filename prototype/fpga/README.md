# Corundum App Root

This directory is the authoritative source for the protocol app that is
currently linked into Corundum as:

`prototype/corundum/fpga/app/consensus -> ../../../fpga`

The goal of this layout is to keep the app implementation under this
repository's own `prototype/` tree while still matching Corundum's expected
`fpga/app/<name>/` structure.

Current contents:

- `rtl/`: protocol RTL and the Corundum app wrapper entrypoint
- `tb/`: standalone RTL testbenches
- `Makefile`: local simulation and bring-up helpers
- `implementation_notes.md`: bring-up and integration notes

At this stage, the Corundum-facing entrypoint is `rtl/mqnic_app_block.v`. The
rest of the app-specific integration can be filled in incrementally without
moving the existing RTL tree.

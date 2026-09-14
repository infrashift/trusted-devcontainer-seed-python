# Your workspace

This directory is a **host volume**, not part of the image. It survives
`make stop` and `make deploy`; everything else in `/home/user` is image-owned
and is reset on every redeploy, by design.

Put work you want to keep here. `make clean` DOES take the volume — the mkdir
plugin names its directory after the volume ID, so a re-created volume is a
different, empty one.

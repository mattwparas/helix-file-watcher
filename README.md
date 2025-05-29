# Helix file watcher plugin

This is a helix plugin made using steel. To install, you can use the `forge` command line tool,
which also requires having a rust toolchain installed.

You can either clone the repo and then from the root run:

`forge install`

Or you can do:

`forge pkg install --git https://github.com/mattwparas/helix-file-watcher.git`.

This will build and install the library.

You should then be able to use the library like so:

```steel
(require "helix-file-watcher/file-watcher.scm")
```

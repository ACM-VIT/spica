# Spica

Native coding app for Linux. Zig 0.16, SDL3, Clay.

```sh
python3 build/bootstrap.py  # first build: fetch pinned dependencies
python3 build/driver.py
zig-out/bin/spica
./tools/check
```

Offline GUI test on a private desktop:

```sh
tools/spica-ui scenario send-restart --output .artifacts/gui/example
```

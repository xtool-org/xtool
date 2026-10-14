# Examples

These primarily exist as fixtures for integration tests, but also double as snippets of sample code.

Each demo is designed to make some assertions shortly after launching, and then exit. On success, stdout will include the message "xtool test succeeded".

## Testing

```
./Examples/test.sh [--build | --run] [DemoName]
```

- Omit `--build`/`--run` to build _and_ run
- Omit the demo name to loop through all demos

## watchOS

`DemoWatch` is a minimal standalone Watch app. `WatchProbe` is an interactive
hardware probe with a persistent counter, haptics, a stopwatch, and an HTTPS check.
These require the experimental [watchOS workflow](../Documentation/xtool.docc/WatchOS.md).
The Watch examples do not participate in the iOS simulator `test.sh` workflow.

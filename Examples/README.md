# Examples

These primarily exist as fixtures for integration tests, but also double as snippets of sample code.

Each demo is designed to make some assertions shortly after launching, and then exit. On success, stdout will include the message "xtool test succeeded".

## Testing

```
./Examples/test.sh [--build | --run] [DemoName]
```

- Omit `--build`/`--run` to build _and_ run
- Omit the demo name to loop through all demos

# Supersign + Linux = <3

Supersign currently uses AppImage to build its Linux CLI. It is possible to build and run the AppImage on a native Linux host, as well as through Docker (natively or through Docker Desktop on macOS).

## Setup

Make sure `usbmuxd` is installed on your host machine. On macOS, `usbmuxd` is preinstalled.

### Using Docker

You can build and run a container with standard Docker Compose commands, for example:
```
docker compose run --rm supersign
``` 
This will spawn a shell inside the container. The Supersign root directory will be bind-mounted at `/Supersign`.

To actually access iOS devices from inside Docker, you'll also need to forward the host's `usbmuxd` to a port which the Docker container's libusbmuxd will connect to. Keep this command running on your host machine:
```
socat -dd TCP-LISTEN:27015,range=127.0.0.1/32,reuseaddr,fork UNIX-CLIENT:/var/run/usbmuxd
```

## Building

Simply run `./build.sh` in this directory. This will output an AppImage to `packages/Supersign.AppImage`, which can directly be invoked.

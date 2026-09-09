# Local rclone WebDAV Launcher

A small interactive Bash launcher for serving an existing [rclone](https://rclone.org/) remote through a **local-only WebDAV endpoint**.

It is intended for workflows where a desktop application expects a local WebDAV server but the files actually live on an rclone-supported remote. The launcher selects an existing rclone remote, starts `rclone serve webdav`, creates an isolated VFS cache, displays transfer status, and provides terminal controls for cache maintenance and safe shutdown.

> [!IMPORTANT]
> This script is designed for Linux systems. It relies on `/proc/meminfo`, GNU `stat`, `setsid`, and `stty` behavior that may not be available or identical on macOS, Windows, or minimal containers.

## Features

- Binds WebDAV to `127.0.0.1:8080` by default, so it is reachable only from the same machine.
- Interactively selects an existing rclone remote and an optional path inside that remote.
- Uses `rclone serve webdav` with `--vfs-cache-mode full` for better compatibility with applications that perform normal file operations.
- Creates a unique temporary VFS cache directory, preferring a RAM-backed `tmpfs` location.
- Sizes the VFS cache to 80% of Linux `MemAvailable` memory, with a 256 MiB minimum.
- Enables rclone's local Remote Control (RC) endpoint at `127.0.0.1:5573` for status and cache commands.
- Displays active-transfer and VFS upload-queue status while the server runs.
- Lets you clear or refresh the VFS directory cache without restarting the server.
- Gracefully waits for uploads and VFS write-back work to drain before stopping.
- Removes the temporary cache directory when the launcher exits.

## Requirements

Install and configure the following before running the script:

| Requirement | Why it is needed |
|---|---|
| Bash | Runs the launcher. |
| [rclone](https://rclone.org/downloads/) | Provides remote access, WebDAV serving, VFS, and RC APIs. |
| `jq` | Parses rclone's JSON status responses and refresh job result. |
| GNU/Linux utilities: `setsid`, `sed`, `stat`, `mktemp`, `awk`, `stty` | Process control, cache-path discovery, temporary directories, memory detection, and keyboard handling. |
| An rclone remote | The script lists remotes already present in your rclone configuration. |

Check the required commands:

```bash
command -v bash rclone jq setsid sed stat mktemp awk stty
```

List your configured rclone remotes:

```bash
rclone listremotes
```

If this is empty, create a remote first:

```bash
rclone config
```

## Installation

Clone the repository or download the script, then make it executable:

```bash
git clone https://github.com/YOUR-ACCOUNT/YOUR-REPOSITORY.git
cd YOUR-REPOSITORY
chmod +x rclone-webdav-local.sh
```

Run it from a terminal with an interactive TTY:

```bash
./rclone-webdav-local.sh
```

Do not run it through a non-interactive scheduler, redirected standard input, or an environment without a working terminal: the remote/path prompts and key controls require terminal input.

## Quick start

1. Start the script:

   ```bash
   ./rclone-webdav-local.sh
   ```

2. Select a number from the displayed rclone remotes.

3. Enter an optional path within the selected remote:

   ```text
   Path within remote (empty = root): projects/active
   ```

   Leave it empty to serve the remote root.

4. Wait until the launcher prints:

   ```text
   Server ready.
   ```

5. Connect a local application to:

   ```text
   http://127.0.0.1:8080/
   ```

6. Leave the terminal running while the application uses WebDAV. Use the controls below to refresh metadata or stop the server.

## Terminal controls

The script changes terminal input handling while it is running. It restores the original terminal settings during cleanup.

| Key | Action | When to use it |
|---|---|---|
| `f` | Clears the VFS **directory cache** using `vfs/forget`. | Use when you want paths to be re-read from the remote only as applications access them. This is usually the lower-cost cache operation. |
| `r` | Starts an asynchronous, recursive VFS directory-cache refresh using `vfs/refresh recursive=true`. | Use when an external process changed many directories on the remote and you want the local WebDAV view proactively updated. This can be expensive for large remotes. |
| `q` | Requests graceful shutdown. The script waits for active transfers and VFS uploads to be idle for two consecutive polls, then sends `SIGTERM` to rclone. | Use this normal exit path to reduce the chance of stopping before write-back uploads complete. |
| `Ctrl+\\` | Immediately force-stops rclone with `SIGKILL`. | Emergency-only option. Pending writes can be interrupted or left incomplete. |
| `Ctrl+C` | Disabled while the launcher is active. | This is intentional: use `q` for normal shutdown or `Ctrl+\\` only when necessary. |

Cache commands are ignored after a graceful shutdown has been requested, so a refresh cannot prolong the shutdown process.

## Configuration defaults

The values below are set near the top of the script and can be edited to match your environment.

| Variable | Default | Meaning |
|---|---:|---|
| `DEFAULT_ADDR` | `127.0.0.1:8080` | WebDAV listener. Keep this loopback-only unless you deliberately intend to expose the service. |
| `DEFAULT_RC_ADDR` | `127.0.0.1:5573` | rclone RC listener used internally by the launcher. |
| `DEFAULT_READ_AHEAD` | `128M` | VFS read-ahead amount for sequential reads. |
| `DEFAULT_DIR_CACHE_TIME` | `9999h` | Directory-cache lifetime. Manual `f` and `r` controls are provided because this is intentionally long. |
| `DEFAULT_VFS_CACHE_MODE` | `full` | Enables full VFS caching. |
| `DEFAULT_RAM_CACHE_ROOT` | `/dev/shm` | First choice for an in-memory cache location. |
| `RAM_PERCENT` | `80` | Portion of `MemAvailable` used for `--vfs-cache-max-size`. |
| `POLL_INTERVAL` | `1` | Seconds between RC status checks. |
| `IDLE_POLLS_REQUIRED` | `2` | Consecutive idle polls needed before graceful shutdown stops rclone. |

### Cache-location selection

The launcher tries the following locations in order:

1. `/dev/shm`
2. `/run/user/<uid>`
3. `/tmp`

It selects the first existing path whose filesystem type is `tmpfs`. If no `tmpfs` candidate exists, it warns and falls back to `/tmp`.

### Memory considerations

`--vfs-cache-max-size` is calculated from Linux `MemAvailable`:

```text
cache size = max(256 MiB, MemAvailable x RAM_PERCENT / 100)
```

The default of 80% is aggressive on a shared workstation or a memory-constrained machine. Consider lowering it, for example:

```bash
RAM_PERCENT=40
```

For a strict fixed budget, replace the dynamic calculation with an explicit value such as:

```bash
CACHE_MAX_SIZE="8G"
CACHE_MAX_SIZE_MIB=8192
```

## What cache refresh does and does not do

The `f` and `r` controls target rclone's **VFS directory cache**.

- They help make externally created, removed, renamed, or moved remote entries visible to WebDAV clients.
- `f` invalidates directory-cache entries. The directory is listed again only when something accesses it.
- `r` proactively traverses and refreshes the directory tree in the background.
- They do not guarantee invalidation of all local file-content cache data, nor do they override an application's own caching behavior.
- A recursive refresh can cause many remote listing/API requests. Use it carefully with very large remotes or services with rate limits.

For rclone RC API details, see [Remote Control](https://rclone.org/rc/).

## Security model

By default, both endpoints bind to loopback addresses:

```text
WebDAV:  http://127.0.0.1:8080/
RC API:  http://127.0.0.1:5573/
```

This means they are not reachable directly from other machines on the network. However:

- Any process running under an appropriate local user context may be able to access an unauthenticated loopback WebDAV endpoint.
- Do not change `DEFAULT_ADDR` or `DEFAULT_RC_ADDR` to `0.0.0.0` or a LAN address unless you understand the exposure and add suitable access controls.
- Treat the terminal and local machine as trusted while the server is running.
- The script does not modify rclone's configuration or transmit credentials itself; rclone uses the remote configuration you have already created.

## Shutdown behavior

When you press `q`, the script checks rclone RC statistics once per second:

- active transfers from `core/stats`
- queued VFS uploads from `vfs/stats`
- VFS uploads in progress from `vfs/stats`

When all three values are zero for `IDLE_POLLS_REQUIRED` consecutive polls, the launcher sends `SIGTERM` to rclone's process group. It then removes its temporary cache directory.

This improves safety compared with stopping immediately, but it is not a transactional guarantee for every remote or client. Before terminating the terminal or rebooting, wait for the script to report `Done.`.

## Logs and troubleshooting

While running, rclone's standard output and error are stored at:

```text
<TMP_CACHE_DIR>/rclone-serve.log
```

The launcher prints the exact path at startup. Its cache directory is intentionally deleted during normal cleanup, so copy the log elsewhere before exiting if you need it for troubleshooting.

Common checks:

```bash
# Confirm the WebDAV server is listening locally.
ss -ltn | grep ':8080'

# Inspect the rclone RC endpoint while the launcher is running.
rclone rc --rc-addr 127.0.0.1:5573 core/stats
rclone rc --rc-addr 127.0.0.1:5573 vfs/stats

# Check the selected remote independently.
rclone lsd REMOTE:
```

### No configured remotes found

Run:

```bash
rclone config
```

Then restart the launcher.

### The server exits during startup

Copy or inspect the displayed `rclone-serve.log` path before the launcher cleans up. Typical causes include an unreachable remote, expired authentication, an invalid rclone configuration, or another service already using port 8080 or 5573.

### Port already in use

Identify the process:

```bash
ss -ltnp | grep -E ':(8080|5573)'
```

Stop the conflicting service or change `DEFAULT_ADDR` / `DEFAULT_RC_ADDR` in the script.

### Remote changes are not visible

- Press `f` if the affected path can be reloaded on demand.
- Press `r` if you need to proactively refresh the full directory tree.
- Consider reducing `DEFAULT_DIR_CACHE_TIME` if external changes are frequent.

### High RAM use or system pressure

Lower `RAM_PERCENT`, choose a disk-backed cache location, or set a fixed `CACHE_MAX_SIZE`. Remember that full VFS cache mode and read-ahead can both increase local resource use.

## rclone command used

After choosing a remote and optional path, the script starts a command equivalent to:

```bash
setsid rclone serve webdav "REMOTE:optional/path" \
  --addr "127.0.0.1:8080" \
  --rc \
  --rc-addr "127.0.0.1:5573" \
  --vfs-cache-mode "full" \
  --cache-dir "<temporary-cache-dir>" \
  --vfs-cache-max-size "<calculated-size>" \
  --links \
  --vfs-read-ahead "128M" \
  --dir-cache-time "9999h"
```

The exact selected remote, subpath, cache location, and calculated cache maximum are printed at startup.

## Limitations

- Linux-focused; not currently portable to all Unix-like platforms.
- Requires an interactive terminal.
- Recursive refresh may be slow or costly for large directory trees.
- A long directory-cache lifetime means remote changes are not automatically discovered promptly without `f`, `r`, or a restart.
- The temporary rclone log is removed with the temporary cache directory during cleanup.
- The script assumes one rclone VFS instance is served by its RC endpoint.

## License

Add a license appropriate for your repository, for example MIT, Apache-2.0, or GPL-3.0-only. If this project already has a license, replace this section with its name and link.

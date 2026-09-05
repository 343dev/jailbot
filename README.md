<div align="center">
<img width="320" height="235" alt="Jailbot as Jailpup" src="./assets/jailpup.jpg">

# Jailbot 2.0

**Run commands in a Docker Linux environment without writing mount flags by hand.**

</div>

Jailbot detects existing host paths in command arguments, mounts them into the
container, and rewrites the arguments to their container paths.

```bash
# Instead of planning multiple docker run -v arguments:
docker run --rm \
  -v "$PWD:/workspace/project" \
  -v "$HOME/data:/workspace/data" \
  mydev:latest python3 /workspace/project/process.py /workspace/data/input.csv

# Pass the host paths directly:
jailbot -- python3 ./process.py ~/data/input.csv
```

## Features

- Automatically mounts existing file and directory arguments
- Supports absolute, relative, and `~/` paths
- Mounts a project directly at `/workspace` with `--workdir`
- Optionally mounts Git configuration and forwards the SSH agent
- Passes custom network configuration to Docker
- Supports a persistent volume for the container user's home directory
- Preserves command exit statuses and forwards interruption signals
- Runs quietly by default and keeps diagnostics on `stderr`
- Uses a POSIX-compatible shell

## Quick start

### 1. Install Jailbot

```bash
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/jailbot \
  https://raw.githubusercontent.com/343dev/jailbot/main/jailbot.sh
chmod +x ~/.local/bin/jailbot
```

Ensure `~/.local/bin` is in your `PATH`.

For a system-wide installation, download the script to
`/usr/local/bin/jailbot` instead and make it executable.

### 2. Prepare a Docker image

The image must contain a non-root user named `jailbot`. This repository includes
an example development image:

```bash
docker build -t mydev:latest docker-example
```

See [`docker-example/Dockerfile`](./docker-example/Dockerfile) when adapting
your own image.

### 3. Configure and run

```bash
export JAILBOT_IMAGE_NAME="mydev:latest"

# Start the image's default shell with the current directory at /workspace
jailbot --workdir=. -- bash
```

Add the export to `~/.bashrc`, `~/.zshrc`, or the appropriate shell
configuration file to keep it between sessions.

## Usage

```text
jailbot [OPTIONS] [--] [COMMAND...]
```

Options before `--` belong to Jailbot. Everything after `--` is the command and
arguments for the container. If no command is provided, Jailbot runs the
image's entrypoint or default command.

### Options

| Option                             | Description                                           |
| ---------------------------------- | ----------------------------------------------------- |
| `-h`, `--help`                     | Show help without requiring Docker configuration      |
| `--version`                        | Print the Jailbot version                             |
| `--verbose`                        | Write mount and Docker diagnostics to `stderr`        |
| `--git`                            | Mount the host's Git configuration files read-only    |
| `--ssh`                            | Forward the host SSH agent; fail if it is unavailable |
| `--network NAME`, `--network=NAME` | Pass a non-empty network name to `docker run`         |
| `--workdir PATH`, `--workdir=PATH` | Mount an existing host directory at `/workspace`      |

### Examples

```bash
# Start an interactive shell
jailbot -- bash

# Run a command with the current project mounted at /workspace
jailbot --workdir=. -- make test

# Mount and translate an individual file argument
jailbot -- cat ./data.txt

# Use files from different host directories
jailbot -- python3 ./process.py ~/data/input.csv

# Use host Git configuration
jailbot --git -- git status

# Use host Git configuration and SSH credentials
jailbot --git --ssh -- git push

# Access services through the host network
jailbot --network=host -- curl http://localhost:8080

# Pass a container-side system path without mounting it
jailbot -- cat \\/proc/cpuinfo
```

Run `jailbot --help` for the terminal-accessible command reference.

## Configuration

| Variable                         | Required | Description                              | Default   |
| -------------------------------- | -------- | ---------------------------------------- | --------- |
| `JAILBOT_IMAGE_NAME`             | Yes      | Name of an existing local Docker image   | —         |
| `JAILBOT_CONTAINER_VOLUME`       | No       | Docker volume mounted at `/home/jailbot` | None      |
| `JAILBOT_CONTAINER_NAME_PREFIX`  | No       | Prefix for generated container names     | `jailbot` |
| `JAILBOT_DOCKER_TIMEOUT_SECONDS` | No       | Positive timeout for Docker checks       | `10`      |

Jailbot validates the Docker daemon and configured image before each run. It
never pulls an image automatically; build or pull the image explicitly first.

### Persistent container home

Without `JAILBOT_CONTAINER_VOLUME`, each container starts with the home
directory from the image. Set a named volume to preserve shell history,
dotfiles, installed tools, and package-manager caches:

```bash
docker volume create jailbot_home
export JAILBOT_CONTAINER_VOLUME="jailbot_home"
```

The volume is mounted at `/home/jailbot`. Removing it permanently deletes the
state stored there.

## How path mounting works

Jailbot examines each argument after `--`. When an argument identifies an
existing host path, Jailbot adds a bind mount and replaces the argument with the
corresponding container path.

- **File:** mounts its parent directory at `/workspace/<parent-name>`
- **Directory:** mounts it at `/workspace/<directory-name>`
- **`--workdir`:** mounts the selected directory directly at `/workspace`
- **Repeated path:** reuses the existing mount
- **Conflicting target:** fails before starting Docker

For example, if `/home/alice/project/config.json` exists:

```bash
jailbot -- cat /home/alice/project/config.json
```

Jailbot mounts `/home/alice/project` at `/workspace/project` and passes
`/workspace/project/config.json` to `cat`.

Only existing host paths are mounted automatically. Ordinary values, URLs, and
other non-path arguments are passed through unchanged.

### Passing container-side paths

Prefix an argument with a backslash when it should remain a container-side path
instead of being considered for mounting. In an ordinary shell invocation, use
two backslashes so one reaches Jailbot:

```bash
jailbot -- curl -o \\/dev/null https://example.com
jailbot -- cat \\~/container-only-file
```

The first backslash is removed before the argument is passed to the container.
An escaped `~/` path is translated relative to `/home/jailbot`.

Arguments retain their order and values, including empty strings, spaces,
wildcards, and backslashes. Literal newlines in arguments are rejected. Paths
containing commas or newlines cannot be represented safely by the automatic
mount format and are also rejected before Docker starts.

## Git and SSH

`--git` mounts these host files read-only when they exist:

- `~/.gitconfig` → `/home/jailbot/.gitconfig`
- `~/.config/git/ignore` → `/home/jailbot/.config/git/ignore`

`--ssh` mounts the host agent at `/ssh-auth.sock` and sets `SSH_AUTH_SOCK` in
the container. On Linux, Jailbot uses the host's `$SSH_AUTH_SOCK`; on macOS, it
uses Docker Desktop's host-services socket. Because SSH forwarding is explicitly
requested, Jailbot exits before contacting Docker if the required Linux socket
is unavailable.

Jailbot forwards the agent only. It does not copy private keys into the
container.

## Runtime behavior

- Successful startup is quiet unless `--verbose` is enabled.
- Container output remains on `stdout`; Jailbot warnings and diagnostics use
  `stderr`.
- The `docker run` status is returned unchanged, including a container command's
  non-zero status.
- `SIGINT` and `SIGTERM` are forwarded to Docker. Conventional interrupted
  statuses are `130` and `143`.
- Containers use `--rm`, and temporary mount-planning state is cleaned up on
  exit.
- Interactive input and TTY allocation are selected from the current standard
  input.
- The host timezone is passed to the container when it can be detected.
- `TERM_PROGRAM` and `TERM_PROGRAM_VERSION` are forwarded when set on the host.

## Troubleshooting

For bug reports, include the operating system, Docker version, shell, minimal
reproduction steps, and `--verbose` diagnostics. Do not include credentials or
other secrets.

### Docker is unavailable

Check that Docker is installed, the daemon is running, and the current user can
access it:

```bash
docker version
docker info
```

On Linux, socket permission errors commonly require adding the user to the
Docker group or correcting the selected Docker context.

### The configured image is missing

Jailbot only uses local images:

```bash
echo "$JAILBOT_IMAGE_NAME"
docker image inspect "$JAILBOT_IMAGE_NAME"
docker build -t mydev:latest docker-example
```

### A path is not mounted

Automatic mounting applies only to existing paths passed as separate arguments
after `--`. Use `--verbose` to inspect the mount plan:

```bash
jailbot --verbose -- cat ./data.txt
```

Use `--workdir=.` when the command needs access to an entire project rather than
a few explicit path arguments.

### A mounted path is not accessible

Bind mounts retain host ownership and permissions. The container runs as the
non-root `jailbot` user, so that user must be able to read or write the path as
required.

```bash
ls -ld ./mydir
ls -l ./myfile.txt
```

### SSH forwarding fails

On Linux, verify that an agent is running and its socket is available:

```bash
echo "$SSH_AUTH_SOCK"
ssh-add -l
jailbot --ssh -- ssh-add -l
```

On macOS, SSH forwarding requires Docker Desktop's host-services socket.

## Requirements

- Docker 20.10 or newer is recommended
- A POSIX-compatible shell
- `realpath` is optional and used when available for path resolution

## Contributing

Contributions and bug reports are welcome at
[github.com/343dev/jailbot](https://github.com/343dev/jailbot).

The script is intended to remain POSIX-compatible. Run the test suite before
submitting changes:

```bash
./test_jailbot.sh
```

## License

This script is provided as-is for personal and commercial use. You may modify
and distribute it.

## Other projects

- 🖼 [optimizt](https://github.com/343dev/optimizt) — CLI tool for image optimization: compresses PNG, JPEG, GIF, SVG, and creates AVIF/WebP
- 📦 [harold](https://github.com/343dev/harold) — CLI tool that compares frontend project bundle sizes between snapshots
- 📝 [markdown-lint](https://github.com/343dev/markdown-lint) — Markdown code style linter based on Prettier, Remark, and Typograf
- 🔤 [languagetool-node](https://github.com/343dev/languagetool-node) — CLI spell and grammar checker powered by LanguageTool

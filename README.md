<div align="center">
<img width="320" height="235" alt="Jailbot as Jailpup" src="./assets/jailpup.jpg">

# Jailbot 2.0

</div>

**A Docker Linux container wrapper with automatic filesystem path mounting**

Jailbot seamlessly bridges your host filesystem and containerized Linux environment, automatically detecting and mounting paths without manual `-v` flags.

> 💡 **Fun fact:** Named after [Jailbot from the animated series Superjail!](https://superjail.fandom.com/wiki/Jailbot) — a robot that captures and transports people. This script similarly "transports" your files into Docker containers.

## Rationale

### The Problem

Working with Docker containers often requires manually mounting paths with `-v` or `--mount` flags:

```bash
# Without jailbot - verbose and error-prone
docker run -v /home/user/project:/workspace \
           -v /home/user/config.json:/workspace/config.json \
           -v ~/.gitconfig:/root/.gitconfig:ro \
           my-image ./script.sh config.json
```

This becomes tedious when:
- Working with multiple files from different directories
- Switching between projects frequently
- Running quick one-off commands
- Teaching Docker to newcomers

### The Solution

Jailbot automatically detects paths in your arguments and mounts them transparently:

```bash
# With jailbot - simple and intuitive
jailbot --git -- ./script.sh ~/config.json
```

No manual mounting, no path translation — just run commands naturally as if the container were your local shell.

## Features

- **Automatic Path Detection** — Recognizes file and directory arguments automatically
- **Smart Mounting** — Mounts parent directories for files, full directories for folders
- **Path Translation** — Translates host paths to container paths transparently
- **Git Integration** — Optional mounting of `.gitconfig` and global git ignore
- **Tilde Expansion** — Supports `~/path` notation
- **Relative Paths** — Handles `./` and `../` paths correctly
- **Timezone Sync** — Automatically syncs host timezone to container
- **Interactive Detection** — Smart TTY detection for interactive shells
- **Duplicate Prevention** — Avoids mounting the same path multiple times
- **Escaped Paths** — Prefix path with `\` to pass it without mounting (e.g., `\\/dev/null`)
- **POSIX Compliant** — Works on Linux, macOS, and BSD systems

## Requirements

- **Docker** — Version 20.10+ recommended
- **POSIX Shell** — `sh`, `bash`, `dash`, or `zsh`
- **Unix-like OS** — Linux, macOS, BSD, or WSL2

Optional utilities (automatically detected):
- `realpath` — For better path resolution (usually preinstalled on Linux)

## Installation

### 1. Download the Script

```bash
# Download to /usr/local/bin (system-wide)
sudo curl -o /usr/local/bin/jailbot \
  https://raw.githubusercontent.com/343dev/jailbot/main/jailbot.sh
sudo chmod +x /usr/local/bin/jailbot

# Or download to ~/bin (user-specific)
mkdir -p ~/bin
curl -o ~/bin/jailbot \
  https://raw.githubusercontent.com/343dev/jailbot/main/jailbot.sh
chmod +x ~/bin/jailbot
```

### 2. Prepare Your Docker Environment

Create your Docker image:

```dockerfile
# Example: Dockerfile
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y \
    git curl vim nano python3 nodejs npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
```

```bash
# Build image
docker build -t mydev:latest .
```

**Optional: Create persistent volume for /root**

If you want to preserve installed tools and configurations between runs:

```bash
# Create persistent volume
docker volume create mydev_root

# You'll set JAILBOT_CONTAINER_VOLUME=mydev_root in the next step
```

Skip this if you prefer ephemeral containers that start fresh each time.

### 3. Configure Environment Variables

Add to your shell configuration (`~/.bashrc`, `~/.zshrc`, etc.):

**Minimal setup (ephemeral containers):**

```bash
# Required: Docker image name
export JAILBOT_IMAGE_NAME="mydev:latest"

# Optional: Create alias for convenience
alias dev="jailbot"
```

**Full setup (persistent /root directory):**

```bash
# Required: Docker image name
export JAILBOT_IMAGE_NAME="mydev:latest"

# Optional: Volume name for /root persistence
export JAILBOT_CONTAINER_VOLUME="mydev_root"

# Optional: Create alias for convenience
alias dev="jailbot"
```

Reload your shell:

```bash
source ~/.bashrc  # or source ~/.zshrc
```

## Configuration

### Environment Variables

#### Required

| Variable | Description | Example |
|----------|-------------|---------|
| `JAILBOT_IMAGE_NAME` | Docker image to use | `debian:trixie-slim` |

#### Optional

| Variable | Description | Example | Default |
|----------|-------------|---------|---------|
| `JAILBOT_CONTAINER_VOLUME` | Volume to mount at `/root` for persistence | `jailbot_root` | _(none)_ |

### Understanding Persistent Storage

The `JAILBOT_CONTAINER_VOLUME` variable controls whether the container's `/root` directory persists between runs.

**Without a volume (ephemeral mode):**
- Container starts fresh every time
- No state is preserved between runs
- Useful for one-off tasks, CI/CD, or testing
- All installed packages and configs are lost on exit

**With a volume (persistent mode):**
- Container's `/root` directory is preserved
- Installed tools, packages, and configurations persist
- Shell history, dotfiles, and cached data remain available
- Essential for development workflows

**Common use cases for persistent storage:**

| Use Case | Why You Need It |
|----------|----------------|
| **Node.js with fnm** | Install Node.js versions once, use them across sessions |
| **Global npm packages** | `npm install -g` packages persist (typescript, eslint, etc.) |
| **Development tools** | Vim/Neovim plugins, tmux configurations |
| **Shell customization** | .bashrc, .zshrc, command history |
| **Package manager caches** | pip cache, npm cache, apt cache |

**Example: Setting up Node.js with fnm**

```bash
# Create persistent volume
docker volume create jailbot_root

# Configure environment
export JAILBOT_CONTAINER_VOLUME="jailbot_root"

# Install fnm (Fast Node Manager) - this persists!
jailbot -- bash -c "curl -fsSL https://fnm.vercel.app/install | bash"

# Install Node.js - also persists!
jailbot -- bash -c "source ~/.bashrc && fnm install 20 && fnm use 20"

# Now Node.js is available in all future sessions
jailbot -- node --version  # Works every time!
```

### Command-Line Options

| Option | Description |
|--------|-------------|
| `--verbose` | Enable detailed logging |
| `--git` | Mount Git configuration files (readonly) |
| `--workdir=PATH` | Mount directory directly into `/workspace` |
| `--help` | Show help message |

### Syntax

```bash
jailbot [OPTIONS] [--] [COMMAND...]
```

Use `--` to separate jailbot options from the container command:
- **Everything before `--`** — Jailbot options (`--verbose`, `--git`, `--workdir`)
- **Everything after `--`** — Command and arguments to run inside container

**Example:**
```bash
# Options for jailbot, then command for container
jailbot --verbose --git -- git status
```

## Usage

### Basic Examples

```bash
# Run a local script
jailbot -- ./myscript.sh

# Process a local file
jailbot -- cat ./data.txt

# Work with multiple files
jailbot -- python3 ./process.py ./input.csv ./output.json

# Use files from different directories
jailbot -- node ~/projects/app.js ~/config/settings.json
```

### Interactive Shell

```bash
# Start an interactive shell
jailbot -- bash

# Start shell in a specific directory
jailbot --workdir=./myproject -- bash

# Start shell with Git configured
jailbot --git -- bash
```

### Git Operations

```bash
# Mount git config and run git commands
jailbot --git -- git status
jailbot --git -- git commit -m "Update"
jailbot --git -- git push
```

### Working with Directories

```bash
# Mount current directory and list files
jailbot --workdir=. -- ls -la

# Run make in a project directory
jailbot --workdir=./myproject -- make build

# Run npm commands
jailbot --workdir=~/webapp -- npm install
jailbot --workdir=~/webapp -- npm test
```

### Debugging

```bash
# See what's being mounted
jailbot --verbose -- ./script.sh ./data.txt

# Verbose output with Git config
jailbot --verbose --git -- git status
```

### System Paths

```bash
# Pass system paths without mounting (use backslash prefix)
jailbot -- curl -o \\/dev/null http://example.com
jailbot -- cat \\/proc/cpuinfo
```

## Advanced Examples

### Complex Development Workflow

```bash
# Process data from multiple sources
jailbot -- python3 ./analyze.py \
  ~/data/2024/sales.csv \
  ~/data/2024/inventory.json \
  /tmp/output/report.pdf

# All paths are automatically mounted!
```

### Build Pipeline

```bash
# Build a C++ project
jailbot --workdir=./myproject -- bash -c "
  cmake -B build &&
  cmake --build build &&
  ctest --test-dir build
"
```

### Data Processing Pipeline

```bash
# Chain multiple commands
jailbot --workdir=./data -- bash -c "
  python3 extract.py raw.csv > processed.csv &&
  python3 analyze.py processed.csv > results.json &&
  cat results.json
"
```

### Testing Across Environments

```bash
# Test Python script in containerized environment
jailbot -- python3 -m pytest ./tests/

# Run linting
jailbot -- pylint ./src/*.py

# Check types
jailbot -- mypy ./src/
```

### Node.js Development with Persistent Environment

**Setting up Node.js with fnm (Fast Node Manager):**

```bash
# First, ensure you have persistent volume configured
export JAILBOT_CONTAINER_VOLUME="jailbot_root"

# Install fnm (one-time setup)
jailbot -- bash -c "curl -fsSL https://fnm.vercel.app/install | bash"

# Install Node.js versions (persists across sessions)
jailbot -- bash -c "source ~/.bashrc && fnm install 20 && fnm default 20"
jailbot -- bash -c "source ~/.bashrc && fnm install 18"

# Use Node.js
jailbot --workdir=./my-app -- bash -c "source ~/.bashrc && npm install"
jailbot --workdir=./my-app -- bash -c "source ~/.bashrc && npm run build"
jailbot --workdir=./my-app -- bash -c "source ~/.bashrc && npm test"

# Switch Node.js versions easily
jailbot -- bash -c "source ~/.bashrc && fnm use 18 && node --version"
```

**Install global npm packages (with persistence):**

```bash
# Install global tools (one-time setup)
jailbot -- bash -c "source ~/.bashrc && npm install -g typescript eslint prettier"

# Use them in your projects
jailbot --workdir=./my-project -- bash -c "source ~/.bashrc && tsc --init"
jailbot --workdir=./my-project -- bash -c "source ~/.bashrc && eslint src/"
```

## How It Works

### Path Detection

Jailbot identifies path arguments by checking if they exist as files or directories on the host filesystem.

**Supported path formats:**
- `./relative/path` — Relative paths
- `../parent/path` — Parent directory references
- `~/home/path` — Tilde expansion
- `/absolute/path` — Absolute paths

**Escaped paths (no mounting):**
- `\/path/to/file` — Prefix with `\` to pass path as argument without mounting
- Example: `jailbot -- curl -o \\/dev/null http://example.com`

**Excluded patterns:**
- `http://`, `https://`, `ftp://`, `file://` — URLs (not files)
- `@scope/package` — NPM scoped packages (don't exist as files)
- `/workspace/*` — Container-internal paths

### Mounting Strategy

**For files:**
- Mounts the parent directory
- Translates file path to container location
- Example: `~/docs/file.txt` → mounts `~/docs` to `/workspace/docs`, passes `/workspace/docs/file.txt`

**For directories:**
- Mounts directory directly to `/workspace/<basename>`
- Example: `~/projects/app` → mounts to `/workspace/app`

### Mount Deduplication

- Tracks mounted paths to avoid duplicates
- Uses temporary file for state management
- Cleans up automatically on exit

### Git Configuration

With `--git` flag, mounts (readonly):
- `~/.gitconfig` → `/root/.gitconfig`
- `~/.config/git/ignore` → `/root/.config/git/ignore`

## Troubleshooting

### Script fails with "Docker not found"

**Problem:** Docker is not installed or not in PATH.

**Solution:**
```bash
# Check Docker installation
which docker
docker --version

# Install Docker if needed
# See: https://docs.docker.com/get-docker/
```

### Script fails with "Docker daemon not accessible"

**Problem:** Docker daemon is not running or requires permissions.

**Solution:**
```bash
# Start Docker daemon (Linux)
sudo systemctl start docker

# Add user to docker group (Linux)
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker ps
```

### Script fails with "Image not found"

**Problem:** Environment variable `JAILBOT_IMAGE_NAME` points to non-existent image.

**Solution:**

```bash
# Check your image name
echo $JAILBOT_IMAGE_NAME

# List available images
docker images

# Pull or build the image
docker pull debian:trixie-slim
# or
docker build -t myimage:latest .

# Update environment variable
export JAILBOT_IMAGE_NAME="myimage:latest"
```

### Paths not mounting correctly

**Problem:** Paths aren't being detected or mounted.

**Solution:**
```bash
# Use --verbose to see what's happening
jailbot --verbose -- ./myscript.sh ./data.txt

# Check if path exists
ls -la ./myscript.sh

# Try absolute path
jailbot --verbose -- "$(pwd)/myscript.sh"
```

### Container can't find files

**Problem:** Files appear to exist but container reports "file not found".

**Solution:**
```bash
# Verify you're passing the path as argument
jailbot -- ls -la ./myfile.txt  # ✅ Correct

# Use --workdir for current directory access
jailbot --workdir=. -- ls -la   # ✅ Mounts current directory
```

### Permission denied errors

**Problem:** Container can't write to mounted paths.

**Solution:**
```bash
# Check host file permissions
ls -la ./myfile.txt

# Note: Mounted paths are writable by default
# The container runs as root, so host permissions matter

# Make file writable
chmod 644 ./myfile.txt

# For directories
chmod 755 ./mydir
```

### Git commands don't work

**Problem:** Git inside container can't find configuration.

**Solution:**

```bash
# Use --git flag
jailbot --git -- git status

# Verify git config exists on host
ls -la ~/.gitconfig

# Check if Git is installed in container
jailbot -- which git
```

## License

This script is provided as-is for personal and commercial use. Feel free to modify and distribute.

## Contributing

Contributions, issues, and feature requests are welcome! The script is designed to be POSIX-compliant and should work across different Unix-like systems.

### Reporting Issues

When reporting issues, please include:
- Your operating system and version
- Docker version (`docker --version`)
- Shell type (`echo $SHELL`)
- Output with `--verbose` flag
- Minimal reproduction steps

---

Made with 🤖 for seamless Docker workflows.

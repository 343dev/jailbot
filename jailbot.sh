#!/bin/sh
# Docker Linux container wrapper with automatic path mounting
# Provides seamless integration between host filesystem and containerized Linux environment

set -e
set -u

# Configuration (from environment variables)
readonly VERSION="2.0.0"
readonly IMAGE_NAME="${JAILBOT_IMAGE_NAME:-}"
readonly CONTAINER_USER="jailbot"
readonly CONTAINER_HOME="/home/${CONTAINER_USER}"
CONTAINER_VOLUME="${JAILBOT_CONTAINER_VOLUME:-}"
if [ -n "$CONTAINER_VOLUME" ]; then
  CONTAINER_VOLUME="${CONTAINER_VOLUME}:${CONTAINER_HOME}"
fi
readonly CONTAINER_VOLUME
readonly CONTAINER_NAME_PREFIX="${JAILBOT_CONTAINER_NAME_PREFIX:-jailbot}"

# Validate required environment variables
validate_env() {
  if [ -z "$IMAGE_NAME" ]; then
    log_error "JAILBOT_IMAGE_NAME environment variable is not set"
  fi

}
readonly CONTAINER_WORKDIR="/workspace"

# Runtime state (POSIX-compatible)
VERBOSE=false
MOUNT_GIT=false
MOUNT_SSH=false

# Use newline-delimited in-memory lists so paths with spaces stay intact.
# Note: paths containing literal newlines are not supported.
NL='
'
MOUNT_SPECS_NL=""
MOUNT_RECORDS_DIR=""
MOUNT_RECORDS_COUNT=0
CONTAINER_ARGS_DIR=""
CONTAINER_ARGS_COUNT=0
DOCKER_NETWORK=""
DOCKER_PID=""
FORWARDED_SIGNAL=""

# ============================================================================
# SECTION 1: UTILITY FUNCTIONS
# ============================================================================

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    printf "[VERBOSE] %s\n" "$*" >&2
  fi
}

log_warning() {
  printf "[WARNING] %s\n" "$*" >&2
}

log_error() {
  printf "[ERROR] %s\n" "$*" >&2
  exit 1
}

# ============================================================================
# SECTION 2: DOCKER VALIDATION
# ============================================================================

validate_docker() {
  log_verbose "Validating Docker environment..."

  # Check Docker binary exists
  if ! command -v docker >/dev/null 2>&1; then
    log_error "Docker not found. Please install Docker."
  fi

  # Check Docker daemon is accessible
  if ! docker info >/dev/null 2>&1; then
    log_error "Docker daemon not accessible. Is Docker running?"
  fi

  # Check image exists
  log_verbose "Checking image: $IMAGE_NAME"
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    log_error "Docker image $IMAGE_NAME not found locally. Please build it first."
  fi

  log_verbose "Docker validation passed"
}

# ============================================================================
# SECTION 3: CLEANUP & SIGNAL HANDLING
# ============================================================================

cleanup() {
  if [ -n "$CONTAINER_ARGS_DIR" ]; then
    rm -rf "$CONTAINER_ARGS_DIR" || true
  fi
  if [ -n "$MOUNT_RECORDS_DIR" ]; then
    rm -rf "$MOUNT_RECORDS_DIR" || true
  fi
}

forward_signal() {
  signal_name="$1"

  if [ -z "$DOCKER_PID" ]; then
    return
  fi

  if [ -n "$FORWARDED_SIGNAL" ]; then
    log_verbose "Repeated signal received; forcing Docker process to stop"
    kill -KILL "$DOCKER_PID" 2>/dev/null || true
    return
  fi

  FORWARDED_SIGNAL="$signal_name"
  log_verbose "Forwarding SIG$signal_name to Docker process"
  kill -s "$signal_name" "$DOCKER_PID" 2>/dev/null || true
}

setup_signals() {
  trap cleanup EXIT
  trap 'forward_signal INT' INT
  trap 'forward_signal TERM' TERM
}

# ============================================================================
# SECTION 4: GIT CONFIGURATION
# ============================================================================

mount_git_config() {
  # Mount global gitconfig if exists (read-only)
  if [ -f "${HOME}/.gitconfig" ]; then
    log_verbose "Mounting gitconfig: ${HOME}/.gitconfig"
    add_mount "${HOME}/.gitconfig" "${CONTAINER_HOME}/.gitconfig" "readonly"
  fi

  # Mount global git ignore if exists (read-only)
  if [ -f "${HOME}/.config/git/ignore" ]; then
    # Ensure directory exists in container
    log_verbose "Mounting git ignore: ${HOME}/.config/git/ignore"
    add_mount "${HOME}/.config/git/ignore" "${CONTAINER_HOME}/.config/git/ignore" "readonly"
  fi
}

# ============================================================================
# SECTION 5: PATH PROCESSING
# ============================================================================

get_absolute_path() {
  target="${1:-}"

  # Empty path - return current directory
  if [ -z "$target" ]; then
    pwd
    return
  fi

  # Expand tilde to home directory
  case "$target" in "~"/*)
    # Remove the "~/" prefix and prepend home directory
    target_path="${target#"~/"}"
    target="${HOME}/${target_path}"
    ;;
  esac

  # Already absolute path
  case "$target" in /*)
    printf "%s" "$target"
    return
    ;;
  esac

  # Use realpath if available (Linux), otherwise fallback
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$target" 2>/dev/null || printf "%s/%s" "$(pwd)" "$target"
  else
    # POSIX fallback for macOS
    if [ -e "$target" ]; then
      if [ -d "$target" ]; then
        (cd "$target" && pwd)
      else
        dir="$(dirname "$target")"
        base="$(basename "$target")"
        (cd "$dir" && printf "%s/%s" "$(pwd)" "$base")
      fi
    else
      printf "%s/%s" "$(pwd)" "$target"
    fi
  fi
}

is_path_argument() {
  arg="${1:-}"

  # Reject escaped paths (prefixed with \)
  case "$arg" in
    \\*) return 1 ;;
  esac

  # Reject npm scoped packages (@scope/pkg)
  case "$arg" in
    @*) return 1 ;;
  esac

  # Expand tilde before checking existence
  case "$arg" in
    "~"/*)
      arg="${HOME}${arg#\~}"
      ;;
  esac

  [ -e "$arg" ]
}

# ============================================================================
# SECTION 6: MOUNT MANAGEMENT
# ============================================================================

init_mount_tracking() {
  MOUNT_SPECS_NL=""
  MOUNT_RECORDS_DIR=""
  MOUNT_RECORDS_COUNT=0
  CONTAINER_ARGS_DIR=""
  CONTAINER_ARGS_COUNT=0
  log_verbose "Initialized mount and argument tracking"
}

add_container_arg() {
  value="${1-}"

  case "$value" in
    *"$NL"*)
      log_error "Container arguments containing newlines are not supported"
      ;;
  esac

  if [ -z "$CONTAINER_ARGS_DIR" ]; then
    CONTAINER_ARGS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jailbot-args.XXXXXX")" ||
      log_error "Could not create temporary storage for container arguments"
  fi

  CONTAINER_ARGS_COUNT=$((CONTAINER_ARGS_COUNT + 1))
  arg_file=$(printf '%s/arg.%06d' "$CONTAINER_ARGS_DIR" "$CONTAINER_ARGS_COUNT")
  if ! printf '%s' "$value" > "$arg_file"; then
    log_error "Could not store container argument $CONTAINER_ARGS_COUNT"
  fi
}

read_file_exact() {
  input_file="$1"
  value="$(cat "$input_file"; printf x)"
  printf '%s' "${value%x}"
}

find_mount_by_host() {
  search_path="$1"
  FOUND_MOUNT_TARGET=""
  record_index=1
  while [ "$record_index" -le "$MOUNT_RECORDS_COUNT" ]; do
    host_file=$(printf '%s/host.%06d' "$MOUNT_RECORDS_DIR" "$record_index")
    target_file=$(printf '%s/target.%06d' "$MOUNT_RECORDS_DIR" "$record_index")
    recorded_host=$(read_file_exact "$host_file")
    if [ "$recorded_host" = "$search_path" ]; then
      FOUND_MOUNT_TARGET=$(read_file_exact "$target_file")
      return 0
    fi
    record_index=$((record_index + 1))
  done
  return 1
}

find_mount_by_target() {
  search_target="$1"
  FOUND_MOUNT_HOST=""
  record_index=1
  while [ "$record_index" -le "$MOUNT_RECORDS_COUNT" ]; do
    host_file=$(printf '%s/host.%06d' "$MOUNT_RECORDS_DIR" "$record_index")
    target_file=$(printf '%s/target.%06d' "$MOUNT_RECORDS_DIR" "$record_index")
    recorded_target=$(read_file_exact "$target_file")
    if [ "$recorded_target" = "$search_target" ]; then
      FOUND_MOUNT_HOST=$(read_file_exact "$host_file")
      return 0
    fi
    record_index=$((record_index + 1))
  done
  return 1
}

record_mount() {
  if [ -z "$MOUNT_RECORDS_DIR" ]; then
    MOUNT_RECORDS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jailbot-mounts.XXXXXX")" ||
      log_error "Could not create temporary storage for mount planning"
  fi

  MOUNT_RECORDS_COUNT=$((MOUNT_RECORDS_COUNT + 1))
  host_file=$(printf '%s/host.%06d' "$MOUNT_RECORDS_DIR" "$MOUNT_RECORDS_COUNT")
  target_file=$(printf '%s/target.%06d' "$MOUNT_RECORDS_DIR" "$MOUNT_RECORDS_COUNT")
  if ! printf '%s' "$host_path" > "$host_file" ||
    ! printf '%s' "$container_path" > "$target_file"; then
    log_error "Could not record mount plan for: $host_path"
  fi
}

add_mount() {
  host_path="${1:-}"
  container_path="${2:-}"
  readonly_flag="${3:-}"

  if [ -z "$host_path" ] || [ -z "$container_path" ]; then
    return 1
  fi

  # Skip container workdir paths
  case "$host_path" in
    /workspace*)
      log_verbose "Skipping container workdir path: $host_path"
      return 1
      ;;
  esac

  case "$host_path" in
    *"$NL"*)
      log_error "Cannot automatically mount path containing a newline: $host_path"
      ;;
    *,*)
      log_error "Cannot automatically mount path containing a comma: $host_path"
      ;;
  esac

  case "$container_path" in
    *"$NL"*)
      log_error "Cannot use mount target containing a newline: $container_path"
      ;;
    *,*)
      log_error "Cannot use mount target containing a comma: $container_path"
      ;;
  esac

  if find_mount_by_host "$host_path"; then
    if [ "$FOUND_MOUNT_TARGET" != "$container_path" ]; then
      log_error "Host path already planned for a different mount target: $host_path"
    fi
    log_verbose "Reusing mount: $host_path -> $container_path"
    return 0
  fi

  if find_mount_by_target "$container_path"; then
    log_error "Mount target collision: $container_path is already used by $FOUND_MOUNT_HOST; cannot also mount $host_path"
  fi

  if [ "$readonly_flag" = "readonly" ]; then
    spec="type=bind,source=$host_path,target=$container_path,readonly"
  else
    spec="type=bind,source=$host_path,target=$container_path"
  fi

  if [ -z "$MOUNT_SPECS_NL" ]; then
    MOUNT_SPECS_NL="$spec"
  else
    MOUNT_SPECS_NL="${MOUNT_SPECS_NL}${NL}${spec}"
  fi
  record_mount
  log_verbose "Added mount: $host_path -> $container_path"
  return 0
}

get_container_path() {
  path="${1:-}"
  if [ -z "$path" ]; then
    return 1
  fi
  basename "$path" | sed "s|^|$CONTAINER_WORKDIR/|"
}

# ============================================================================
# SECTION 7: ARGUMENT HANDLING
# ============================================================================

handle_mount_only() {
  mount_path="${1:-}"

  if [ -z "$mount_path" ]; then
    log_error "--workdir requires a non-empty directory path"
  fi

  abs_path="$(get_absolute_path "$mount_path")"

  if [ -z "$abs_path" ]; then
    log_error "Could not resolve workdir path: $mount_path"
  fi

  case "$abs_path" in
    /workspace*)
      log_error "Workdir must be a host directory outside /workspace: $mount_path"
      ;;
  esac

  if [ ! -e "$abs_path" ]; then
    log_error "Workdir does not exist: $abs_path"
  fi

  if [ ! -d "$abs_path" ]; then
    log_error "Workdir must be a directory: $abs_path"
  fi

  if [ ! -r "$abs_path" ] || [ ! -x "$abs_path" ]; then
    log_error "Workdir must be readable and searchable: $abs_path"
  fi

  if ! add_mount "$abs_path" "$CONTAINER_WORKDIR"; then
    log_error "Could not mount workdir: $abs_path"
  fi
}

handle_path_argument() {
  arg="${1-}"

  if [ -z "$arg" ]; then
    add_container_arg ""
    return
  fi

  # Handle escaped paths (prefixed with \) - pass through without mounting
  case "$arg" in
    \\~/*)
      # Expand escaped ~/ inside the container without mounting the host path.
      unescaped_path="${CONTAINER_HOME}${arg#\\~}"
      add_container_arg "$unescaped_path"
      log_verbose "Converted escaped ~/ to ${CONTAINER_HOME}: $unescaped_path"
      return
      ;;
    \\*)
      # Remove the leading backslash and pass as regular argument
      unescaped_path="${arg#\\}"
      add_container_arg "$unescaped_path"
      log_verbose "Escaped path, passing through: $unescaped_path"
      return
      ;;
  esac

  # Check if this is a path argument
  if [ ! -e "$arg" ] && ! is_path_argument "$arg"; then
    # Not a path, treat as regular argument
    add_container_arg "$arg"
    return
  fi

  # If it exists but is_path_argument rejected it, treat as regular arg
  if [ -e "$arg" ] && ! is_path_argument "$arg"; then
    add_container_arg "$arg"
    return
  fi

  abs_path="$(get_absolute_path "$arg")"

  # Skip container workdir paths
  case "$abs_path" in
    /workspace*)
      log_warning "Skipping container workdir path: $arg"
      add_container_arg "$arg"
      return
      ;;
  esac

  # Validate path exists
  if [ ! -e "$abs_path" ]; then
    log_warning "Path does not exist: $abs_path"
    add_container_arg "$arg"
    return
  fi

  if [ -f "$abs_path" ]; then
    # Mount parent directory for files.
    parent_dir="$(dirname "$abs_path")"
    parent_container="$(get_container_path "$parent_dir")"
    add_mount "$parent_dir" "$parent_container"

    file_path="$parent_container/$(basename "$abs_path")"
    add_container_arg "$file_path"
    log_verbose "Mapped file: $abs_path -> $file_path"

  elif [ -d "$abs_path" ]; then
    container_path="$(get_container_path "$abs_path")"
    add_mount "$abs_path" "$container_path"
    add_container_arg "$container_path"
    log_verbose "Mapped directory: $abs_path -> $container_path"
  else
    log_error "Cannot automatically mount unsupported path type: $abs_path"
  fi
}

# ============================================================================
# SECTION 8: EXECUTION
# ============================================================================

validate_requested_modes() {
  if [ "$MOUNT_SSH" != true ]; then
    return
  fi

  if [ "$(uname -s)" = "Darwin" ]; then
    return
  fi

  if [ -z "${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
    log_error "SSH agent forwarding requires an available SSH auth socket; start an SSH agent, set SSH_AUTH_SOCK, or remove --ssh"
  fi
}

detect_interactive_mode() {
  if [ -t 0 ]; then
    printf '%s' "-it"
    log_verbose "Interactive mode detected"
  else
    printf '%s' "-i"
    log_verbose "Non-interactive mode detected (pipe/redirect)"
  fi
}

execute_container() {
  validate_requested_modes
  validate_docker

  # Detect timezone
  TIME_ZONE=""
  if [ -L /etc/localtime ]; then
    TIME_ZONE="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
  elif [ -f /etc/timezone ]; then
    TIME_ZONE="$(cat /etc/timezone)"
  fi

  # Build docker command
  interactive_flags="$(detect_interactive_mode)"

  # Start building command safely
  container_name="${CONTAINER_NAME_PREFIX}_$$"
  log_verbose "Container name: $container_name"
  set -- docker run --rm --name "$container_name"

  # Add interactive flags
  case "$interactive_flags" in
    *-it*) set -- "$@" -it ;;
    *) set -- "$@" -i ;;
  esac

  # Add network configuration if specified
  if [ -n "$DOCKER_NETWORK" ]; then
    set -- "$@" --network "$DOCKER_NETWORK"
  fi

  # Add mounts (evaluated safely)
  if [ -n "$MOUNT_SPECS_NL" ]; then
    while IFS= read -r spec; do
      if [ -z "$spec" ]; then
        continue
      fi
      set -- "$@" --mount "$spec"
    done <<EOF
$MOUNT_SPECS_NL
EOF
  else
    log_verbose "No filesystem paths mounted"
  fi

  # Add SSH agent forwarding if requested
  if [ "$MOUNT_SSH" = true ]; then
    SSH_AUTH_SOCK_HOST=""
    OS_NAME="$(uname -s)"
    if [ "$OS_NAME" = "Darwin" ]; then
      # macOS: Docker Desktop provides a virtual socket path that doesn't
      # exist on the host filesystem but is handled internally by Docker.
      SSH_AUTH_SOCK_HOST="/run/host-services/ssh-auth.sock"
    elif [ -n "${SSH_AUTH_SOCK:-}" ] && [ -e "$SSH_AUTH_SOCK" ]; then
      SSH_AUTH_SOCK_HOST="$SSH_AUTH_SOCK"
    fi

    if [ -n "$SSH_AUTH_SOCK_HOST" ]; then
      log_verbose "Forwarding SSH agent: $SSH_AUTH_SOCK_HOST"
      set -- "$@" --volume "${SSH_AUTH_SOCK_HOST}:/ssh-auth.sock"
      set -- "$@" --env "SSH_AUTH_SOCK=/ssh-auth.sock"
    else
      log_warning "SSH agent forwarding requested but no SSH auth socket found"
    fi
  fi

  # Run as the image's non-root user with its fixed home directory.
  set -- "$@" --user "$CONTAINER_USER"
  set -- "$@" --env "HOME=$CONTAINER_HOME"

  # Add environment and volumes
  if [ -n "$TIME_ZONE" ]; then
    set -- "$@" --env "TZ=$TIME_ZONE"
  fi
  if [ -n "$CONTAINER_VOLUME" ]; then
    set -- "$@" --volume "$CONTAINER_VOLUME"
  fi
  set -- "$@" --workdir "$CONTAINER_WORKDIR"
  set -- "$@" "$IMAGE_NAME"

  log_verbose "Docker command: $*"

  # Everything after the image is the container command and its exact argv.
  if [ "$CONTAINER_ARGS_COUNT" -gt 0 ]; then
    arg_index=1
    while [ "$arg_index" -le "$CONTAINER_ARGS_COUNT" ]; do
      arg_file=$(printf '%s/arg.%06d' "$CONTAINER_ARGS_DIR" "$arg_index")
      # The sentinel preserves empty arguments and trailing newlines through
      # command substitution. Newlines are rejected earlier by policy.
      carg="$(cat "$arg_file"; printf x)"
      carg=${carg%x}
      set -- "$@" "$carg"
      arg_index=$((arg_index + 1))
    done
  fi

  log_verbose "Executing: docker run ..."
  FORWARDED_SIGNAL=""
  "$@" &
  DOCKER_PID=$!

  while :; do
    if wait "$DOCKER_PID"; then
      docker_status=0
      break
    else
      docker_status=$?
    fi

    # A signal can interrupt wait before Docker has exited. Keep waiting after
    # forwarding it so cleanup and the final status reflect the child process.
    if kill -0 "$DOCKER_PID" 2>/dev/null; then
      continue
    fi
    break
  done

  DOCKER_PID=""
  return "$docker_status"
}

# ============================================================================
# SECTION 9: MAIN
# ============================================================================

show_usage() {
  script_name=$(basename "$0")
  cat <<EOF
Usage: ${script_name} [OPTIONS] [--] [COMMAND...]

Docker Linux container wrapper with automatic path mounting.

Examples:
  ${script_name} --workdir=. -- make test
  ${script_name} --git -- git status
  ${script_name} -- cat ./local-file.txt

Options:
  -h, --help         Show this help message and exit
  --version          Show the Jailbot version and exit
  --verbose          Enable verbose diagnostics on stderr
  --git              Mount Git configuration files read-only
  --ssh              Forward the SSH agent socket; fail if unavailable
  --network=NAME     Pass a non-empty network name to docker run
  --network NAME     Pass a network name to docker run
  --workdir=PATH     Mount an existing host directory at /workspace
  --workdir PATH     Mount an existing host directory at /workspace

Invocation:
  Options before -- belong to Jailbot. Everything after -- is the container
  command. The separator is consumed and is not passed after the Docker image.
  Existing host paths after -- are mounted and translated to container paths.
  Mount target collisions and comma/newline paths are rejected before Docker.
  Prefix a path with a backslash to pass it without mounting. Empty arguments
  are preserved; arguments containing literal newlines are rejected.

  With no COMMAND, Jailbot runs the image's entrypoint or default command.

Environment:
  JAILBOT_IMAGE_NAME             Required Docker image name
  JAILBOT_CONTAINER_VOLUME       Optional volume mounted at /home/jailbot
  JAILBOT_CONTAINER_NAME_PREFIX  Optional container name prefix (default: jailbot)

SSH forwarding uses \$SSH_AUTH_SOCK on Linux and Docker Desktop's host socket
on macOS.

Documentation and issues: https://github.com/343dev/jailbot
EOF
}

show_version() {
  printf 'jailbot %s\n' "$VERSION"
}

handle_discovery_options() {
  for arg in "$@"; do
    case "$arg" in
      --)
        break
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
    esac
  done

  for arg in "$@"; do
    case "$arg" in
      --)
        break
        ;;
      --version)
        show_version
        exit 0
        ;;
    esac
  done
}

main() {
  # Discovery commands are side-effect free and do not require configuration.
  handle_discovery_options "$@"

  # Validate required environment variables
  validate_env

  # Setup cleanup and signal handlers
  setup_signals

  # Initialize mount tracking
  init_mount_tracking

  # No arguments - just run container
  if [ $# -eq 0 ]; then
    execute_container
    return
  fi

  # Parse jailbot options (before --)
  SEEN_SEPARATOR=false
  while [ $# -gt 0 ]; do
    arg="${1:-}"

    case "$arg" in
      --)
        SEEN_SEPARATOR=true
        shift
        break
        ;;

      --help|-h)
        show_usage
        exit 0
        ;;

      --version)
        show_version
        exit 0
        ;;

      --verbose)
        VERBOSE=true
        shift
        ;;

      --git)
        MOUNT_GIT=true
        shift
        ;;

      --ssh)
        MOUNT_SSH=true
        shift
        ;;

      --workdir=*)
        mount_path="${arg#--workdir=}"
        handle_mount_only "$mount_path"
        shift
        ;;

      --workdir)
        shift
        if [ $# -eq 0 ] || [ "${1:-}" = "--" ]; then
          log_error "--workdir requires a path argument"
        fi
        handle_mount_only "$1"
        shift
        ;;

      --network=*)
        DOCKER_NETWORK="${arg#--network=}"
        if [ -z "$DOCKER_NETWORK" ]; then
          log_error "--network requires a non-empty network name"
        fi
        shift
        ;;

      --network)
        shift
        if [ $# -eq 0 ] || [ "${1:-}" = "--" ]; then
          log_error "--network requires a network name argument"
        fi
        DOCKER_NETWORK="$1"
        shift
        ;;

      --*)
        printf "[ERROR] Unknown option: %s\n\n" "$arg" >&2
        show_usage >&2
        exit 1
        ;;

      *)
        printf "[ERROR] Unexpected argument before --: %s\n\n" "$arg" >&2
        show_usage >&2
        exit 1
        ;;
    esac
  done

  # Mount git configuration files if requested
  if [ "$MOUNT_GIT" = true ]; then
    mount_git_config
  fi

  # Process container arguments (after --)
  if [ "$SEEN_SEPARATOR" = true ]; then
    while [ $# -gt 0 ]; do
      handle_path_argument "$1"
      shift
    done
  fi

  execute_container
}

# Execute main function
main "$@"

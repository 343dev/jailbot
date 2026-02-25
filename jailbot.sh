#!/bin/sh
# Docker Linux container wrapper with automatic path mounting
# Provides seamless integration between host filesystem and containerized Linux environment

set -e
set -u

# Configuration (from environment variables)
readonly IMAGE_NAME="${JAILBOT_IMAGE_NAME:-}"
CONTAINER_VOLUME="${JAILBOT_CONTAINER_VOLUME:-}"
if [ -n "$CONTAINER_VOLUME" ]; then
  CONTAINER_VOLUME="${CONTAINER_VOLUME}:/root"
fi
readonly CONTAINER_VOLUME

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

# Use newline-delimited in-memory lists so paths with spaces stay intact.
# Note: paths containing literal newlines are not supported.
NL='
'
MOUNTED_HOSTS_NL=""
MOUNT_SPECS_NL=""
CONTAINER_ARGS_NL=""

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
  :
}

setup_signals() {
  trap cleanup EXIT
  trap 'log_error "Interrupted by signal"; exit 130' INT TERM
}

# ============================================================================
# SECTION 4: GIT CONFIGURATION
# ============================================================================

mount_git_config() {
  # Mount global gitconfig if exists (read-only)
  if [ -f "${HOME}/.gitconfig" ]; then
    log_verbose "Mounting gitconfig: ${HOME}/.gitconfig"
    add_mount "${HOME}/.gitconfig" "/root/.gitconfig" "readonly"
  fi

  # Mount global git ignore if exists (read-only)
  if [ -f "${HOME}/.config/git/ignore" ]; then
    # Ensure directory exists in container
    log_verbose "Mounting git ignore: ${HOME}/.config/git/ignore"
    add_mount "${HOME}/.config/git/ignore" "/root/.config/git/ignore" "readonly"
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
  MOUNTED_HOSTS_NL=""
  MOUNT_SPECS_NL=""
  CONTAINER_ARGS_NL=""
  log_verbose "Initialized mount tracking (in-memory)"
}

add_container_arg() {
  value="${1:-}"

  # Empty args are currently ignored by design.
  if [ -z "$value" ]; then
    return 0
  fi

  case "$value" in
    *"$NL"*)
      log_warning "Skipping argument containing newline (unsupported)"
      return 1
      ;;
  esac

  if [ -z "$CONTAINER_ARGS_NL" ]; then
    CONTAINER_ARGS_NL="$value"
  else
    CONTAINER_ARGS_NL="${CONTAINER_ARGS_NL}${NL}${value}"
  fi
}

is_already_mounted() {
  search_path="${1:-}"
  if [ -z "$search_path" ]; then
    return 1
  fi

  if [ -z "$MOUNTED_HOSTS_NL" ]; then
    return 1
  fi

  if grep -Fxq -- "$search_path" <<EOF
$MOUNTED_HOSTS_NL
EOF
  then
    return 0
  fi
  return 1
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

  # Check if already mounted
  if is_already_mounted "$host_path"; then
    log_verbose "Path already mounted: $host_path"
    return 1
  fi

  case "$host_path" in
    *"$NL"*)
      log_warning "Skipping mount with newline in path (unsupported): $host_path"
      return 1
      ;;
  esac

  case "$container_path" in
    *"$NL"*)
      log_warning "Skipping mount with newline in path (unsupported): $host_path"
      return 1
      ;;
  esac

  # Record mount (newline-delimited list)
  if [ -z "$MOUNTED_HOSTS_NL" ]; then
    MOUNTED_HOSTS_NL="$host_path"
  else
    MOUNTED_HOSTS_NL="${MOUNTED_HOSTS_NL}${NL}${host_path}"
  fi

  # Docker's --mount parser uses commas as separators; paths containing commas
  # are not reliably representable.
  case "${host_path}${container_path}" in
    *,*)
      log_warning "Skipping mount (comma in path unsupported by docker --mount): $host_path"
      return 1
      ;;
  esac

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
    log_warning "Empty mount path provided"
    return
  fi

  abs_path="$(get_absolute_path "$mount_path")"

  if [ -z "$abs_path" ]; then
    log_warning "Failed to resolve absolute path for: $mount_path"
    return
  fi

  # Skip container workdir paths
  case "$abs_path" in
    /workspace*)
      log_warning "Cannot mount container workdir path: $mount_path"
      return
      ;;
  esac

  # Validate path exists and is directory
  if [ ! -e "$abs_path" ]; then
    log_warning "Mount-only path does not exist: $abs_path"
    return
  fi

  if [ ! -d "$abs_path" ]; then
    log_warning "Mount-only target must be directory: $abs_path"
    return
  fi

  add_mount "$abs_path" "$CONTAINER_WORKDIR"
}

handle_path_argument() {
  arg="${1:-}"

  if [ -z "$arg" ]; then
    return
  fi

  # Handle escaped paths (prefixed with \) - pass through without mounting
  case "$arg" in
    \\~/*)
      # Convert escaped ~/ to /root/
      unescaped_path="/root${arg#\\\~}"
      add_container_arg "$unescaped_path"
      log_verbose "Converted escaped ~/ to /root: $unescaped_path"
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
    # Mount parent directory for files
    parent_dir="$(dirname "$abs_path")"
    parent_container="$(get_container_path "$parent_dir")"

    add_mount "$parent_dir" "$parent_container" || true

    # Use container path for the file
    file_path="$parent_container/$(basename "$abs_path")"
    add_container_arg "$file_path"
    log_verbose "Mapped file: $abs_path -> $file_path"

  elif [ -d "$abs_path" ]; then
    # Mount directory directly
    container_path="$(get_container_path "$abs_path")"
    if add_mount "$abs_path" "$container_path"; then
      add_container_arg "$container_path"
      log_verbose "Mapped directory: $abs_path -> $container_path"
    else
      add_container_arg "$arg"
    fi
  fi
}

# ============================================================================
# SECTION 8: EXECUTION
# ============================================================================

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
  set -- docker run --rm

  # Add interactive flags
  case "$interactive_flags" in
    *-it*) set -- "$@" -it ;;
    *) set -- "$@" -i ;;
  esac

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

  # Add container arguments if any
  if [ -n "$CONTAINER_ARGS_NL" ]; then
    # Add -- to separate docker options from container command
    set -- "$@" --
    while IFS= read -r carg; do
      if [ -z "$carg" ]; then
        continue
      fi
      set -- "$@" "$carg"
    done <<EOF
$CONTAINER_ARGS_NL
EOF
  fi

  log_verbose "Executing: docker run ..."
  "$@"
}

# ============================================================================
# SECTION 9: MAIN
# ============================================================================

show_usage() {
  script_name=$(basename "$0")
  cat <<EOF
Usage: ${script_name} [OPTIONS] [--] [COMMAND...]

Docker Linux container wrapper with automatic path mounting.

REQUIRED ENVIRONMENT VARIABLES:
  JAILBOT_IMAGE_NAME      Docker image name (e.g., "debian:trixie-slim")

OPTIONAL ENVIRONMENT VARIABLES:
  JAILBOT_CONTAINER_VOLUME  Volume name to mount at /root (e.g., "jailbot_root")

OPTIONS:
  --verbose         Enable verbose output
  --git             Mount Git configuration files (~/.gitconfig, ~/.config/git/ignore)
  --workdir=PATH    Mount directory directly into container's workdir (/workspace)
  --workdir PATH    Mount directory directly into container's workdir (/workspace)
  --help            Show this help message

SEPARATOR:
  Use -- to separate jailbot options from container command.
  Everything after -- is passed to the container with automatic path mounting.

ARGS:
  Any arguments to pass to the container. Path arguments are automatically
  detected and mounted with proper translation to container paths.

WORKDIR MODE:
  Use --workdir=PATH to mount a directory directly into the container's
  working directory (/workspace). This is useful when you want to run commands
  in the context of a specific directory without passing it as an argument.
  Example: ${script_name} --workdir=. -- bash  # Start shell in current directory

FEATURES:
  Use --git flag to mount Git configuration files:
    ~/.gitconfig       	 -> /root/.gitconfig
    ~/.config/git/ignore -> /root/.config/git/ignore

EXAMPLES:
  ${script_name} --verbose -- ls -la
  ${script_name} --git -- git status
  ${script_name} --workdir=. -- bash
  ${script_name} --workdir=/home/user/projects -- myscript.sh
  ${script_name} -- cat ./local-file.txt
EOF
}

main() {
  # Check for --help first, before validation
  case "${1:-}" in
    --help|-h)
      show_usage
      exit 0
      ;;
  esac

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

      --verbose)
        VERBOSE=true
        shift
        ;;

      --git)
        MOUNT_GIT=true
        shift
        ;;

      --workdir=*)
        mount_path="${arg#--workdir=}"
        handle_mount_only "$mount_path"
        shift
        ;;

      --workdir)
        shift
        if [ $# -eq 0 ]; then
          log_error "--workdir requires a path argument"
        fi
        handle_mount_only "$1"
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

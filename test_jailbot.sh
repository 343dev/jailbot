#!/bin/sh
# Process-level contract tests for jailbot.sh.

set -u

SCRIPT="$(cd "$(dirname "$0")" && pwd)/jailbot.sh"
ENTRYPOINT="$(cd "$(dirname "$0")" && pwd)/docker-example/entrypoint.sh"
TEST_ROOT="${TMPDIR:-/tmp}/jailbot-tests-$$"
STUB_DIR="$TEST_ROOT/bin"
CALLS_FILE="$TEST_ROOT/docker-calls"
ARGS_DIR="$TEST_ROOT/docker-run-args"
EXPECTED_ARGS_DIR="$TEST_ROOT/expected-docker-run-args"
STDOUT_FILE="$TEST_ROOT/stdout"
STDERR_FILE="$TEST_ROOT/stderr"
NL='
'

TESTS=0
PASSED=0
FAILED=0
RUN_STATUS=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_status() {
  expected="$1"
  if [ "$RUN_STATUS" -ne "$expected" ]; then
    fail "expected exit status $expected, got $RUN_STATUS"
  fi
}

assert_empty() {
  file="$1"
  if [ -s "$file" ]; then
    printf '    expected %s to be empty; actual contents:\n' "$file" >&2
    od -An -tx1 -c "$file" >&2
    return 1
  fi
}

assert_contains() {
  file="$1"
  text="$2"
  if ! grep -Fq -- "$text" "$file"; then
    printf '    expected %s to contain: %s\n' "$file" "$text" >&2
    printf '    actual contents:\n' >&2
    od -An -tx1 -c "$file" >&2
    return 1
  fi
}

assert_no_control_bytes() {
  file="$1"
  if LC_ALL=C tr -d '\011\012\015\040-\176' < "$file" | grep -q .; then
    printf '    expected %s to contain no control bytes; actual contents:\n' "$file" >&2
    od -An -tx1 -c "$file" >&2
    return 1
  fi
}

assert_file_content() {
  file="$1"
  expected="$2"
  expected_file="$TEST_ROOT/expected-file"
  printf '%s' "$expected" > "$expected_file"
  if ! cmp -s "$expected_file" "$file"; then
    printf '    exact content mismatch for %s\n' "$file" >&2
    printf '    expected:\n' >&2
    od -An -tx1 -c "$expected_file" >&2
    printf '    actual:\n' >&2
    od -An -tx1 -c "$file" >&2
    return 1
  fi
}

assert_no_docker_calls() {
  assert_empty "$CALLS_FILE"
}

assert_docker_calls() {
  expected="$1"
  assert_file_content "$CALLS_FILE" "$expected"
}

record_expected_args() {
  rm -rf "$EXPECTED_ARGS_DIR"
  mkdir -p "$EXPECTED_ARGS_DIR"
  count=0
  for arg in "$@"; do
    count=$((count + 1))
    arg_file=$(printf '%s/arg.%06d' "$EXPECTED_ARGS_DIR" "$count")
    printf '%s' "$arg" > "$arg_file"
  done
  printf '%s\n' "$count" > "$EXPECTED_ARGS_DIR/count"
}

assert_run_args() {
  record_expected_args "$@"

  if [ ! -f "$ARGS_DIR/count" ]; then
    fail 'docker run argument capture is missing'
    return
  fi

  expected_count=$(cat "$EXPECTED_ARGS_DIR/count")
  actual_count=$(cat "$ARGS_DIR/count")
  if [ "$actual_count" -ne "$expected_count" ]; then
    fail "expected $expected_count docker run arguments, got $actual_count"
    return
  fi

  index=1
  while [ "$index" -le "$expected_count" ]; do
    expected_file=$(printf '%s/arg.%06d' "$EXPECTED_ARGS_DIR" "$index")
    actual_file=$(printf '%s/arg.%06d' "$ARGS_DIR" "$index")
    if ! cmp -s "$expected_file" "$actual_file"; then
      printf '    docker run argument %d differs\n' "$index" >&2
      printf '    expected:\n' >&2
      od -An -tx1 -c "$expected_file" >&2
      printf '    actual:\n' >&2
      od -An -tx1 -c "$actual_file" >&2
      return 1
    fi
    index=$((index + 1))
  done
}

captured_run_arg() {
  index="$1"
  arg_file=$(printf '%s/arg.%06d' "$ARGS_DIR" "$index")
  if [ ! -f "$arg_file" ]; then
    return 1
  fi
  cat "$arg_file"
}

reset_capture() {
  : > "$CALLS_FILE"
  : > "$STDOUT_FILE"
  : > "$STDERR_FILE"
  rm -rf "$ARGS_DIR"
  unset JAILBOT_STUB_RUN_STDOUT JAILBOT_STUB_RUN_STDERR JAILBOT_STUB_RUN_STATUS
}

run_cli() {
  reset_capture
  PATH="$STUB_DIR:$PATH" \
    TERM=dumb \
    SSH_AUTH_SOCK='' \
    JAILBOT_IMAGE_NAME=stubimage \
    JAILBOT_CONTAINER_NAME_PREFIX=test \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    "$SCRIPT" "$@" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?
}

run_cli_without_config() {
  reset_capture
  PATH="$STUB_DIR:$PATH" \
    TERM=dumb \
    SSH_AUTH_SOCK='' \
    JAILBOT_IMAGE_NAME='' \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    "$SCRIPT" "$@" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?
}

run_test() {
  name="$1"
  test_function="$2"
  TESTS=$((TESTS + 1))
  printf '[TEST] %s\n' "$name"
  if "$test_function"; then
    PASSED=$((PASSED + 1))
    printf '[PASS] %s\n' "$name"
  else
    FAILED=$((FAILED + 1))
    printf '[FAIL] %s\n' "$name"
  fi
}

create_docker_stub() {
  mkdir -p "$STUB_DIR"
  cat > "$STUB_DIR/docker" <<'STUB'
#!/bin/sh
set -u

command_name="${1:-}"
if [ "$#" -gt 0 ]; then
  shift
fi
printf '%s\n' "$command_name" >> "$JAILBOT_DOCKER_CALLS_FILE"

case "$command_name" in
  info)
    if [ -n "${JAILBOT_STUB_INFO_SLEEP:-}" ]; then
      sleep "$JAILBOT_STUB_INFO_SLEEP"
    fi
    if [ -n "${JAILBOT_STUB_INFO_STDERR:-}" ]; then
      printf '%s\n' "$JAILBOT_STUB_INFO_STDERR" >&2
    fi
    exit "${JAILBOT_STUB_INFO_STATUS:-0}"
    ;;
  image)
    if [ -n "${JAILBOT_STUB_IMAGE_SLEEP:-}" ]; then
      sleep "$JAILBOT_STUB_IMAGE_SLEEP"
    fi
    if [ -n "${JAILBOT_STUB_IMAGE_STDERR:-}" ]; then
      printf '%s\n' "$JAILBOT_STUB_IMAGE_STDERR" >&2
    fi
    exit "${JAILBOT_STUB_IMAGE_STATUS:-0}"
    ;;
  run)
    rm -rf "$JAILBOT_DOCKER_RUN_ARGS_DIR"
    mkdir -p "$JAILBOT_DOCKER_RUN_ARGS_DIR"
    count=0
    for arg in "$@"; do
      count=$((count + 1))
      arg_file=$(printf '%s/arg.%06d' "$JAILBOT_DOCKER_RUN_ARGS_DIR" "$count")
      printf '%s' "$arg" > "$arg_file"
    done
    printf '%s\n' "$count" > "$JAILBOT_DOCKER_RUN_ARGS_DIR/count"
    if [ -n "${JAILBOT_STUB_RUN_STDOUT:-}" ]; then
      printf '%s\n' "$JAILBOT_STUB_RUN_STDOUT"
    fi
    if [ -n "${JAILBOT_STUB_RUN_STDERR:-}" ]; then
      printf '%s\n' "$JAILBOT_STUB_RUN_STDERR" >&2
    fi
    if [ -n "${JAILBOT_STUB_SIGNAL_FILE:-}" ]; then
      exec python3 - <<'PYTHON_SIGNAL_STUB'
import os
import signal
import time

signal_file = os.environ["JAILBOT_STUB_SIGNAL_FILE"]
ready_file = os.environ["JAILBOT_STUB_READY_FILE"]

def stop(signum, _frame):
    name = signal.Signals(signum).name.removeprefix("SIG")
    with open(signal_file, "w", encoding="ascii") as output:
        output.write(name)
    raise SystemExit(128 + signum)

signal.signal(signal.SIGINT, stop)
signal.signal(signal.SIGTERM, stop)
with open(ready_file, "w", encoding="ascii") as output:
    output.write(str(os.getpid()))
while True:
    time.sleep(1)
PYTHON_SIGNAL_STUB
    fi
    exit "${JAILBOT_STUB_RUN_STATUS:-0}"
    ;;
esac

exit 0
STUB
  chmod +x "$STUB_DIR/docker"
}

test_stub_preserves_exact_argv() {
  reset_capture
  PATH="$STUB_DIR:$PATH" \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    docker run 'two words' '' '*' "\\" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?

  assert_status 0 || return
  assert_run_args 'two words' '' '*' "\\" || return
  assert_docker_calls "run${NL}" || return
  assert_empty "$STDOUT_FILE" || return
  assert_empty "$STDERR_FILE"
}

test_long_help_is_safe_without_configuration() {
  run_cli_without_config --help

  assert_status 0 || return
  assert_contains "$STDOUT_FILE" 'Usage:' || return
  assert_contains "$STDOUT_FILE" 'Docker Linux container wrapper' || return
  assert_contains "$STDOUT_FILE" '-h, --help' || return
  assert_contains "$STDOUT_FILE" 'https://github.com/343dev/jailbot' || return
  assert_no_control_bytes "$STDOUT_FILE" || return
  assert_empty "$STDERR_FILE" || return
  assert_no_docker_calls
}

test_short_help_is_safe_without_configuration() {
  run_cli_without_config -h

  assert_status 0 || return
  assert_contains "$STDOUT_FILE" 'Usage:' || return
  assert_no_control_bytes "$STDOUT_FILE" || return
  assert_empty "$STDERR_FILE" || return
  assert_no_docker_calls
}

test_help_wins_before_separator() {
  run_cli_without_config --unknown-option --help

  assert_status 0 || return
  assert_contains "$STDOUT_FILE" 'Usage:' || return
  assert_empty "$STDERR_FILE" || return
  assert_no_docker_calls
}

test_version_is_safe_without_configuration() {
  run_cli_without_config --version

  assert_status 0 || return
  assert_file_content "$STDOUT_FILE" "jailbot 2.0.0${NL}" || return
  assert_empty "$STDERR_FILE" || return
  assert_no_docker_calls
}

test_separator_passes_wrapper_like_arguments() {
  run_cli -- printf '%s' --help

  assert_status 0 || return
  assert_docker_calls "info${NL}image${NL}run${NL}" || return

  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage printf '%s' --help
  assert_run_args "$@"
}

test_unknown_option_has_exact_failure_contract() {
  run_cli --unknown-option

  assert_status 1 || return
  assert_contains "$STDERR_FILE" '[ERROR] Unknown option: --unknown-option' || return
  assert_contains "$STDERR_FILE" 'Usage:' || return
  assert_no_docker_calls
}

test_missing_configuration_stops_before_docker() {
  run_cli_without_config -- echo test

  assert_status 1 || return
  assert_contains "$STDERR_FILE" 'JAILBOT_IMAGE_NAME environment variable is not set' || return
  assert_no_docker_calls
}

assert_validation_failure() {
  expected_message="$1"
  shift
  run_cli "$@"

  assert_status 1 || return
  assert_empty "$STDOUT_FILE" || return
  assert_contains "$STDERR_FILE" "$expected_message" || return
  assert_no_docker_calls
}

test_empty_workdir_is_rejected_before_docker() {
  assert_validation_failure '--workdir requires a non-empty directory path' --workdir=
}

test_missing_workdir_is_rejected_before_docker() {
  missing_path="$TEST_ROOT/missing-workdir"
  assert_validation_failure "Workdir does not exist: $missing_path" --workdir "$missing_path" -- echo test
}

test_workdir_file_is_rejected_before_docker() {
  file_path="$TEST_ROOT/not-a-directory"
  printf 'file\n' > "$file_path"
  assert_validation_failure "Workdir must be a directory: $file_path" --workdir="$file_path" -- echo test
}

test_workdir_without_value_is_rejected_before_docker() {
  assert_validation_failure '--workdir requires a path argument' --workdir
}

test_workdir_separator_is_not_consumed_as_value() {
  assert_validation_failure '--workdir requires a path argument' --workdir -- echo test
}

test_empty_network_is_rejected_before_docker() {
  assert_validation_failure '--network requires a non-empty network name' --network=
}

test_network_without_value_is_rejected_before_docker() {
  assert_validation_failure '--network requires a network name argument' --network
}

test_network_separator_is_not_consumed_as_value() {
  assert_validation_failure '--network requires a network name argument' --network -- echo test
}

test_missing_ssh_socket_is_rejected_before_docker() {
  assert_validation_failure 'SSH agent forwarding requires an available SSH auth socket' --ssh -- echo test || return
  assert_contains "$STDERR_FILE" 'start an SSH agent, set SSH_AUTH_SOCK, or remove --ssh'
}

run_cli_with_docker_failure() {
  reset_capture
  PATH="$STUB_DIR:$PATH" \
    TERM=dumb \
    SSH_AUTH_SOCK='' \
    JAILBOT_IMAGE_NAME=stubimage \
    JAILBOT_CONTAINER_NAME_PREFIX=test \
    JAILBOT_DOCKER_TIMEOUT_SECONDS="${JAILBOT_DOCKER_TIMEOUT_SECONDS:-10}" \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    JAILBOT_STUB_INFO_SLEEP="${JAILBOT_STUB_INFO_SLEEP:-}" \
    JAILBOT_STUB_INFO_STDERR="${JAILBOT_STUB_INFO_STDERR:-}" \
    JAILBOT_STUB_INFO_STATUS="${JAILBOT_STUB_INFO_STATUS:-0}" \
    JAILBOT_STUB_IMAGE_SLEEP="${JAILBOT_STUB_IMAGE_SLEEP:-}" \
    JAILBOT_STUB_IMAGE_STDERR="${JAILBOT_STUB_IMAGE_STDERR:-}" \
    JAILBOT_STUB_IMAGE_STATUS="${JAILBOT_STUB_IMAGE_STATUS:-0}" \
    "$SCRIPT" "$@" > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?
}

clear_docker_failure_env() {
  unset JAILBOT_DOCKER_TIMEOUT_SECONDS \
    JAILBOT_STUB_INFO_SLEEP JAILBOT_STUB_INFO_STDERR JAILBOT_STUB_INFO_STATUS \
    JAILBOT_STUB_IMAGE_SLEEP JAILBOT_STUB_IMAGE_STDERR JAILBOT_STUB_IMAGE_STATUS
}

test_daemon_permission_error_is_actionable() {
  JAILBOT_STUB_INFO_STATUS=1
  JAILBOT_STUB_INFO_STDERR='permission denied while trying to connect to the Docker daemon socket'
  run_cli_with_docker_failure -- echo test
  clear_docker_failure_env

  assert_status 1 || return
  assert_empty "$STDOUT_FILE" || return
  assert_contains "$STDERR_FILE" 'Permission denied while accessing Docker' || return
  assert_contains "$STDERR_FILE" 'socket permissions' || return
  assert_docker_calls "info${NL}"
}

test_docker_context_error_is_actionable_and_verbose() {
  JAILBOT_STUB_INFO_STATUS=1
  JAILBOT_STUB_INFO_STDERR='error during connect: context deadline exceeded'
  run_cli_with_docker_failure --verbose -- echo test
  clear_docker_failure_env

  assert_status 1 || return
  assert_contains "$STDERR_FILE" 'Docker daemon or current context is not accessible' || return
  assert_contains "$STDERR_FILE" '[VERBOSE] Docker detail: error during connect: context deadline exceeded' || return
  assert_docker_calls "info${NL}"
}

test_missing_local_image_is_actionable() {
  JAILBOT_STUB_IMAGE_STATUS=1
  JAILBOT_STUB_IMAGE_STDERR='Error: No such image: stubimage'
  run_cli_with_docker_failure -- echo test
  clear_docker_failure_env

  assert_status 1 || return
  assert_contains "$STDERR_FILE" 'Docker image stubimage was not found locally' || return
  assert_contains "$STDERR_FILE" 'build or pull it first' || return
  assert_docker_calls "info${NL}image${NL}"
}

test_docker_check_timeout_is_bounded() {
  JAILBOT_DOCKER_TIMEOUT_SECONDS=1
  JAILBOT_STUB_INFO_SLEEP=5
  run_cli_with_docker_failure -- echo test
  clear_docker_failure_env

  assert_status 1 || return
  assert_contains "$STDERR_FILE" 'Docker daemon check timed out after 1 seconds' || return
  assert_docker_calls "info${NL}"
}

test_invalid_docker_timeout_is_rejected_before_docker() {
  JAILBOT_DOCKER_TIMEOUT_SECONDS=invalid
  run_cli_with_docker_failure -- echo test
  clear_docker_failure_env

  assert_status 1 || return
  assert_contains "$STDERR_FILE" 'JAILBOT_DOCKER_TIMEOUT_SECONDS must be a positive integer' || return
  assert_no_docker_calls
}

test_streams_and_status_are_captured_exactly() {
  reset_capture
  export JAILBOT_STUB_RUN_STDOUT='container stdout'
  export JAILBOT_STUB_RUN_STDERR='container stderr'
  export JAILBOT_STUB_RUN_STATUS=17

  PATH="$STUB_DIR:$PATH" \
    TERM=dumb \
    SSH_AUTH_SOCK='' \
    JAILBOT_IMAGE_NAME=stubimage \
    JAILBOT_CONTAINER_NAME_PREFIX=test \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    JAILBOT_STUB_RUN_STDOUT="$JAILBOT_STUB_RUN_STDOUT" \
    JAILBOT_STUB_RUN_STDERR="$JAILBOT_STUB_RUN_STDERR" \
    JAILBOT_STUB_RUN_STATUS="$JAILBOT_STUB_RUN_STATUS" \
    "$SCRIPT" -- echo test > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?
  unset JAILBOT_STUB_RUN_STDOUT JAILBOT_STUB_RUN_STDERR JAILBOT_STUB_RUN_STATUS

  assert_status 17 || return
  assert_file_content "$STDOUT_FILE" "container stdout${NL}" || return
  assert_no_control_bytes "$STDOUT_FILE" || return
  assert_file_content "$STDERR_FILE" "container stderr${NL}" || return
  assert_docker_calls "info${NL}image${NL}run${NL}"
}

run_signal_case() {
  signal_name="$1"
  expected_status="$2"
  ready_file="$TEST_ROOT/signal-ready"
  signal_file="$TEST_ROOT/signal-received"
  status_file="$TEST_ROOT/signal-status"
  reset_capture
  rm -f "$ready_file" "$signal_file" "$status_file"

  PATH="$STUB_DIR:$PATH" \
    TERM=dumb \
    SSH_AUTH_SOCK='' \
    JAILBOT_IMAGE_NAME=stubimage \
    JAILBOT_CONTAINER_NAME_PREFIX=test \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    JAILBOT_STUB_SIGNAL_FILE="$signal_file" \
    JAILBOT_STUB_READY_FILE="$ready_file" \
    JAILBOT_SIGNAL_NAME="$signal_name" \
    JAILBOT_SIGNAL_STATUS_FILE="$status_file" \
    python3 - "$SCRIPT" "$STDOUT_FILE" "$STDERR_FILE" <<'PYTHON'
import os
import signal
import subprocess
import sys
import time

script, stdout_path, stderr_path = sys.argv[1:]
def start_new_session_with_default_signals():
    os.setsid()
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

with open(stdout_path, "wb") as stdout, open(stderr_path, "wb") as stderr:
    process = subprocess.Popen(
        [script, "--", "sleep", "60"],
        stdout=stdout,
        stderr=stderr,
        env=os.environ.copy(),
        preexec_fn=start_new_session_with_default_signals,
    )
    ready_file = os.environ["JAILBOT_STUB_READY_FILE"]
    for _ in range(100):
        if os.path.exists(ready_file) and os.path.getsize(ready_file) > 0:
            break
        if process.poll() is not None:
            break
        time.sleep(0.05)
    else:
        process.kill()
        process.wait()
        raise SystemExit("Docker stub did not become ready for signal test")

    if process.poll() is not None:
        raise SystemExit("Jailbot exited before the signal was sent")
    requested_signal = getattr(signal, "SIG" + os.environ["JAILBOT_SIGNAL_NAME"])
    if requested_signal == signal.SIGINT:
        os.killpg(process.pid, requested_signal)
    else:
        process.send_signal(requested_signal)
    try:
        status = process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise SystemExit("Jailbot did not stop after the signal")

with open(os.environ["JAILBOT_SIGNAL_STATUS_FILE"], "w", encoding="ascii") as output:
    output.write(str(status))
PYTHON
  helper_status=$?
  if [ "$helper_status" -ne 0 ]; then
    fail "signal helper failed with status $helper_status"
    return
  fi
  RUN_STATUS=$(cat "$status_file")

  assert_status "$expected_status" || return
  assert_file_content "$signal_file" "$signal_name" || return
  assert_empty "$STDOUT_FILE" || return

  run_cli -- echo retry
  assert_status 0
}

test_sigint_is_forwarded_with_status_130() {
  run_signal_case INT 130
}

test_sigterm_is_forwarded_with_status_143() {
  run_signal_case TERM 143
}

test_container_argv_preserves_empty_and_special_arguments() {
  run_cli -- printf '<%s>' '' 'two words' '*' 'back\slash' ''

  assert_status 0 || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage \
    printf '<%s>' '' 'two words' '*' 'back\slash' ''
  assert_run_args "$@"
}

test_newline_argument_is_rejected_before_docker() {
  newline_argument="first${NL}second"
  run_cli -- printf '%s' "$newline_argument"

  assert_status 1 || return
  assert_empty "$STDOUT_FILE" || return
  assert_contains "$STDERR_FILE" 'Container arguments containing newlines are not supported' || return
  assert_no_docker_calls
}

test_bare_invocation_adds_no_container_command() {
  run_cli

  assert_status 0 || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage
  assert_run_args "$@"
}

test_ordinary_command_has_complete_docker_argv() {
  run_cli -- echo 'two words'

  assert_status 0 || return
  assert_docker_calls "info${NL}image${NL}run${NL}" || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage echo 'two words'
  assert_run_args "$@"
}

test_repeated_directory_uses_one_mount_and_one_target() {
  path_dir="$TEST_ROOT/repeated-project"
  mkdir -p "$path_dir"

  run_cli -- printf '%s:%s' "$path_dir" "$path_dir"

  assert_status 0 || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  container_dir="/workspace/$(basename "$path_dir")"
  set -- --rm --name "$container_name" -i \
    --mount "type=bind,source=$path_dir,target=$container_dir" \
    --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage \
    printf '%s:%s' "$container_dir" "$container_dir"
  assert_run_args "$@"
}

test_colliding_mount_targets_are_rejected_before_docker() {
  first_dir="$TEST_ROOT/first/project"
  second_dir="$TEST_ROOT/second/project"
  mkdir -p "$first_dir" "$second_dir"

  run_cli -- printf '%s:%s' "$first_dir" "$second_dir"

  assert_status 1 || return
  assert_empty "$STDOUT_FILE" || return
  assert_contains "$STDERR_FILE" 'Mount target collision: /workspace/project' || return
  assert_contains "$STDERR_FILE" "$first_dir" || return
  assert_contains "$STDERR_FILE" "$second_dir" || return
  assert_no_docker_calls
}

test_comma_path_is_rejected_before_docker() {
  comma_dir="$TEST_ROOT/project,comma"
  mkdir -p "$comma_dir"

  run_cli -- cat "$comma_dir"

  assert_status 1 || return
  assert_empty "$STDOUT_FILE" || return
  assert_contains "$STDERR_FILE" 'Cannot automatically mount path containing a comma' || return
  assert_contains "$STDERR_FILE" "$comma_dir" || return
  assert_no_docker_calls
}

test_workspace_path_is_passed_without_mounting() {
  workspace_path="$(cd "$(dirname "$SCRIPT")" && pwd)/README.md"

  run_cli -- printf '%s' "$workspace_path"

  assert_status 0 || return
  assert_contains "$STDERR_FILE" "Skipping container workdir path: $workspace_path" || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage printf '%s' "$workspace_path"
  assert_run_args "$@"
}

test_escaped_comma_path_is_passed_without_mounting() {
  comma_dir="$TEST_ROOT/escaped,comma"
  mkdir -p "$comma_dir"

  run_cli -- printf '%s' "\\$comma_dir"

  assert_status 0 || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage printf '%s' "$comma_dir"
  assert_run_args "$@"
}

test_path_with_spaces_has_exact_mount_and_translation() {
  path_dir="$TEST_ROOT/path with spaces"
  path_file="$path_dir/file name.txt"
  mkdir -p "$path_dir"
  printf 'data\n' > "$path_file"

  run_cli -- cat "$path_file"

  assert_status 0 || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  container_dir="/workspace/$(basename "$path_dir")"
  set -- --rm --name "$container_name" -i \
    --mount "type=bind,source=$path_dir,target=$container_dir" \
    --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --workdir /workspace stubimage cat "$container_dir/$(basename "$path_file")"
  assert_run_args "$@"
}

test_persistent_volume_targets_container_home() {
  reset_capture
  PATH="$STUB_DIR:$PATH" \
    TERM=dumb \
    SSH_AUTH_SOCK='' \
    JAILBOT_IMAGE_NAME=stubimage \
    JAILBOT_CONTAINER_NAME_PREFIX=test \
    JAILBOT_CONTAINER_VOLUME=jailbot_home \
    JAILBOT_DOCKER_CALLS_FILE="$CALLS_FILE" \
    JAILBOT_DOCKER_RUN_ARGS_DIR="$ARGS_DIR" \
    "$SCRIPT" -- echo test > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?

  assert_status 0 || return
  container_name=$(captured_run_arg 3) || return 1
  timezone=''
  if [ -L /etc/localtime ]; then
    timezone=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
  elif [ -f /etc/timezone ]; then
    timezone=$(cat /etc/timezone)
  fi
  set -- --rm --name "$container_name" -i --user jailbot --env HOME=/home/jailbot
  if [ -n "$timezone" ]; then
    set -- "$@" --env "TZ=$timezone"
  fi
  set -- "$@" --volume jailbot_home:/home/jailbot \
    --workdir /workspace stubimage echo test
  assert_run_args "$@"
}

test_entrypoint_loads_path_from_bashrc() {
  test_home="$TEST_ROOT/entrypoint-home"
  mkdir -p "$test_home/.local/bin"
  cat > "$test_home/.local/bin/pi-test" <<'COMMAND'
#!/bin/sh
printf 'pi-test args=%s\n' "$*"
COMMAND
  chmod +x "$test_home/.local/bin/pi-test"
  cat > "$test_home/.bashrc" <<'BASHRC'
export PATH="$HOME/.local/bin:$PATH"
BASHRC

  HOME="$test_home" bash "$ENTRYPOINT" pi-test hello 'two words' > "$STDOUT_FILE" 2> "$STDERR_FILE"
  RUN_STATUS=$?

  assert_status 0 || return
  assert_file_content "$STDOUT_FILE" "pi-test args=hello two words${NL}"
}

main() {
  mkdir -p "$TEST_ROOT"
  : > "$CALLS_FILE"
  : > "$STDOUT_FILE"
  : > "$STDERR_FILE"
  create_docker_stub

  run_test 'Docker stub preserves exact argv elements' test_stub_preserves_exact_argv
  run_test 'long help is safe without configuration' test_long_help_is_safe_without_configuration
  run_test 'short help is safe without configuration' test_short_help_is_safe_without_configuration
  run_test 'help wins over errors before the separator' test_help_wins_before_separator
  run_test 'version is safe without configuration' test_version_is_safe_without_configuration
  run_test 'separator passes wrapper-like arguments to the container' test_separator_passes_wrapper_like_arguments
  run_test 'unknown options have a strict failure contract' test_unknown_option_has_exact_failure_contract
  run_test 'missing configuration stops before Docker' test_missing_configuration_stops_before_docker
  run_test 'empty workdir is rejected before Docker' test_empty_workdir_is_rejected_before_docker
  run_test 'missing workdir is rejected before Docker' test_missing_workdir_is_rejected_before_docker
  run_test 'workdir files are rejected before Docker' test_workdir_file_is_rejected_before_docker
  run_test 'workdir without a value is rejected before Docker' test_workdir_without_value_is_rejected_before_docker
  run_test 'workdir does not consume the separator as a value' test_workdir_separator_is_not_consumed_as_value
  run_test 'empty network is rejected before Docker' test_empty_network_is_rejected_before_docker
  run_test 'network without a value is rejected before Docker' test_network_without_value_is_rejected_before_docker
  run_test 'network does not consume the separator as a value' test_network_separator_is_not_consumed_as_value
  run_test 'missing SSH socket is rejected before Docker' test_missing_ssh_socket_is_rejected_before_docker
  run_test 'Docker permission errors are actionable' test_daemon_permission_error_is_actionable
  run_test 'Docker context errors are actionable and verbose' test_docker_context_error_is_actionable_and_verbose
  run_test 'missing local images are actionable' test_missing_local_image_is_actionable
  run_test 'Docker checks have a bounded timeout' test_docker_check_timeout_is_bounded
  run_test 'invalid Docker timeout is rejected before Docker' test_invalid_docker_timeout_is_rejected_before_docker
  run_test 'stdout, stderr, and exit status are independent' test_streams_and_status_are_captured_exactly
  run_test 'SIGINT is forwarded with status 130' test_sigint_is_forwarded_with_status_130
  run_test 'SIGTERM is forwarded with status 143' test_sigterm_is_forwarded_with_status_143
  run_test 'container argv preserves empty and special arguments' test_container_argv_preserves_empty_and_special_arguments
  run_test 'newline arguments are rejected before Docker' test_newline_argument_is_rejected_before_docker
  run_test 'bare invocation adds no container command' test_bare_invocation_adds_no_container_command
  run_test 'ordinary commands produce a complete Docker argv' test_ordinary_command_has_complete_docker_argv
  run_test 'repeated directories use one mount and target' test_repeated_directory_uses_one_mount_and_one_target
  run_test 'colliding mount targets are rejected before Docker' test_colliding_mount_targets_are_rejected_before_docker
  run_test 'comma paths are rejected before Docker' test_comma_path_is_rejected_before_docker
  run_test 'workspace paths pass without mounting' test_workspace_path_is_passed_without_mounting
  run_test 'escaped comma paths pass without mounting' test_escaped_comma_path_is_passed_without_mounting
  run_test 'paths with spaces preserve mount and translated argv' test_path_with_spaces_has_exact_mount_and_translation
  run_test 'persistent volume targets the container home' test_persistent_volume_targets_container_home
  run_test 'entrypoint resolves commands from bashrc PATH' test_entrypoint_loads_path_from_bashrc

  printf '\nTests: %d, Passed: %d, Failed: %d\n' "$TESTS" "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}

main "$@"

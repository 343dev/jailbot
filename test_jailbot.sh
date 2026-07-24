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
    exit 0
    ;;
  image)
    exit 0
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
  set -- "$@" --workdir /workspace stubimage -- printf '%s' --help
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
  set -- "$@" --workdir /workspace stubimage -- echo 'two words'
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
  set -- "$@" --workdir /workspace stubimage -- cat "$container_dir/$(basename "$path_file")"
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
    --workdir /workspace stubimage -- echo test
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
  run_test 'stdout, stderr, and exit status are independent' test_streams_and_status_are_captured_exactly
  run_test 'ordinary commands produce a complete Docker argv' test_ordinary_command_has_complete_docker_argv
  run_test 'paths with spaces preserve mount and translated argv' test_path_with_spaces_has_exact_mount_and_translation
  run_test 'persistent volume targets the container home' test_persistent_volume_targets_container_home
  run_test 'entrypoint resolves commands from bashrc PATH' test_entrypoint_loads_path_from_bashrc

  printf '\nTests: %d, Passed: %d, Failed: %d\n' "$TESTS" "$PASSED" "$FAILED"
  [ "$FAILED" -eq 0 ]
}

main "$@"

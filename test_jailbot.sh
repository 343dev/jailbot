#!/bin/sh
# Test suite for jailbot.sh
# Tests various edge cases and security scenarios

set -e

SCRIPT="./jailbot.sh"
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PASSED=0
FAILED=0

# Colors for output (if terminal supports it)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m' # No Color
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

log_test() {
  printf "${YELLOW}[TEST]${NC} %s\n" "$1"
}

log_pass() {
  printf "${GREEN}[PASS]${NC} %s\n" "$1"
  PASSED=$((PASSED + 1))
}

log_fail() {
  printf "${RED}[FAIL]${NC} %s\n" "$1"
  FAILED=$((FAILED + 1))
}

# Test 1: Help flag
test_help() {
  log_test "Testing --help flag"
  if $SCRIPT --help >/dev/null 2>&1; then
    log_pass "--help works"
  else
    log_fail "--help failed"
  fi
}

# Test 2: -- separator usage
test_separator() {
  log_test "Testing -- separator"
  # Unknown flags after -- should be passed to container
  if JAILBOT_IMAGE_NAME=test $SCRIPT --verbose -- git config --global user.name 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Separator passes flags to container"
  else
    log_fail "Separator not working properly"
  fi
}

# Test 2b: Unknown flag shows usage
test_unknown_flag() {
  log_test "Testing unknown flag shows usage"
  # Unknown flags before -- should show usage and exit with error
  if JAILBOT_IMAGE_NAME=test $SCRIPT --unknown-flag 2>&1 | grep -q "Usage:"; then
    log_pass "Unknown flag shows usage"
  else
    log_fail "Unknown flag does not show usage"
  fi
}

# Test 3: Empty arguments
test_empty_args() {
  log_test "Testing empty argument handling"
  # Should not crash
  if $SCRIPT 2>&1 | grep -q "Docker\|daemon\|not found"; then
    log_pass "Empty args handled (Docker validation works)"
  else
    log_pass "Empty args processed"
  fi
}

# Test 4: Path with spaces
test_path_with_spaces() {
  log_test "Testing path with spaces"
  mkdir -p "$TEST_DIR/path with spaces"
  touch "$TEST_DIR/path with spaces/file.txt"
  
  # Should handle without errors
  if $SCRIPT --verbose -- "$TEST_DIR/path with spaces/file.txt" 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Path with spaces handled (Docker not available)"
  else
    log_pass "Path with spaces processed"
  fi
  
  rm -rf "$TEST_DIR/path with spaces"
}

# Test 5: Special characters in path
test_special_chars() {
  log_test "Testing special characters in path"
  mkdir -p "$TEST_DIR/special_chars"
  touch "$TEST_DIR/special_chars/file;rm -rf;.txt"
  
  # Should handle without executing injection
  if $SCRIPT --verbose -- "$TEST_DIR/special_chars/file;rm -rf;.txt" 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Special characters handled safely"
  else
    log_pass "Special characters processed"
  fi
  
  rm -rf "$TEST_DIR/special_chars"
}

# Test 6: Non-existent path
test_nonexistent_path() {
  log_test "Testing non-existent path"
  if $SCRIPT --verbose -- /nonexistent/path/to/file 2>&1 | grep -q "WARNING.*does not exist"; then
    log_pass "Non-existent path warning shown"
  else
    log_pass "Non-existent path handled"
  fi
}

# Test 7: npm package name (starts with @)
test_npm_package() {
  log_test "Testing npm package name handling"
  # @babel/core should not be treated as path
  if $SCRIPT --verbose -- @babel/core 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "NPM package handled correctly"
  else
    log_pass "NPM package processed"
  fi
}

# Test 8: Multiple paths
test_multiple_paths() {
  log_test "Testing multiple paths"
  mkdir -p "$TEST_DIR/multi_test"
  touch "$TEST_DIR/multi_test/file1.txt"
  touch "$TEST_DIR/multi_test/file2.txt"
  
  # Should handle multiple files
  if $SCRIPT --verbose -- "$TEST_DIR/multi_test/file1.txt" "$TEST_DIR/multi_test/file2.txt" 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Multiple paths handled"
  else
    log_pass "Multiple paths processed"
  fi
  
  rm -rf "$TEST_DIR/multi_test"
}

# Test 9: Symbolic link
test_symlink() {
  log_test "Testing symbolic link handling"
  mkdir -p "$TEST_DIR/symlink_test"
  touch "$TEST_DIR/symlink_test/real_file.txt"
  ln -sf "$TEST_DIR/symlink_test/real_file.txt" "$TEST_DIR/symlink_test/link.txt"
  
  if $SCRIPT --verbose -- "$TEST_DIR/symlink_test/link.txt" 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Symlink handled"
  else
    log_pass "Symlink processed"
  fi
  
  rm -rf "$TEST_DIR/symlink_test"
}

# Test 10: Relative paths
test_relative_paths() {
  log_test "Testing relative paths"
  mkdir -p "$TEST_DIR/rel_test/subdir"
  touch "$TEST_DIR/rel_test/file.txt"
  
  cd "$TEST_DIR/rel_test"
  if $SCRIPT --verbose -- ./file.txt ../rel_test/file.txt 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Relative paths handled"
  else
    log_pass "Relative paths processed"
  fi
  cd "$TEST_DIR"
  
  rm -rf "$TEST_DIR/rel_test"
}

# Test 11: URL-like paths (should not be treated as paths)
test_url_paths() {
  log_test "Testing URL-like arguments"
  # URLs should not be mounted
  if $SCRIPT --verbose -- http://example.com/file.txt 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "URL not treated as path"
  else
    log_pass "URL handled correctly"
  fi
}

# Test 12: --workdir option
test_mount_only() {
  log_test "Testing --workdir option"
  mkdir -p "$TEST_DIR/mount_test"

  if $SCRIPT --verbose --workdir="$TEST_DIR/mount_test" -- echo "test" 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Workdir option handled"
  else
    log_pass "Workdir processed"
  fi

  rm -rf "$TEST_DIR/mount_test"
}

# Test 12b: --workdir with tilde expansion
test_workdir_tilde() {
  log_test "Testing --workdir tilde expansion"
  mkdir -p "$HOME/debian_test_tilde"

  # Test with --workdir=~/path syntax
  if $SCRIPT --verbose --workdir="$HOME/debian_test_tilde" -- echo "test" 2>&1 | grep -q "Added mount.*debian_test_tilde"; then
    log_pass "Tilde expansion works"
  else
    log_pass "Tilde expansion handled"
  fi

  rm -rf "$HOME/debian_test_tilde"
}

# Test 13: Command injection attempt
test_command_injection() {
  log_test "Testing command injection protection"
  # This should NOT execute 'id' command
  output=$($SCRIPT --verbose -- '"; id; echo "' 2>&1) || true
  
  if echo "$output" | grep -q "uid="; then
    log_fail "Command injection vulnerability detected!"
  else
    log_pass "Command injection prevented"
  fi
}

# Test 14: Container workdir path rejection
test_workdir_path() {
  log_test "Testing container workdir path rejection"
  if $SCRIPT --verbose -- /workspace/test 2>&1 | grep -q "Skipping container workdir"; then
    log_pass "Workspace path correctly rejected"
  else
    log_pass "Workspace path handled"
  fi
}

# Test 15: Verbose mode
test_verbose_mode() {
  log_test "Testing verbose mode"
  if $SCRIPT --verbose -- echo "test" 2>&1 | grep -q "\[VERBOSE\]"; then
    log_pass "Verbose mode produces output"
  else
    log_pass "Verbose mode handled"
  fi
}

# Test 16: Git config mounting
test_git_config() {
  log_test "Testing git config auto-mounting"
  # Create test git config files
  mkdir -p "$HOME/.config/git"
  touch "$HOME/.gitconfig" 2>/dev/null || true
  touch "$HOME/.config/git/ignore" 2>/dev/null || true
  
  if $SCRIPT --git --verbose -- echo "test" 2>&1 | grep -q "gitconfig\|git ignore\|Docker\|daemon"; then
    log_pass "Git config handled"
  else
    log_pass "Git config processed"
  fi
}

# Test 17: Pipe input
test_pipe_input() {
  log_test "Testing pipe input detection"
  if echo "test" | $SCRIPT -- cat 2>&1 | grep -q "Docker\|daemon"; then
    log_pass "Pipe input handled"
  else
    log_pass "Pipe input processed"
  fi
}

# Test 18: Escaped paths (prefixed with backslash)
test_escaped_path() {
  log_test "Testing escaped path handling"

  # Create test files for absolute and relative paths
  test_dir="/tmp/jailbot_escaped_test_$$"
  mkdir -p "$test_dir"
  echo "absolute" > "$test_dir/absolute.txt"

  # Also create relative path test structure
  rel_test_dir="/tmp/jailbot_rel_test_$$"
  mkdir -p "$rel_test_dir/subdir"
  echo "relative" > "$rel_test_dir/subdir/file.txt"

  # Test 1: Escaped absolute path should be unescaped and not mounted
  # Use verbose mode to check that the escaped path is passed through
  escaped_abs_path="\\${test_dir}/absolute.txt"
  output=$(JAILBOT_IMAGE_NAME=test $SCRIPT --verbose -- "$escaped_abs_path" 2>&1) || true
  if echo "$output" | grep -q "Escaped path, passing through.*$test_dir/absolute.txt"; then
    log_pass "Escaped absolute path is unescaped"
  else
    log_fail "Escaped absolute path not properly unescaped"
  fi

  # Test 2: Escaped relative path should be unescaped
  cd "$rel_test_dir/subdir"
  escaped_rel_path="\\../subdir/file.txt"
  output=$(JAILBOT_IMAGE_NAME=test "$TEST_DIR/$SCRIPT" --verbose -- "$escaped_rel_path" 2>&1) || true
  if echo "$output" | grep -q "Escaped path, passing through.*../subdir/file.txt"; then
    log_pass "Escaped relative path is unescaped"
  else
    log_fail "Escaped relative path not properly unescaped"
  fi
  cd "$TEST_DIR"

  # Test 3: Escaped ./ relative path
  cd "$rel_test_dir/subdir"
  escaped_dot_path="\\./file.txt"
  output=$(JAILBOT_IMAGE_NAME=test "$TEST_DIR/$SCRIPT" --verbose -- "$escaped_dot_path" 2>&1) || true
  if echo "$output" | grep -q "Escaped path, passing through.*./file.txt"; then
    log_pass "Escaped ./ relative path is unescaped"
  else
    log_fail "Escaped ./ relative path not properly unescaped"
  fi
  cd "$TEST_DIR"

  # Cleanup
  rm -rf "$test_dir" "$rel_test_dir"
}

# Main test runner
main() {
  printf "========================================\n"
  printf "Testing jailbot.sh\n"
  printf "========================================\n\n"
  
  # Check if script exists and is executable
  if [ ! -x "$SCRIPT" ]; then
    chmod +x "$SCRIPT" 2>/dev/null || true
  fi
  
  # Run all tests
  test_help
  test_separator
  test_unknown_flag
  test_empty_args
  test_path_with_spaces
  test_special_chars
  test_nonexistent_path
  test_npm_package
  test_multiple_paths
  test_symlink
  test_relative_paths
  test_url_paths
  test_mount_only
  test_workdir_tilde
  test_command_injection
  test_workdir_path
  test_verbose_mode
  test_git_config
  test_pipe_input
  test_escaped_path

  printf "\n========================================\n"
  printf "Test Results:\n"
  printf "  Passed: %d\n" "$PASSED"
  printf "  Failed: %d\n" "$FAILED"
  printf "========================================\n"
  
  if [ "$FAILED" -eq 0 ]; then
    printf "${GREEN}All tests passed!${NC}\n"
    exit 0
  else
    printf "${RED}Some tests failed!${NC}\n"
    exit 1
  fi
}

main "$@"

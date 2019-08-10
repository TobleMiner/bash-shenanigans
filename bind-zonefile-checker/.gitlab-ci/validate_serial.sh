#!/usr/bin/env bash

# Copyright 2019 Tobias Schramm

# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.



# This script is designed to be used with Gitlab CI. It checks commits
# on repositiories containing bind zonefiles for correct incrementation
# of the serial in SOA records.

# LIMITATIONS
# This script can not handle multiple SOA records in a single zonefile. It will
# only detect the first one and thus only compare the first serial.

set -e

# Print to stderr if VERBOSE is set
debug() {
  [[ -n "$VERBOSE" ]] && error $@ || true
}

# Print to stderr
error() {
  ( >&2 echo "$@" )
}

is_whitespace() {
  [[ "$1" == "$(echo -n "$1" | egrep '^[[:space:]]+$')" ]]
}

is_comment() {
  [[ "$1" == ';' ]]
}

is_quote() {
  [[ "$1" == '"' ]]
}

is_escaped() {
  [[ "$1" == '\' ]]
}

is_brace_open() {
  [[ "$1" == '(' ]]
}

is_brace_close() {
  [[ "$1" == ')' ]]
}

is_brace() {
  is_brace_open "$1" || is_brace_close "$1"
}

is_numeric() {
  grep '^[0-9]*$' <<< "$1" > /dev/null
}

QUOTED=''
is_quoted() {
  [[ -n "$QUOTED" ]]
}

# Check if there are no unfinished strings and braces are balanced
is_line_finished() {
  local nesting=0

  # Check if we are still in a quoted section.
  if is_quoted; then
    # Line can't end while still quoted, fail
    return 1
  fi

  for token in "${TOKENS[@]}"; do
    # Increment nesting by one for each opening brace
    if is_brace_open "$token"; then
      (( nesting++ )) || true
    fi
    # Decrement nesting by one for each closing brace
    if is_brace_close "$token"; then
      (( nesting-- )) || true
    fi

    # Abort immediately if there are more closing than opening braces
    if [[ "$nesting" -lt 0 ]]; then
      return 1
    fi
  done
  # Return 0 if braces are balanced
  [[ "$nesting" -eq 0 ]]
}

# Break line from a zonefile into its elements.
# Elements seperated by whitespace are handled as separate tokens
# Notable exceptions to this are:
#   Tokens seperated by escaped (\ ) whitespace
#   Tokens enclosed in quotation marks ("foo bar baz")
#   Braced that are neither escaped not enclosed in quotes. Those are always separate tokens
# Terminates on end of line or unescaped, unquoted comment denoted by ';'
# Result is appended to global array TOKENS
TOKENS=()
TOKEN=''
tokenize() {
  local line="$1"     # Line to parse
  local last_char=''  # Character read in last iteration
  local i
  # Parse line chracter by character
  for (( i=0; i<${#line}; i++ )); do
    local chr="${line:$i:1}"

    # Check wether we are currently in a quoted section
    if is_quoted; then
      # The only special character inside a quoted section is '"'
      if ! is_escaped "$last_char"; then
        if is_quote "$chr"; then
            QUOTED=''
            continue
        fi
      fi
    else
      # All escaped characters are to be copied verbatim
      if ! is_escaped "$last_char"; then
        # Check if we are at the start of a quoted section
        if is_quote "$chr"; then
          QUOTED=yes
          continue
        fi

        # Check if this is the start of a comment
        if is_comment "$chr"; then
          break;
        fi

        # Check if we have a brace
        if is_brace "$chr"; then
          if [[ -n "$TOKEN" ]]; then
            TOKENS+=("$TOKEN")
            TOKEN=''
          fi
          # Make brace a separate token
          TOKENS+=("$chr")
          last_char=''
          continue
        fi

        # Check if current character is whitespace
        if is_whitespace "$chr"; then
          # Create a new token if token buffer is not empty
          if [[ -n "$TOKEN" ]]; then
            TOKENS+=("$TOKEN")
            TOKEN=''
          fi
          last_char=''
          continue
        fi

      fi
    fi

    # No special handling required, append character to token buffer
    TOKEN="${TOKEN}${chr}"
    last_char="$chr"
  done
  # If we are still in a quoted section we must add add a newline to the token
  # buffer since we are in a verbatim string
  if is_quoted; then
    TOKEN+=$'\n'
  else
    if [[ -n "$TOKEN" ]]; then
      TOKENS+=("$TOKEN")
    fi
  fi
}

# Reset global state of tokenizer
reset_tokenizer() {
  TOKENS=()
  TOKEN=''
  QUOTED=''
}

# Check wether global array TOKENS contains token $1
has_token() {
  local i
  for (( i=0; i<${#TOKENS[@]}; i++ )); do
    token="${TOKENS[$i]}"
    if [[ "${token,,}" == "${1,,}" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

# Serial extraction subroutine.
# Expects global array TOKENS to be initialized with the first
# line of a SOA record
# Fails if serial can't be found
# Returns the serial if it has been found
extract_serial_sub() {
  local zone="$1"                          # Full zonefile
  local linenum="$2"                       # Line to start parsing at
  local soa_token="$3"                     # Index of token 'SOA' inside global token array
  local serial_token="$((soa_token + 4))"  # Calvulated index of serial token in global token array (always at fixed offset, see RFC1035)
  local i=0
  while read line; do
    # Skip to line after $linenum
    if [[ "$i" -gt "$linenum" ]]; then
      debug "sub: $line $i"
      # Append tokens of this line to global array TOKENS
      tokenize "$line"
      # Check if line has ended, this denotes the end of the record
      if is_line_finished; then
        # Check if index of serial token is outside global token array, then fail
        if [[ "${#TOKENS[@]}" -le "$serial_token" ]]; then
          return 1
        fi
        # Return what is probably the serial
        echo "${TOKENS[$serial_token]}"
        return 0
      fi
    fi
    (( i++ )) || true
  done <<< "$zone"
  return 1
}

# Extracts the serial from zonefile passed as $1
extract_serial() {
  zone="$1"
  local i=0
  while read line; do
    debug "main: $line $i"
    # Reset global tokenizer state
    reset_tokenizer
    # Tokenize line
    tokenize "$line"
    set +e
    # Check if line has a SOA token
    soa_token="$(has_token soa)"
    soa_found="$?"
    set -e
    # If line contains a SOA token it might be start of a SOA record
    if [[ "$soa_found" -eq 0 ]]; then
      set +e
      # Break out parsing of the rest of the record into subroutine
      # This allows us to continue scanning if the serial is not found
      # with no additional setupo required
      serial="$(extract_serial_sub "$zone" "$i" "$soa_token")"
      serial_found="$?"
      set -e
      # Return immediately if serial has been found
      if [[ "$serial_found" -eq 0 ]]; then
        echo "$serial"
        return 0
      fi
    fi
    (( i++ )) || true
  done <<< "$zone"
  # Serial not found, fail
  return 1
}

# Check wether file $1 existes at git revision $2
exists_at() {
  file="$1"
  rev="$2"
  git cat-file -e "$rev":"$file" &> /dev/null
}

# Cat file $1 at git revision $2
cat_at() {
  file="$1"
  rev="$2"
  git show "$rev":"$file"
}

# Construct a associative array by the name of $1 that
# contains all values of the global array $ZONEFILES as
# keys and the serials found in those zonefiles as values
# $2 is the git revision to be used
serial_hash() {
  hash="$1"
  rev="$2"
  local i
  for (( i=0; i < ${#ZONEFILES[@]}; i++ )); do
    file="${ZONEFILES[$i]}"
    debug "processing: $file"
    if exists_at "$file" "$rev"; then
      debug "hash_key: $i => $file"
      set +e
      # Extract serial from zonefile at specified git revision
      serial="$(extract_serial "$(cat_at "$file" "$rev")")"
      serial_found="$?"
      set -e
      if [[ "$serial_found" -eq 0 ]]; then
        debug "hash_value: $serial"
        # Set serial
        declare -g "$hash[$i]"="$serial"
        continue
      fi
    fi
    # File not found/no serial found, set value to empty serial
    declare -g "$hash[$i]"=''
    error "Warning: \"$file\" does not have a serial"
  done
}

# Check git hash for validity
# Sometimes Gitlab sets a hash of 0 instead of leaving
# an environment variable blank
valid_hash() {
  [[ -n "$1" ]] && [[ "$(( 16#$1 ))" -ne 0 ]]
}

# Check if a file is a zonefile
# If there is neither a serial pre, nor post commit
# it is probably not a zonefile
is_zonefile() {
  [[ -n "${SERIALS_PRE[$1]}" ]] || [[ -n "${SERIALS_POST[$1]}" ]]
}


usage() {
  error "Usage: $1 [-f <reg>]"
  error "    -f <reg>: Include only files whose name matches <reg> in checks. <reg> is a regular expression. May be specified multiple times"
  exit 1
}

file_filter=()
# Parse command line options
while getopts 'f:h' opt; do
  case "$opt" in
    f)
      file_filter+=("$OPTARG")
      ;;
    *)
      usage
      ;;
  esac
done

# Choose origin of check commit
PRE_HEAD='HEAD~'
if [[ -n "$CI_MERGE_REQUEST_TARGET_BRANCH_NAME" ]]; then
  # In merge requests only this variable is set
  # There is a bunch more variables that look like
  # they should be pointing to an exact revision
  # for merge requests but empirical testing has
  # shown that those are simply empty in most cases
  PRE_HEAD=origin/"$CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
fi

# Choose current head
POST_HEAD='HEAD'
if valid_hash "$CI_COMMIT_SHA"; then
  # Probably mostly the same as HEAD but Gitlab
  # helpfully provides the exact hash thus we use
  # it
  POST_HEAD="$CI_COMMIT_SHA"
fi

echo "Detecting changed files... ($PRE_HEAD...$POST_HEAD)"
ZONEFILES=()
files_changed="$(git diff --raw --name-only "$PRE_HEAD" "$POST_HEAD")"
i=0
# Build list of changed files
while read zonefile; do
  # Check if there are any file name filters in place
  if [[ ${#file_filter[@]} -gt 0 ]]; then
    # Apply fitler regexes to filenames
    match=''
    for filter in "${file_filter[@]}"; do
      if grep "$filter" <<< "$zonefile" > /dev/null; then
        match=yes
        break
      fi
    done
    # Check if one of the regexes matched the current file
    if [[ -z "$match" ]]; then
      # Continue outer loop if there was no match
      continue
    fi
  fi
  echo "File \"$zonefile\" changed"
  ZONEFILES+=("$zonefile")
  (( i++ )) || true
done <<< "$files_changed"

if [[ ${#ZONEFILES[@]} -eq 0 ]]; then
  echo "No zonefiles changed. Exiting"
  exit 0
fi

debug "$(declare -p ZONEFILES)"

echo "Parsing current zonefiles..."
declare -A SERIALS_POST
serial_hash SERIALS_POST "$POST_HEAD"

debug "$(declare -p SERIALS_POST)"


# Checking loop
# Runs up to 10 times traversing deeper and deeper into
# the check commits parents in case the check commit
# itself is broken
post_process=()
attempts=0
while [[ "$attempts" -lt 10 ]]; do

  echo "Parsing old zonefiles..."
  declare -A SERIALS_PRE
  serial_hash SERIALS_PRE "$PRE_HEAD"
  debug "$(declare -p SERIALS_PRE)"

  fail=''
  last_post_process=("${post_process[@]}")
  post_process=()
  # Assume there is no further processing to be done
  finished=yes
  for (( i=0; i < ${#ZONEFILES[@]}; i++ )); do
    post_process["$i"]=''
    # Process only files that need post processing on all runs of the outer loop but the first
    if [[ ${#last_post_process[@]} -gt 0 ]]; then
      if [[ -z "${last_post_process[$i]}" ]]; then
        continue;
      fi
    fi

    zonefile="${ZONEFILES[$i]}"
    # Evict files that are probably not zonefiles from checklist
    if ! is_zonefile "$i"; then
      echo "File \"$zonefile\" does not seem to be a valid zonefile, skipping"
      continue
    fi

    serial_pre="${SERIALS_PRE[$i]}"
    serial_post="${SERIALS_POST[$i]}"
    # Check if something that should be a zonefile does not have a serial, this should not happen
    if exists_at "$zonefile" "$POST_HEAD"  && [[ -z "$serial_pre" ]]; then
      error "Warning: File \"$zonefile\" exists post-commit but has no serial"
    fi

    # Check if check commit has valid serial
    if ! is_numeric "$serial_pre"; then
      error "Error: Pre serial is invalid, adding \"$zonefile\" to post processing"
      post_process["$i"]="$zonefile"
      # We must do some post processing, the check commit itself was bad
      finished=''
      continue
    fi

    # Check if commited zonefile has bad serial
    if ! is_numeric "$serial_post"; then
      error "Error: File \"$zonefile\" has invalid, non-numeric serial \"$serial_post\""
      fail=yes
      continue
    fi

    # Check if commited zonefile has incremented serial compared to zonefile at check commit
    if [[ -n "$serial_pre" ]] && [[ -n "$serial_post" ]] && is_numeric "$serial_pre"; then
      if [[ "$serial_post" -le "$serial_pre" ]]; then
        error "Error: File \"$zonefile\" has invalid serial: $serial_post (new) <= $serial_pre (old)"
        fail=yes
        continue
      fi
    fi

    # Zonefile seems to be fine
    echo "File \"$zonefile\" is OK ($serial_post (new) > $serial_pre (old))"
  done

  if [[ -n "$finished" ]]; then
    break
  fi

  PRE_HEAD="$PRE_HEAD~"

  # Since we traverse the git history there might be situations where we hit the root
  # commit. Since we can't go back any further just abort and fail (finished not set)
  if ! git rev-parse "$PRE_HEAD" &> /dev/null; then
    error "Can't roll history back any further"
    break
  fi
done

# Check if the zonefile checks did finish, set failure flag if the didn't
if [[ -z "$finished" ]]; then
  error "Failed to find previous revision of zonefile with valid serial. Giving up"
  fail=yes
fi

# Check failure flag only at the very end
# This ensures that all error messages have been delivered
if [[ -n "$fail" ]]; then
  exit 1
fi

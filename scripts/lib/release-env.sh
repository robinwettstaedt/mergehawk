# shellcheck shell=bash
# Shared loader for MergeHawk release env files.
#
# Parses a KEY=value file as inert data (never `source`d, so file contents are
# never executed) and exports only keys in a caller-supplied allowlist. Source
# this file, then call:
#
#   load_release_env_file <file> <allowed-key> [<allowed-key> ...]
#
# Missing files are ignored. Unsupported syntax or keys outside the allowlist
# abort with exit 2.

load_release_env_file() {
  local file="$1"
  shift
  local allowed_keys=("$@")
  local line
  local line_number=0
  local key
  local value
  local allowed

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "Unsupported release env syntax in $file:$line_number" >&2
      exit 2
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    allowed=0
    local candidate
    for candidate in "${allowed_keys[@]}"; do
      if [[ "$candidate" == "$key" ]]; then
        allowed=1
        break
      fi
    done
    if [[ "$allowed" != 1 ]]; then
      echo "Unsupported release env key in $file:$line_number: $key" >&2
      exit 2
    fi

    printf -v "$key" '%s' "$value"
    export "$key"
  done < "$file"
}

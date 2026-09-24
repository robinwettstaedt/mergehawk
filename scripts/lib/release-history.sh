#!/usr/bin/env bash

list_published_release_tags() {
  local repository="$1"
  gh api --paginate "repos/$repository/releases" \
    --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name'
}

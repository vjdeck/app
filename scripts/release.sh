#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release.sh patch|minor|major|VERSION [--dry-run]

Examples:
  scripts/release.sh patch
  scripts/release.sh 1.6.0
  scripts/release.sh minor --dry-run

Publishes VJDeck to the public vjdeck/site GitHub Releases. Installed
copies check that repository on launch and update themselves from the
VJDeck-VERSION.zip asset; VJDeck.dmg is for manual installs.

Run from a clean main that matches origin/main. The script bumps
Resources/Info.plist, builds Release, re-signs ad hoc, packages the zip and DMG,
commits "Bump version to vVERSION", tags and pushes it, and creates the release.
The matching "## [VERSION]" section of CHANGELOG.md becomes the release notes.
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

validate_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)[.](0|[1-9][0-9]*)[.](0|[1-9][0-9]*)$ ]]
}

semver_gt() {
  local left="$1"
  local right="$2"
  local left_major left_minor left_patch
  local right_major right_minor right_patch

  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"

  (( left_major > right_major )) && return 0
  (( left_major < right_major )) && return 1
  (( left_minor > right_minor )) && return 0
  (( left_minor < right_minor )) && return 1
  (( left_patch > right_patch ))
}

SITE_REPO="vjdeck/site"
APP_NAME="VJDeck"
info_plist="Resources/Info.plist"
plistbuddy="/usr/libexec/PlistBuddy"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$repo_root"

target=""
dry_run=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --dry-run)
      dry_run=1
      ;;
    major|minor|patch|v[0-9]*|[0-9]*)
      [[ -z "$target" ]] || die "specify only one version target"
      target="${arg#v}"
      ;;
    *)
      usage >&2
      die "unknown argument: $arg"
      ;;
  esac
done
[[ -n "$target" ]] || { usage >&2; exit 64; }

current_version="$("$plistbuddy" -c "Print :CFBundleShortVersionString" "$info_plist")"
current_build="$("$plistbuddy" -c "Print :CFBundleVersion" "$info_plist")"
validate_semver "$current_version" || die "current version is not x.y.z: $current_version"
[[ "$current_version" == "$current_build" ]] \
  || die "CFBundleShortVersionString ($current_version) and CFBundleVersion ($current_build) differ"

case "$target" in
  major|minor|patch)
    IFS=. read -r major minor patch <<<"$current_version"
    case "$target" in
      major) (( major += 1 )); minor=0; patch=0 ;;
      minor) (( minor += 1 )); patch=0 ;;
      patch) (( patch += 1 )) ;;
    esac
    version="$major.$minor.$patch"
    ;;
  *)
    version="$target"
    validate_semver "$version" || die "target version is not x.y.z: $version"
    ;;
esac
semver_gt "$version" "$current_version" || die "target version $version must be greater than current version $current_version"

tag="v$version"
out_dir="$repo_root/build/release"
zip="$out_dir/$APP_NAME-$version.zip"
dmg="$out_dir/$APP_NAME.dmg"
notes="$(awk -v heading="## [$version]" '
  $0 == heading || index($0, heading " ") == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
  END { if (!found) exit 1 }
' CHANGELOG.md)" || die "add a ## [$version] section to CHANGELOG.md before releasing"
[[ -n "${notes//[[:space:]]/}" ]] || die "CHANGELOG.md [$version] must contain release notes"

if [[ "$dry_run" == "1" ]]; then
  echo "Current version: $current_version"
  echo "Next version:    $version"
  echo "Commit message:  Bump version to $tag"
  echo "Tag:             $tag"
  echo "Release:         https://github.com/$SITE_REPO/releases/tag/$tag"
  echo "Assets:          $(basename "$dmg"), $(basename "$zip")"
  echo "Notes:           CHANGELOG.md [$version]"
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh is required: brew install gh"
gh auth status >/dev/null 2>&1 || die "gh is not logged in: gh auth login"
[[ "$(gh api "repos/$SITE_REPO" --jq '.permissions.push // false')" == true ]] \
  || die "the gh token needs write access to $SITE_REPO"
[[ "$(git branch --show-current)" == main ]] || die "run from the main branch"
[[ -z "$(git status --porcelain)" ]] || die "working tree must be clean before releasing"
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main must match origin/main"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  die "tag already exists: $tag"
fi
if gh release view "$tag" -R "$SITE_REPO" >/dev/null 2>&1; then
  die "release already exists in $SITE_REPO: $tag"
fi

echo "Releasing $tag..."

# Keep a recoverable state and print exact commands after any partial publication.
release_committed=0
notes_file="$out_dir/notes-$version.md"
finish_release() {
  local status=$?
  trap - EXIT
  if [[ "$status" != 0 ]]; then
    if [[ "$release_committed" == 0 ]]; then
      git restore --source=HEAD --staged --worktree -- "$info_plist"
      echo 'Release stopped before committing; the version file was restored.' >&2
    else
      echo 'Release stopped after committing. Finish it with these commands:' >&2
      if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        printf '  git tag -a %q -m %q\n' "$tag" "VJDeck $tag" >&2
      fi
      printf '  git push --atomic origin main %q\n' "$tag" >&2
      if gh release view "$tag" -R "$SITE_REPO" >/dev/null 2>&1; then
        printf '  gh release upload %q %q %q -R %q --clobber\n' "$tag" "$dmg" "$zip" "$SITE_REPO" >&2
        printf '  gh release edit %q -R %q --title %q --notes-file %q\n' "$tag" "$SITE_REPO" "$tag" "$notes_file" >&2
      else
        printf '  gh release create %q %q %q -R %q --title %q --notes-file %q\n' \
          "$tag" "$dmg" "$zip" "$SITE_REPO" "$tag" "$notes_file" >&2
        echo '  If the release was partially created, use gh release upload --clobber instead.' >&2
      fi
    fi
  fi
  exit "$status"
}
trap finish_release EXIT
mkdir -p "$out_dir"
printf '%s\n' "$notes" >"$notes_file"
"$plistbuddy" \
  -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $version" \
  "$info_plist"

derived_data="$repo_root/build/DerivedData"
"$repo_root/scripts/build-dmg.sh" --derived-data "$derived_data" --output "$dmg"
app="$derived_data/Build/Products/Release/$APP_NAME.app"

built="$("$plistbuddy" -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
[[ "$built" == "$version" ]] || die "built app reports version $built"

# The updater unpacks VJDeck.app from this zip; the DMG keeps the drag-to-Applications install.
ditto -c -k --keepParent "$app" "$zip"

git commit --quiet -m "Bump version to $tag" "$info_plist"
release_committed=1
git tag -a "$tag" -m "VJDeck $tag"
git push --atomic --quiet origin main "$tag"

gh release create "$tag" "$dmg" "$zip" -R "$SITE_REPO" --title "$tag" --notes-file "$notes_file"
echo "Published https://github.com/$SITE_REPO/releases/tag/$tag"

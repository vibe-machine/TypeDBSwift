#!/usr/bin/env bash
#MISE description="Tag a semver release and optionally push"
#MISE alias="r"
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: mise run release <version>"
    echo "  e.g. mise run release 0.1.0"
    exit 1
fi

VERSION="$1"

# Validate semver format
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?(\+[a-zA-Z0-9.]+)?$ ]]; then
    echo "Error: '$VERSION' is not valid semver. Expected: MAJOR.MINOR.PATCH[-prerelease]"
    exit 1
fi

TAG="v$VERSION"

# Check working tree is clean
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: Working tree is not clean. Commit or stash changes first."
    git status --short
    exit 1
fi

# Warn if not on main
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" != "main" ]]; then
    echo "Warning: You are on branch '$BRANCH', not 'main'."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check tag doesn't already exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: Tag '$TAG' already exists."
    exit 1
fi

# Create annotated tag
echo "Creating tag $TAG..."
git tag -a "$TAG" -m "Release $VERSION"
echo "Tag $TAG created."

# Ask whether to push
echo ""
read -p "Push tag to origin? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    git push origin "$TAG"
    echo ""
    echo "Tag $TAG pushed to origin."
    echo ""
    echo "Next steps:"
    echo "  1. Go to https://github.com/vibe-machine/TypeDBSwift/releases"
    echo "  2. Create a release from tag $TAG"
    echo "  3. Add release notes from CHANGELOG.md"
else
    echo ""
    echo "Tag created locally. To push later:"
    echo "  git push origin $TAG"
fi

echo ""
echo "Consumers can now add this package:"
echo "  .package(url: \"https://github.com/vibe-machine/TypeDBSwift.git\", from: \"$VERSION\")"

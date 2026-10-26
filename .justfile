bundle_id := "com.guilospanck.goom"

# Build build/Goom.app
build:
    ./scripts/build-app.sh

# Reset camera/mic/screen-recording permissions for Goom (and the old bundle id)
reset-permissions:
    tccutil reset All com.example.goom || true
    tccutil reset All {{bundle_id}}

# Build and open the app
run: build
    open build/Goom.app

# Build and install to /Applications (stable path helps macOS keep permissions)
install: build
    -pkill -x Goom
    rm -rf /Applications/Goom.app
    cp -R build/Goom.app /Applications/Goom.app
    open /Applications/Goom.app

# Lint the Homebrew cask CI will publish (style + deprecation checks).
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v brew >/dev/null || { echo "✗ install Homebrew to lint the cask: https://brew.sh" >&2; exit 1; }
    # Render under a Casks/ dir so `brew style` recognizes it as a cask and
    # applies the cask cops (a loose .rb elsewhere gets the generic Ruby
    # ruleset instead).
    # Version/sha are placeholders; neither affects style.
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    mkdir -p "$tmp/Casks"
    ./scripts/render-cask.sh 0.0.0 "$(printf '%064d' 0)" > "$tmp/Casks/goom.rb"
    prefix="$(brew --prefix)"
    library="$prefix/Library/Homebrew"
    if [[ -d "$library" && "$(cd "$library" && pwd -P)" == /nix/store/* ]]; then
        # Homebrew installs lint gems inside its own Library. Nix's copy is
        # immutable, so run the same code from a disposable writable copy.
        source_repo="$(cd -P "$library" && cd ../.. && pwd -P)"
        mkdir -p "$tmp/brew"
        cp -R "$source_repo/." "$tmp/brew/"
        chmod -R u+w "$tmp/brew"
        HOMEBREW_PREFIX="$prefix" \
        HOMEBREW_REPOSITORY="$tmp/brew" \
        HOMEBREW_LIBRARY="$tmp/brew/Library" \
        HOMEBREW_BREW_FILE="$(command -v brew)" \
        HOMEBREW_USER_CONFIG_HOME="$tmp/brew/config" \
        HOMEBREW_DEVELOPER=1 HOMEBREW_NO_AUTO_UPDATE=1 \
            /bin/bash "$tmp/brew/Library/Homebrew/brew.sh" style "$tmp/Casks/goom.rb"
    else
        brew style "$tmp/Casks/goom.rb"
    fi
    echo "✓ cask lint clean"

# Bump the version, commit, tag, and push — triggers the Release workflow.
# Optional notes (Markdown) go into the annotated tag and appear at the top of
# the GitHub Release, above the auto-generated changelog.
# Usage: just tag 1.1
#        just tag 1.1 "Fixes the camera bubble."
tag version $notes="":
    #!/usr/bin/env bash
    set -euo pipefail
    ver="{{version}}"
    if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        echo "✗ version must look like 1.1 or 1.1.0 (got '$ver')" >&2; exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "✗ working tree not clean — commit or stash first." >&2; exit 1
    fi
    if git rev-parse "v$ver" >/dev/null 2>&1; then
        echo "✗ tag v$ver already exists." >&2; exit 1
    fi
    # Pre-flight: require a successful app build and cask lint before releasing.
    just build
    just lint
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ver" Resources/Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ver" Resources/Info.plist
    git add Resources/Info.plist
    git commit -m "Release v$ver"
    # `notes` arrives as an environment variable (the `$` on the parameter), so
    # quotes, backticks, and newlines in it pass through untouched.
    if [[ -n "${notes//[[:space:]]/}" ]]; then
        git tag -a "v$ver" --cleanup=verbatim -m "$notes"
    else
        git tag "v$ver"
    fi
    git push origin HEAD
    git push origin "v$ver"
    echo "✓ Pushed v$ver — CI will build, release, and update the tap."

# One-time: create a write-scoped deploy key for the tap and store its private
# half as a secret in this repo, so CI can push the cask. Needs gh (authed).
# Usage: just setup-tap-key
setup-tap-key:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v gh >/dev/null || { echo "✗ install gh first: brew install gh" >&2; exit 1; }
    umask 077
    tmp="$(mktemp -d)"
    trap 'rm -rf -- "$tmp"' EXIT
    ssh-keygen -t ed25519 -N "" -C "goom release CI" -f "$tmp/key" >/dev/null
    gh repo deploy-key add "$tmp/key.pub" \
        -R Guilospanck/homebrew-tap \
        --title "goom release CI" \
        --allow-write
    if ! gh secret set HOMEBREW_TAP_DEPLOY_KEY \
        -R Guilospanck/goom < "$tmp/key"; then
        echo "✗ Failed to store the private key; removing the deploy key from homebrew-tap." >&2
        public_key="$(awk '{print $1 " " $2}' "$tmp/key.pub")"
        key_id="$(gh repo deploy-key list \
            -R Guilospanck/homebrew-tap \
            --json id,key \
            --jq ".[] | select(.key == \"$public_key\") | .id" || true)"
        if [[ -n "$key_id" ]] && gh repo deploy-key delete "$key_id" -R Guilospanck/homebrew-tap; then
            echo "✓ Removed the deploy key." >&2
        else
            echo "⚠ Could not remove the deploy key automatically; remove it from homebrew-tap manually." >&2
        fi
        exit 1
    fi
    echo "✓ Deploy key added to homebrew-tap (write) and stored as HOMEBREW_TAP_DEPLOY_KEY."

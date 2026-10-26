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

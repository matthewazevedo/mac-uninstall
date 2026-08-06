# Contributing

Build and test instructions live in the README's **Build and run** section. This file
covers the parts only a maintainer needs: cutting a release, and rehearsing an update
before one goes out.

## Releasing

Tag a version and the workflow in `.github/workflows/release.yml` builds, signs,
notarises, staples, signs the appcast, and publishes the disk image and the feed:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The tag is the version. `Scripts/build-app.sh` derives `CFBundleShortVersionString` and
`CFBundleVersion` from it, because Sparkle decides whether an update is newer by
comparing `CFBundleVersion` — it has to be a plain dotted number that sorts correctly.
A build ahead of the last tag becomes `0.1.0.<commits>`, which sorts above `0.1.0` and
below `0.1.1`, so a development build never compares equal to the release it came from.

It needs six repository secrets — the certificate, the Apple credentials, and the
Sparkle signing key — listed at the top of that workflow file. They are never committed;
the signing certificate is imported into a throwaway keychain that lives for one job.

Losing the Sparkle private key means no existing install can ever be updated again, so
keep a copy somewhere other than the keychain that holds it.

## Rehearsing an update

To exercise the whole update path against a local feed before shipping:

```bash
# Build the "new" version and sign an appcast for it, exactly as CI does.
MACUNINSTALL_VERSION=0.2.0 Scripts/build-app.sh release && Scripts/make-dmg.sh
mkdir -p /tmp/feed && cp dist/MacUninstall.dmg /tmp/feed/
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --download-url-prefix "http://localhost:8137/" /tmp/feed
(cd /tmp/feed && python3 -m http.server 8137 --bind 127.0.0.1) &

# Build an older copy that looks at that feed, run it, and check for updates.
MACUNINSTALL_VERSION=0.1.0 \
MACUNINSTALL_FEED_URL="http://localhost:8137/appcast.xml" \
MACUNINSTALL_BUILD_DIR=/tmp/old Scripts/build-app.sh release
open /tmp/old/MacUninstall.app
```

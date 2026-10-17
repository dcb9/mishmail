# OSS Scanner build for MishMail (https://github.com/ronboger/mishmail).
#
# MishMail is a macOS 14+ SwiftUI/AppKit application. It builds with
# xcodebuild (project.yml -> XcodeGen -> MishMail.xcodeproj), which exists
# only on macOS, so there is no compilation step possible in this Linux
# container. This image instead gives the scanner the checked-out source, a
# Swift toolchain (for `swiftc -parse` syntax checks and small standalone
# Foundation-only reproducers), and the app's one dependency fetched while
# the build still has network access.
FROM swift:6.4.1-bookworm
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git python3 sqlite3 \
    && rm -rf /var/lib/apt/lists/*

# scanner contract: the checkout lives inside the image, at /src
COPY . /src
WORKDIR /src

# The app's only SwiftPM dependency is GRDB (duckduckgo fork, exactVersion
# 3.0.0 in project.yml). Fetch it now so the audit can read the API the SQL
# in Sources/MishMail/Store is built on; nothing is reachable after this.
RUN git clone --depth 1 --branch 3.0.0 \
      https://github.com/duckduckgo/GRDB.swift /deps/GRDB

# In place of a build: parse every Swift source file. `swiftc -parse` does
# no type checking and resolves no imports, so the macOS-only frameworks
# (SwiftUI, AppKit, WebKit, Network, Keychain) are not a problem, and each
# file checked alone parses as a main file (top-level statements allowed).
# A file that fails to parse is reported but does not fail the image build:
# the checked-out sources are what the scanner audits.
RUN find Sources Tests -name '*.swift' | sort > /tmp/sources.list \
    && failed=0 \
    && while IFS= read -r file; do \
         swiftc -parse "$file" >/dev/null 2>&1 \
           || { echo "PARSE FAIL: $file"; failed=$((failed + 1)); }; \
       done < /tmp/sources.list \
    && echo "swiftc -parse: $failed file(s) failed to parse"

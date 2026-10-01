#!/usr/bin/env bash
# Build an extracted IntelliJ IDEA 2019.3.5 distribution into a browser app
# with openjdk21-wasm-link.
#
#   bash build-idea.sh [IDEA_DIR] [OUT_HTML]
#
# Run it from the directory that contains emenv/ and javaenv/.
set -euo pipefail

IDEA_DIR=${1:-../intellij-cheerpj/intellij/intellij}   # extracted distribution (lib/, plugins/, bin/)
OUT=${2:-out/intellij.html}
IDEA_VFS=/files/intellij     # where it appears inside the virtual file system

# Same short classpath the stock bin/idea.sh uses (check: grep CLASSPATH bin/idea.sh).
# IDEA's bootstrap builds its own class loader from the rest of lib/*.jar.
CP=""
for j in bootstrap extensions util jdom log4j trove4j jna; do
  CP+="${CP:+:}$IDEA_VFS/lib/$j.jar"
done

args=()
add() { local a; for a in "$@"; do args+=(--arg "$a"); done; }

# JVM options. These must come BEFORE the main class to act as system properties.
add -Xmx768m

# IDEA 2019.3 targets Java 8/11; on JDK 21 its reflection into JDK internals
# needs explicit opens. Add any further package named in an
# InaccessibleObjectException.
OPENS=(
  java.base/java.io java.base/java.lang java.base/java.lang.reflect
  java.base/java.net java.base/java.nio java.base/java.util
  java.base/java.util.concurrent java.base/sun.nio.ch java.base/sun.nio.fs
  java.desktop/java.awt java.desktop/java.awt.event java.desktop/java.awt.peer
  java.desktop/javax.swing java.desktop/javax.swing.plaf.basic
  java.desktop/javax.swing.text.html
  java.desktop/sun.awt java.desktop/sun.font java.desktop/sun.java2d
  java.desktop/sun.swing
)
for m in "${OPENS[@]}"; do add "--add-opens=$m=ALL-UNNAMED"; done

add \
  -Didea.home.path=$IDEA_VFS \
  -Didea.platform.prefix=Idea \
  -Dnosplash=true \
  -Dswing.systemlaf=javax.swing.plaf.metal.MetalLookAndFeel \
  -Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel \
  -Didea.native.transparent.window.supported=false \
  -Didea.no.launcher=true \
  -Dide.browser.jcef.enabled=false \
  -Didea.initially.ask.config=never \
  -Djb.consents.confirmation.enabled=false \
  -Didea.initially.ask.eula=false \
  -Djb.privacy.policy.text= \
  -Didea.suppress.statistics.report=true \
  -Didea.config.path=/files/config \
  -Didea.system.path=/files/system \
  -Didea.log.path=/files/log \
  -Didea.plugins.path=/files/plugins \
  -Djava.io.tmpdir=/tmp \
  -Djna.boot.library.path= \
  -Djna.nosys=true \
  -Djna.noclasspath=true \
  -Ddisable.fs.notifier=true \
  -Dide.native.launcher=false \
  -Dsun.io.useCanonCaches=false

# --- process-spawn stub -------------------------------------------------------
# The wasm JVM cannot start processes (posix_spawn fails with ENOSYS), but IDEA's
# startup check runs a test script from idea.system.path/tmp and refuses to start
# if that fails. This replaces java.lang.ProcessImpl via --patch-module: the test
# script "runs" and exits 0; every other command throws IOException, as before.
# Needs a JDK 21 javac on the host (same major version as the wasm JDK).
command -v javac >/dev/null || { echo "build-idea: javac (JDK 21) not on PATH" >&2; exit 1; }
PATCH_SRC=build/process-patch-src
PATCH_OUT=build/process-patch
rm -rf "$PATCH_SRC" "$PATCH_OUT"
mkdir -p "$PATCH_SRC/java/lang" "$PATCH_OUT"
cat > "$PATCH_SRC/java/lang/ProcessImpl.java" <<'JAVA'
package java.lang;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Map;

/** Stand-in for a JVM that cannot create processes. */
final class ProcessImpl extends Process {

    static Process start(String[] cmdarray, Map<String, String> environment, String dir,
                         ProcessBuilder.Redirect[] redirects, boolean redirectErrorStream)
            throws IOException {
        // IDEA's startup self-check: a single argument, <system>/tmp/ij<digits>.tmp
        if (cmdarray.length == 1) {
            String name = new File(cmdarray[0]).getName();
            if (name.startsWith("ij") && name.endsWith(".tmp")) {
                return new ProcessImpl();
            }
        }
        throw new IOException("process creation is not supported on this platform");
    }

    private ProcessImpl() {}

    @Override public OutputStream getOutputStream() { return OutputStream.nullOutputStream(); }
    @Override public InputStream getInputStream() { return InputStream.nullInputStream(); }
    @Override public InputStream getErrorStream() { return InputStream.nullInputStream(); }
    @Override public int waitFor() { return 0; }
    @Override public int exitValue() { return 0; }
    @Override public void destroy() {}
}
JAVA
javac --patch-module java.base="$PATCH_SRC" -d "$PATCH_OUT" "$PATCH_SRC/java/lang/ProcessImpl.java"
add --patch-module=java.base=/app/process-patch

# Do not use --headless: IDEA needs the AWT/x11 build.
PATH="$PWD/emenv/bin:$PATH" ./javaenv/bin/openjdk21-wasm-link -o "$OUT" \
  --max-memory 4096 \
  --app "$IDEA_DIR@$IDEA_VFS" \
  --arg -cp --arg "$CP" \
  "${args[@]}" \
  --arg com.intellij.idea.Main \
  --arg nosplash
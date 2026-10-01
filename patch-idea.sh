#!/usr/bin/env bash
# Patches IDEA 2019.3's lib/platform-impl.jar for a wasm JVM (no processes, no sockets).
# Supersedes patch-startuputil.sh: this applies both patches, always starting from
# the pristine jar, so do not run the two scripts one after the other.
#
#   1. com.intellij.idea.StartupUtil
#        ProcessBuilder.start() -> null, Process.waitFor() -> 0
#        (the startup "can this directory run a script?" check)
#   2. com.intellij.idea.SocketLock
#        lockAndTryActivate -> reports "no other instance" without touching port
#        files or starting the Netty server; getServer -> null;
#        getServerFuture -> already-completed future holding null; dispose -> no-op
#        (the single-instance lock and its local server socket)
#
#   bash patch-idea.sh [IDEA_DIR]
#
# Needs a host JDK (javac, java, jar, javap). Override the javassist jar with
#   JAVASSIST=/path/to/javassist.jar bash patch-idea.sh
set -euo pipefail

IDEA_DIR=$(cd "${1:-../intellij/intellij}" && pwd)
LIB="$IDEA_DIR/lib"
JAR="$LIB/platform-impl.jar"
BACKUP="$IDEA_DIR/../platform-impl.jar.orig"   # outside IDEA_DIR so it is not packed
JAVASSIST=${JAVASSIST:-$(ls "$LIB"/javassist-*.jar | head -n1)}

[ -f "$BACKUP" ] || cp "$JAR" "$BACKUP"
cp "$BACKUP" "$JAR"

if ! javap -p -classpath "$JAR" 'com.intellij.idea.SocketLock$ActivationStatus' | grep -q NO_INSTANCE; then
  echo "patch-idea: SocketLock.ActivationStatus has no NO_INSTANCE constant; it has:" >&2
  javap -p -classpath "$JAR" 'com.intellij.idea.SocketLock$ActivationStatus' >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/Patch.java" <<'JAVA'
import javassist.*;
import javassist.expr.*;
import java.io.File;

public class Patch {
  static int starts = 0, waits = 0;

  public static void main(String[] a) throws Exception {
    String lib = a[0], out = a[1];
    ClassPool pool = new ClassPool(true);
    pool.insertClassPath(lib + "/platform-impl.jar");
    // the other jars let javassist resolve types while rebuilding stack maps
    for (File f : new File(lib).listFiles())
      if (f.getName().endsWith(".jar") && !f.getName().equals("platform-impl.jar"))
        pool.appendClassPath(f.getPath());

    // 1. StartupUtil: the exec check must not spawn a process
    CtClass su = pool.get("com.intellij.idea.StartupUtil");
    for (CtBehavior b : su.getDeclaredBehaviors()) {
      b.instrument(new ExprEditor() {
        public void edit(MethodCall c) throws CannotCompileException {
          String cls = c.getClassName(), m = c.getMethodName();
          if (cls.equals("java.lang.ProcessBuilder") && m.equals("start")) {
            c.replace("$_ = null;");
            starts++;
          } else if (cls.equals("java.lang.Process") && m.equals("waitFor")
                     && c.getSignature().equals("()I")) {
            c.replace("$_ = 0;");
            waits++;
          }
        }
      });
    }
    if (starts == 0) throw new Exception("no ProcessBuilder.start() call found in StartupUtil");
    su.writeFile(out);
    System.out.println("StartupUtil: " + starts + " start() call(s), " + waits + " waitFor() call(s) patched");

    // 2. SocketLock: no port files, no local server
    CtClass sl = pool.get("com.intellij.idea.SocketLock");
    body(sl, "lockAndTryActivate",
         "{ return com.intellij.openapi.util.Pair.create("
         + "com.intellij.idea.SocketLock.ActivationStatus.NO_INSTANCE, null); }");
    body(sl, "getServer", "{ return null; }");
    body(sl, "getServerFuture",
         "{ return java.util.concurrent.CompletableFuture.completedFuture(null); }");
    body(sl, "dispose", "{ }");
    sl.writeFile(out);
    System.out.println("SocketLock: lockAndTryActivate, getServer, getServerFuture, dispose replaced");
  }

  static void body(CtClass c, String name, String src) throws Exception {
    c.getDeclaredMethod(name).setBody(src);
  }
}
JAVA

javac -cp "$JAVASSIST" -d "$work" "$work/Patch.java"
java -cp "$work:$JAVASSIST" Patch "$LIB" "$work/out"
jar uf "$JAR" \
  -C "$work/out" com/intellij/idea/StartupUtil.class \
  -C "$work/out" com/intellij/idea/SocketLock.class

echo "ProcessBuilder.start calls left in StartupUtil (expect 0):"
javap -p -c -classpath "$JAR" com.intellij.idea.StartupUtil | grep -c 'ProcessBuilder.start' || true
echo "NO_INSTANCE references in SocketLock (expect at least 1):"
javap -p -c -classpath "$JAR" com.intellij.idea.SocketLock | grep -c 'NO_INSTANCE' || true
echo "done: $JAR"

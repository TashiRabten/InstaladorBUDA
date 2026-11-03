import com.example.glossariobuda.security.Capability;
import com.example.glossariobuda.security.DeveloperIdentity;
import com.example.glossariobuda.security.FixBundles;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.EnumSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

/**
 * Test fixture for tests/FixInbox.Tests.ps1: writes a signed .budafix the way TradutorBUDA's "Sugerir mudança"
 * does (FixBundles.write, as in its BundleToolTest), with TradutorBUDA's own classes on the class path.
 *
 * <pre>java -cp TradutorBUDA.jar MakeBundle.java OUT IDENTITY PASSWORD_ENV TITLE SLUG VERSION CAPS|- (PATH BASE|- CONTENT|-)…</pre>
 */
public class MakeBundle {
   public static void main(String[] a) throws Exception {
      DeveloperIdentity id = DeveloperIdentity.load(Path.of(a[1]));
      char[] password = System.getenv(a[2]).toCharArray();
      Set<Capability> caps = EnumSet.noneOf(Capability.class);
      List<String> lines = new ArrayList<>();
      if (!a[6].equals("-")) {
         for (String c : a[6].split(",")) {
            caps.add(Capability.valueOf(c));
            lines.add(c + ": acrescentado pelo pacote de teste");
         }
      }
      Map<String, String> base = new TreeMap<>();
      Map<String, byte[]> files = new TreeMap<>();
      for (int i = 7; i + 2 < a.length; i += 3) {
         if (!a[i + 1].equals("-")) base.put(a[i], a[i + 1]);
         files.put(a[i], a[i + 2].equals("-") ? null : Files.readAllBytes(Path.of(a[i + 2])));
      }
      FixBundles.write(Path.of(a[0]), new FixBundles.Contents("TradutorBUDA", a[5], a[3], "Descrição de teste: " + a[3], a[4],
            base, files, caps, lines), id, id.unlock(password));
   }
}

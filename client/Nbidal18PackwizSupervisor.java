import java.io.IOException;
import java.io.InputStream;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/**
 * Stable Prism pre-launch gate for nbidal18.
 *
 * The supervisor is intentionally tiny and stable. It promotes the update engine and its
 * launch dependencies only while they are not running, then runs the newest engine. If that
 * engine downloads an even newer staged engine, the supervisor promotes it and repeats before
 * returning to Prism. Prism therefore cannot start Minecraft from a partially updated release.
 */
public final class Nbidal18PackwizSupervisor {
    private static final int MAX_UPDATE_PASSES = 3;
    private static final long MAX_JAR_BYTES = 16L * 1024L * 1024L;
    private static final List<Promotion> PROMOTIONS = List.of(
            new Promotion("nbidal18-packwiz-updater.next.jar", "nbidal18-packwiz-updater.jar", MAX_JAR_BYTES),
            new Promotion("packwiz-installer-bootstrap.next.jar", "packwiz-installer-bootstrap.jar", MAX_JAR_BYTES),
            new Promotion("packwiz-installer.next.jar", "packwiz-installer.jar", MAX_JAR_BYTES));

    private Nbidal18PackwizSupervisor() {
    }

    public static void main(String[] args) {
        try {
            Path root = minecraftRoot();
            Path java = currentJava();
            for (int pass = 1; pass <= MAX_UPDATE_PASSES; pass++) {
                promoteAll(root);
                int result = runUpdater(root, java);
                if (result != 0) {
                    System.exit(result);
                }
                if (!promoteAll(root)) {
                    System.exit(0);
                }
                System.out.println("[nbidal18 supervisor] A newer update engine was staged; validating with it before Minecraft starts.");
            }
            throw new IOException("The update engine changed repeatedly and did not stabilize after "
                    + MAX_UPDATE_PASSES + " passes.");
        } catch (Exception error) {
            String message = error.getMessage();
            System.err.println("[nbidal18 supervisor] "
                    + (message == null || message.isBlank() ? error.getClass().getSimpleName() : message));
            System.exit(1);
        }
    }

    private static Path minecraftRoot() {
        String value = System.getenv("INST_MC_DIR");
        return Path.of(value == null || value.isBlank() ? "." : value)
                .toAbsolutePath().normalize();
    }

    private static Path currentJava() throws IOException {
        String command = ProcessHandle.current().info().command().orElse("");
        Path java;
        if (!command.isBlank()) {
            java = Path.of(command).toAbsolutePath().normalize();
        } else {
            boolean windows = System.getProperty("os.name", "")
                    .toLowerCase(Locale.ROOT).contains("win");
            java = Path.of(System.getProperty("java.home"), "bin", windows ? "java.exe" : "java")
                    .toAbsolutePath().normalize();
        }
        if (java.getFileName().toString().equalsIgnoreCase("javaw.exe")) {
            Path console = java.resolveSibling("java.exe");
            if (Files.isRegularFile(console)) {
                java = console;
            }
        }
        if (!Files.isRegularFile(java)) {
            throw new IOException("Java runtime is missing: " + java);
        }
        return java;
    }

    private static int runUpdater(Path root, Path java) throws IOException, InterruptedException {
        Path updater = root.resolve("nbidal18-packwiz-updater.jar").normalize();
        if (!updater.getParent().equals(root) || !Files.isRegularFile(updater, LinkOption.NOFOLLOW_LINKS)
                || Files.isSymbolicLink(updater)) {
            throw new IOException("The managed update engine is missing or unsafe: " + updater);
        }
        List<String> command = new ArrayList<>();
        command.add(java.toString());
        command.add("-jar");
        command.add(updater.toString());
        ProcessBuilder builder = new ProcessBuilder(command);
        builder.directory(root.toFile());
        builder.environment().put("INST_MC_DIR", root.toString());
        builder.inheritIO();
        return builder.start().waitFor();
    }

    private static boolean promoteAll(Path root) throws Exception {
        boolean changed = false;
        for (Promotion promotion : PROMOTIONS) {
            changed |= promote(root, promotion);
        }
        changed |= promotePrismMetadata(root);
        return changed;
    }

    private static boolean promotePrismMetadata(Path root) throws Exception {
        Path instance = root.getParent();
        if (instance == null) {
            throw new IOException("The Prism instance directory could not be located.");
        }
        Path staged = root.resolve("prism/mmc-pack.json").normalize();
        Path live = instance.resolve("mmc-pack.json").normalize();
        if (!staged.startsWith(root.resolve("prism")) || !live.getParent().equals(instance)) {
            throw new IOException("Prism metadata promotion escaped the instance directory.");
        }
        return promoteFile(staged, live, 1024L * 1024L);
    }

    private static boolean promote(Path root, Promotion promotion) throws Exception {
        Path staged = root.resolve(promotion.staged()).normalize();
        Path live = root.resolve(promotion.live()).normalize();
        if (!staged.getParent().equals(root) || !live.getParent().equals(root)) {
            throw new IOException("Updater promotion escaped the Minecraft directory.");
        }
        return promoteFile(staged, live, promotion.maxBytes());
    }

    private static boolean promoteFile(Path staged, Path live, long maxBytes) throws Exception {
        BasicFileAttributes attributes = Files.readAttributes(
                staged, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
        if (!attributes.isRegularFile() || attributes.isSymbolicLink()
                || attributes.size() <= 0 || attributes.size() > maxBytes) {
            throw new IOException("A staged bootstrap file is missing or unsafe: " + staged);
        }
        String stagedHash = sha256(staged);
        if (Files.isRegularFile(live, LinkOption.NOFOLLOW_LINKS)
                && !Files.isSymbolicLink(live) && stagedHash.equals(sha256(live))) {
            return false;
        }

        Path temporary = live.resolveSibling(live.getFileName()
                + ".nbidal18-" + UUID.randomUUID() + ".tmp");
        try {
            Files.copy(staged, temporary, StandardCopyOption.COPY_ATTRIBUTES);
            if (!stagedHash.equals(sha256(temporary))) {
                throw new IOException("A staged bootstrap copy failed verification: " + live);
            }
            try {
                Files.move(temporary, live, StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING);
            } catch (AtomicMoveNotSupportedException ignored) {
                Files.move(temporary, live, StandardCopyOption.REPLACE_EXISTING);
            }
            return true;
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    private static String sha256(Path path) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(path)) {
            byte[] buffer = new byte[128 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                if (count > 0) {
                    digest.update(buffer, 0, count);
                }
            }
        }
        StringBuilder result = new StringBuilder(64);
        for (byte value : digest.digest()) {
            result.append(String.format("%02x", value & 0xff));
        }
        return result.toString();
    }

    private record Promotion(String staged, String live, long maxBytes) {
    }
}

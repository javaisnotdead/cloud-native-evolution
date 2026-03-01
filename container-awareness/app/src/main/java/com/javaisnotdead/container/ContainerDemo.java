package com.javaisnotdead.container;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

/**
 * Container Awareness Demo
 * javaisnotdead.com — Cloud Native Evolution, Article 2
 *
 * Demonstrates how different JVM versions read container resource limits.
 * Run via docker-compose to see side-by-side comparison.
 */
public class ContainerDemo {

    public static void main(String[] args) throws Exception {
        String scenario = System.getenv("SCENARIO");
        if (scenario == null)
            scenario = "all";

        switch (scenario) {
            case "detection":
                runDetection();
                break;
            case "memory":
                runMemory();
                break;
            case "cpu":
                runCpu();
                break;
            default:
                runAll();
                break;
        }
    }

    // -------------------------------------------------------------------------
    // Scenario 1: Container Detection
    // -------------------------------------------------------------------------

    static void runDetection() {
        printHeader("Scenario 1: Container Detection");

        long jvmMaxHeapMB = Runtime.getRuntime().maxMemory() / MB;
        long hostMemoryMB = readProcMeminfo();
        long cgroupMemoryMB = readCgroupMemory();
        int jvmCpus = Runtime.getRuntime().availableProcessors();
        double cgroupCpus = readCgroupCpu();

        printJvmInfo();

        System.out.println("\n  Memory");
        System.out.printf("    /proc/meminfo (host total) : %6d MB%n", hostMemoryMB);
        System.out.printf("    cgroup limit (container)   : %6d MB%n", cgroupMemoryMB);
        System.out.printf("    JVM max heap               : %6d MB%n", jvmMaxHeapMB);

        System.out.println("\n  CPU");
        System.out.printf("    Host CPUs (visible)        : %6d%n", Runtime.getRuntime().availableProcessors());
        System.out.printf("    cgroup CPU limit           : %9.1f%n", cgroupCpus);
        System.out.printf("    JVM availableProcessors()  : %6d%n", jvmCpus);

        boolean memoryAware = cgroupMemoryMB > 0 && jvmMaxHeapMB <= cgroupMemoryMB;
        boolean cpuAware = cgroupCpus > 0 && jvmCpus <= (int) Math.ceil(cgroupCpus);

        System.out.println();
        System.out.println("  Result");
        System.out.println("    Memory aware : " + (memoryAware ? "YES" : "NO — reading host memory"));
        System.out.println("    CPU aware    : " + (cpuAware ? "YES" : "NO — reading host CPUs"));

        printFooter();
    }

    // -------------------------------------------------------------------------
    // Scenario 2: Memory Scaling
    // -------------------------------------------------------------------------

    static void runMemory() throws InterruptedException {
        printHeader("Scenario 2: Memory Scaling");
        printJvmInfo();

        long maxHeapMB = Runtime.getRuntime().maxMemory() / MB;
        System.out.printf("%n  Max heap available to JVM: %d MB%n", maxHeapMB);
        System.out.println("  Allocating memory in 64MB chunks...");
        System.out.println();

        long allocated = 0;
        int chunk = 0;
        try {
            java.util.List<byte[]> blocks = new java.util.ArrayList<>();
            while (true) {
                blocks.add(new byte[64 * 1024 * 1024]); // 64MB
                allocated += 64;
                System.out.printf("  Chunk %2d: %4d MB allocated — OK%n", chunk + 1, allocated);
                Thread.sleep(200);
                chunk++;
            }
        } catch (OutOfMemoryError e) {
            System.out.printf("  Chunk %2d: OutOfMemoryError at %d MB%n", chunk + 1, allocated);
            System.out.println("\n  JVM heap exhausted. Container limit enforced.");
            // DEMONSTRATION ONLY: Never catch OutOfMemoryError in production. Allow the JVM
            // to crash.
        }

        printFooter();
    }

    // -------------------------------------------------------------------------
    // Scenario 3: CPU Awareness
    // -------------------------------------------------------------------------

    static void runCpu() {
        printHeader("Scenario 3: CPU Awareness");
        printJvmInfo();

        int jvmCpus = Runtime.getRuntime().availableProcessors();
        double cgroupCpus = readCgroupCpu();

        System.out.printf("%n  JVM availableProcessors() : %d%n", jvmCpus);
        System.out.printf("  cgroup CPU limit           : %.1f%n", cgroupCpus);

        // Thread pool sizes calculated by the JVM (blind to containers in Java 8)
        int gcThreads = jvmCpus <= 8 ? jvmCpus : 8 + (jvmCpus - 8) * 5 / 8;
        int forkJoinThreads = jvmCpus - 1 > 0 ? jvmCpus - 1 : 1; // Used by parallel streams
        int nettyEventLoop = jvmCpus * 2; // Default for Spring WebFlux / Reactive

        System.out.println("\n  Thread pools sized by JVM (based on availableProcessors):");
        System.out.printf("    Parallel GC threads (ParallelGCThreads) : %d%n", gcThreads);
        System.out.printf("    ForkJoinPool (parallel streams)         : %d%n", forkJoinThreads);
        System.out.printf("    Netty Event Loop (Reactive)             : %d%n", nettyEventLoop);

        if (cgroupCpus > 0 && jvmCpus > (int) Math.ceil(cgroupCpus)) {
            System.out.println("\n  WARNING: JVM detected " + jvmCpus + " CPUs and over-provisioned threads.");
            System.out.println("           But container only guarantees " + cgroupCpus + " CPU quota.");
            System.out.println("           Result: Severe CPU throttling and extreme context switching.");
        } else {
            System.out.println("\n  Thread pools correctly sized for container CPU limit.");
        }

        printFooter();
    }

    static void runAll() throws Exception {
        runDetection();
        System.out.println();
        runCpu();
        System.out.println();
        runMemory();
        System.out.println();
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    static final long MB = 1024L * 1024L;

    static void printHeader(String scenario) {
        System.out.println("============================================================");
        System.out.println("  " + scenario);
        System.out.println("  javaisnotdead.com — Cloud Native Evolution, Article 2");
        System.out.println("============================================================");
    }

    static void printFooter() {
        System.out.println("============================================================");
    }

    static void printJvmInfo() {
        System.out.printf("%n  JVM: %s %s%n",
                System.getProperty("java.vendor"),
                System.getProperty("java.version"));
    }

    static long readProcMeminfo() {
        try {
            List<String> lines = Files.readAllLines(Paths.get("/proc/meminfo"));
            for (String line : lines) {
                if (line.startsWith("MemTotal:")) {
                    String[] parts = line.trim().split("\\s+");
                    return Long.parseLong(parts[1]) / 1024; // kB to MB
                }
            }
        } catch (IOException e) {
            // not on Linux
        }
        return -1;
    }

    static long readCgroupMemory() {
        // cgroups v2
        long v2 = readLongFile("/sys/fs/cgroup/memory.max");
        if (v2 > 0 && v2 < Long.MAX_VALUE)
            return v2 / MB;

        // cgroups v1
        long v1 = readLongFile("/sys/fs/cgroup/memory/memory.limit_in_bytes");
        if (v1 > 0 && v1 < Long.MAX_VALUE)
            return v1 / MB;

        return -1;
    }

    static double readCgroupCpu() {
        // cgroups v2: "max period" or "max" meaning unlimited
        try {
            String content = new String(Files.readAllBytes(Paths.get("/sys/fs/cgroup/cpu.max"))).trim();
            if (!content.startsWith("max")) {
                String[] parts = content.split(" ");
                return Double.parseDouble(parts[0]) / Double.parseDouble(parts[1]);
            }
        } catch (IOException e) {
            System.err.println("Could not read cgroups v2 CPU limits: " + e.getMessage());
        }

        // cgroups v1
        long quota = readLongFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
        long period = readLongFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
        if (quota > 0 && period > 0)
            return (double) quota / period;

        return -1;
    }

    static long readLongFile(String path) {
        try {
            String content = new String(Files.readAllBytes(Paths.get(path))).trim();
            return Long.parseLong(content);
        } catch (Exception e) {
            System.err.println("Could not read long value from file " + path + ": " + e.getMessage());
            return -1;
        }
    }
}

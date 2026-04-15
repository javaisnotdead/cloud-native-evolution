package com.javaisnotdead.coh;

import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
import org.springframework.web.bind.annotation.*;

import java.lang.management.ManagementFactory;
import java.util.Map;

@RestController
@RequestMapping("/cache")
public class CacheController {

    private final Cache cache;

    public CacheController(CacheManager cacheManager) {
        this.cache = cacheManager.getCache("orders");
    }

    /**
     * Populates the cache with N entries. Each entry is a CachedOrder
     * with realistic field values (Strings, BigDecimal, LocalDateTime).
     */
    @PostMapping("/populate")
    public Map<String, Object> populate(@RequestParam(defaultValue = "1000000") int count) {
        long start = System.nanoTime();

        for (long i = 0; i < count; i++) {
            cache.put(i, CachedOrder.generate(i));
        }

        // Force GC to get stable heap measurement
        System.gc();
        try { Thread.sleep(2000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        System.gc();
        try { Thread.sleep(1000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }

        long elapsed = (System.nanoTime() - start) / 1_000_000;

        return Map.of(
                "entriesLoaded", count,
                "loadTimeMs", elapsed,
                "heapUsedMB", heapUsedMB(),
                "rssKB", rssKB()
        );
    }

    @GetMapping("/{id}")
    public CachedOrder get(@PathVariable long id) {
        CachedOrder order = cache.get(id, CachedOrder.class);
        if (order == null) {
            order = CachedOrder.generate(id);
            cache.put(id, order);
        }
        return order;
    }

    @GetMapping("/stats")
    public Map<String, Object> stats() {
        return Map.of(
                "heapUsedMB", heapUsedMB(),
                "heapMaxMB", heapMaxMB(),
                "rssKB", rssKB()
        );
    }

    private long heapUsedMB() {
        var mem = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        return mem.getUsed() / (1024 * 1024);
    }

    private long heapMaxMB() {
        var mem = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        return mem.getMax() / (1024 * 1024);
    }

    private long rssKB() {
        // Read RSS from /proc on Linux (inside Docker container)
        try {
            String status = new String(
                    java.nio.file.Files.readAllBytes(java.nio.file.Path.of("/proc/self/status")));
            for (String line : status.split("\n")) {
                if (line.startsWith("VmRSS:")) {
                    return Long.parseLong(line.replaceAll("[^0-9]", ""));
                }
            }
        } catch (Exception e) {
            // Not on Linux or /proc not available
        }
        return -1;
    }
}

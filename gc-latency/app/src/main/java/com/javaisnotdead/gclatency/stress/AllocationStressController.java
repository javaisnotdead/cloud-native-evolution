package com.javaisnotdead.gclatency.stress;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Additional stress endpoints that exercise specific GC weaknesses.
 * These supplement the main payment endpoint for targeted testing.
 */
@RestController
public class AllocationStressController {

    // Scenario 2: Long-lived cache that fills old generation
    private final Map<Long, byte[]> longLivedCache = new HashMap<>();
    private final AtomicLong cacheKeySequence = new AtomicLong(0);

    // Scenario 3: LRU cache - objects promote to old gen then die
    private final LinkedHashMap<Long, byte[]> lruCache = new LinkedHashMap<>(10_000, 0.75f, true) {
        @Override
        protected boolean removeEldestEntry(Map.Entry<Long, byte[]> eldest) {
            return size() > 10_000;
        }
    };
    private final AtomicLong lruSequence = new AtomicLong(0);

    /**
     * Scenario 1: Firehose - pure allocation pressure.
     * Creates and discards objects as fast as possible.
     * Each call allocates ~sizeKb KB of garbage.
     */
    @GetMapping("/api/stress/firehose")
    public Map<String, Object> firehose(@RequestParam(defaultValue = "64") int sizeKb) {
        // Create short-lived objects that become garbage immediately
        byte[] data = new byte[sizeKb * 1024];
        String hash = UUID.randomUUID().toString();

        // Force some object graph complexity (not just a flat array)
        Map<String, Object> tempGraph = new HashMap<>(16);
        for (int i = 0; i < 10; i++) {
            tempGraph.put("key_" + i, new byte[sizeKb * 100]);
            tempGraph.put("meta_" + i, UUID.randomUUID().toString());
        }

        return Map.of(
            "allocated_kb", sizeKb + (sizeKb * 10),
            "hash", hash
        );
    }

    /**
     * Scenario 2: Fill long-lived cache.
     * Call this before running the main benchmark to fill old generation.
     * This makes G1's job harder because it has more live data to scan.
     */
    @GetMapping("/api/stress/fill-cache")
    public Map<String, Object> fillCache(
            @RequestParam(defaultValue = "100000") int entries,
            @RequestParam(defaultValue = "1024") int valueSizeBytes) {
        for (int i = 0; i < entries; i++) {
            longLivedCache.put(cacheKeySequence.incrementAndGet(), new byte[valueSizeBytes]);
        }
        long totalMb = (long) longLivedCache.size() * valueSizeBytes / (1024 * 1024);
        return Map.of(
            "cacheSize", longLivedCache.size(),
            "estimatedMb", totalMb
        );
    }

    @GetMapping("/api/stress/clear-cache")
    public Map<String, Object> clearCache() {
        int size = longLivedCache.size();
        longLivedCache.clear();
        return Map.of("cleared", size);
    }

    /**
     * Scenario 3: LRU cache - objects live long enough to promote to old gen,
     * then get evicted. This is the worst case for generational collectors
     * because objects that promoted turn into old-gen garbage.
     */
    @GetMapping("/api/stress/lru")
    public Map<String, Object> lruPut(@RequestParam(defaultValue = "4096") int valueSizeBytes) {
        long key = lruSequence.incrementAndGet();
        synchronized (lruCache) {
            lruCache.put(key, new byte[valueSizeBytes]);
        }
        return Map.of(
            "lruSize", lruCache.size(),
            "key", key
        );
    }
}

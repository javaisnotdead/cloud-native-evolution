package com.javaisnotdead.gclatency.payment;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.util.HashMap;
import java.util.Map;

@RestController
public class PaymentController {

    private final PaymentService paymentService;

    public PaymentController(PaymentService paymentService) {
        this.paymentService = paymentService;
    }

    @PostMapping("/api/payments")
    public ResponseEntity<PaymentService.PaymentResult> processPayment(
            @RequestBody PaymentService.PaymentRequest request) {
        return ResponseEntity.ok(paymentService.process(request));
    }

    /**
     * Returns current GC stats for monitoring during benchmark.
     */
    @GetMapping("/api/gc-stats")
    public ResponseEntity<Map<String, Object>> gcStats() {
        Map<String, Object> stats = new HashMap<>();

        MemoryMXBean memory = ManagementFactory.getMemoryMXBean();
        stats.put("heapUsed", memory.getHeapMemoryUsage().getUsed());
        stats.put("heapMax", memory.getHeapMemoryUsage().getMax());
        stats.put("heapCommitted", memory.getHeapMemoryUsage().getCommitted());

        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            Map<String, Object> gcInfo = new HashMap<>();
            gcInfo.put("count", gc.getCollectionCount());
            gcInfo.put("timeMs", gc.getCollectionTime());
            stats.put("gc_" + gc.getName().replace(" ", "_"), gcInfo);
        }

        stats.put("availableProcessors", Runtime.getRuntime().availableProcessors());
        stats.put("jvmArgs", ManagementFactory.getRuntimeMXBean().getInputArguments());

        return ResponseEntity.ok(stats);
    }
}

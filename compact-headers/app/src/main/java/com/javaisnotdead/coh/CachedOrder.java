package com.javaisnotdead.coh;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/**
 * Simulates a typical cached entity. Each instance creates multiple
 * internal objects (Strings, BigDecimal, LocalDateTime) that all
 * benefit from smaller headers.
 */
public record CachedOrder(
        Long id,
        String customerName,
        String productName,
        Integer quantity,
        BigDecimal price,
        String status,
        LocalDateTime createdAt
) {

    static CachedOrder generate(long id) {
        return new CachedOrder(
                id,
                "Customer-" + id,
                "Product-" + (id % 1000),
                (int) (id % 50) + 1,
                BigDecimal.valueOf(9_99 + (id % 10000), 2),
                id % 3 == 0 ? "SHIPPED" : id % 3 == 1 ? "PENDING" : "DELIVERED",
                LocalDateTime.of(2026, 1, 1, 0, 0).plusMinutes(id)
        );
    }
}

package com.javaisnotdead.virtualthreads.order;

import org.springframework.stereotype.Service;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.concurrent.TimeUnit;

@Service
public class OrderService {

    private final OrderRepository repository;

    public OrderService(OrderRepository repository) {
        this.repository = repository;
    }

    // sleep() runs BEFORE the DB call — no connection is held during the wait.
    // Platform thread: OS thread blocked for 50ms, can't serve other requests.
    // Virtual thread: unmounts from carrier thread, carrier serves other VTs.
    //
    // IMPORTANT: Deliberately no @Transactional here. If @Transactional were placed
    // on create(), Spring would open a Hikari connection at method entry and hold it
    // for the entire simulateIoLatency() call — 50ms of idle connection per request.
    // With a 20-connection pool, the pool would exhaust as fast as with platform threads.
    public Order create(CreateOrderRequest request) {
        simulateIoLatency();
        return doCreate(request);
    }

    // Single INSERT — auto-commit is sufficient, no explicit transaction needed.
    public Order doCreate(CreateOrderRequest request) {
        Order order = new Order(
                request.customerName(),
                request.productName(),
                request.quantity(),
                new BigDecimal("9.99"),  // Fixed price for benchmark simplicity
                "PENDING",
                LocalDateTime.now()
        );
        return repository.save(order);
    }

    // Same pattern: sleep before DB call, connection held only during SELECT.
    public Order findById(Long id) {
        simulateIoLatency();
        return doFindById(id);
    }

    // Single SELECT — auto-commit, no explicit transaction needed.
    public Order doFindById(Long id) {
        return repository.findById(id)
                .orElseThrow(() -> new RuntimeException("Order not found: " + id));
    }

    // Simulates realistic network I/O latency (remote DB, external API call, etc.)
    // Total per request: 2 x 50ms = 100ms simulated I/O + actual DB time.
    private void simulateIoLatency() {
        try {
            TimeUnit.MILLISECONDS.sleep(50);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}

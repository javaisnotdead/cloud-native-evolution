package com.javaisnotdead.reactive.order;

import org.springframework.stereotype.Service;
import reactor.core.publisher.Mono;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.LocalDateTime;

@Service
public class OrderService {

    private final OrderRepository repository;

    public OrderService(OrderRepository repository) {
        this.repository = repository;
    }

    // Same pattern as blocking version: delay runs BEFORE the DB call.
    // Mono.delay() is non-blocking — Netty event loop thread is never idle.
    public Mono<Order> create(CreateOrderRequest request) {
        return simulateIoLatency()
                .then(Mono.defer(() -> doCreate(request)));
    }

    // Single INSERT — auto-commit is sufficient, no explicit transaction needed.
    public Mono<Order> doCreate(CreateOrderRequest request) {
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

    // Same pattern: delay before DB call, connection held only during SELECT.
    public Mono<Order> findById(Long id) {
        return simulateIoLatency()
                .then(Mono.defer(() -> doFindById(id)));
    }

    // Single SELECT — auto-commit, no explicit transaction needed.
    public Mono<Order> doFindById(Long id) {
        return repository.findById(id)
                .switchIfEmpty(Mono.error(
                        new RuntimeException("Order not found: " + id)));
    }

    // Simulates realistic network I/O latency (remote DB, external API call, etc.)
    // Total per request: 2 x 50ms simulated I/O + actual DB time.
    // Unlike Thread.sleep(), Mono.delay() does not block any thread.
    private Mono<Void> simulateIoLatency() {
        return Mono.delay(Duration.ofMillis(50)).then();
    }
}

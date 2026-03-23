package com.javaisnotdead.reactive.order;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;
import reactor.core.publisher.Mono;

@RestController
@RequestMapping("/orders")
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    // Two DB round-trips per request: INSERT (create) + SELECT (findById)
    // Same logic as the blocking version, expressed as a reactive pipeline.
    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Mono<Order> create(@RequestBody CreateOrderRequest request) {
        return service.create(request)
                .flatMap(saved -> service.findById(saved.getId()));
    }

    @GetMapping("/{id}")
    public Mono<Order> findById(@PathVariable Long id) {
        return service.findById(id);
    }
}

package com.javaisnotdead.virtualthreads.order;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/orders")
public class OrderController {

    private final OrderService service;

    public OrderController(OrderService service) {
        this.service = service;
    }

    // Two DB round-trips per request: INSERT (create) + SELECT (findById)
    // This is the benchmark endpoint — each POST hits PostgreSQL twice.
    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Order create(@RequestBody CreateOrderRequest request) {
        Order saved = service.create(request);
        return service.findById(saved.getId());
    }

    @GetMapping("/{id}")
    public Order findById(@PathVariable Long id) {
        return service.findById(id);
    }
}

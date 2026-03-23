package com.javaisnotdead.virtualthreads.order;

public record CreateOrderRequest(
        String customerName,
        String productName,
        Integer quantity) {
}

package com.javaisnotdead.reactive.order;

public record CreateOrderRequest(
        String customerName,
        String productName,
        Integer quantity) {
}

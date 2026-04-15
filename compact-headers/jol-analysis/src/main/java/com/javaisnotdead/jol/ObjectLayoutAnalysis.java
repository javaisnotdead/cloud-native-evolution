package com.javaisnotdead.jol;

import org.openjdk.jol.info.ClassLayout;
import org.openjdk.jol.vm.VM;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedList;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Analyzes object layouts with and without Compact Object Headers.
 *
 * Run twice:
 *   java -jar jol-analysis.jar                              (default headers)
 *   java -XX:+UseCompactObjectHeaders -jar jol-analysis.jar (compact headers)
 *
 * Compare the output to see exactly which bytes disappear.
 */
public class ObjectLayoutAnalysis {

    // Simulates a typical JPA entity (like our Order from previous articles)
    static class OrderEntity {
        Long id;
        String customerName;
        String productName;
        Integer quantity;
        BigDecimal price;
        String status;
        LocalDateTime createdAt;
    }

    // Simulates a simple DTO
    static class OrderResponse {
        long id;
        String customerName;
        String status;
        double totalPrice;
    }

    // Simulates a cache entry (common in Spring apps)
    static class CacheEntry {
        String key;
        Object value;
        long expiresAt;
    }

    // Tiny wrapper objects (worst case for header tax)
    static class IntWrapper {
        int value;
    }

    static class BooleanWrapper {
        boolean flag;
    }

    public static void main(String[] args) {
        System.out.println("=== Java Object Layout Analysis ===");
        System.out.println(VM.current().details());
        System.out.println();

        printSection("JDK CORE TYPES (objects your app creates millions of)");

        printLayout(Object.class, "Empty Object (baseline - pure header cost)");
        printLayout(String.class, "String");
        printLayout(Integer.class, "Integer (autoboxing)");
        printLayout(Long.class, "Long (autoboxing)");
        printLayout(Double.class, "Double (autoboxing)");
        printLayout(byte[].class, "byte[] (array header)");
        printLayout(Object[].class, "Object[] (array header)");

        printSection("COLLECTIONS (HashMap.Node is the most allocated object in most Java apps)");

        printLayout(HashMap.class, "HashMap (shell)");
        printLayout(nodeClass("java.util.HashMap$Node"), "HashMap.Node (one per entry)");
        printLayout(ArrayList.class, "ArrayList (shell)");
        printLayout(LinkedList.class, "LinkedList (shell)");
        printLayout(ConcurrentHashMap.class, "ConcurrentHashMap (shell)");

        printSection("SPRING BOOT APP TYPES (from our benchmark series)");

        printLayout(OrderEntity.class, "OrderEntity (JPA entity, 7 fields)");
        printLayout(OrderResponse.class, "OrderResponse (DTO, 4 fields)");
        printLayout(CacheEntry.class, "CacheEntry (cache entry, 3 fields)");

        printSection("WORST CASE: TINY WRAPPERS (header tax is highest here)");

        printLayout(IntWrapper.class, "IntWrapper (4 bytes payload, rest is overhead)");
        printLayout(BooleanWrapper.class, "BooleanWrapper (1 byte payload, rest is overhead)");

        printSummary();
    }

    private static void printLayout(Class<?> clazz, String description) {
        if (clazz == null) {
            System.out.println("  [class not found, skipping]");
            System.out.println();
            return;
        }
        System.out.println("--- " + description + " ---");
        System.out.println(ClassLayout.parseClass(clazz).toPrintable());
    }

    private static void printSection(String title) {
        System.out.println();
        System.out.println("============================================================");
        System.out.println(title);
        System.out.println("============================================================");
        System.out.println();
    }

    private static void printSummary() {
        printSection("SUMMARY: HEADER SIZE IMPACT");

        long headerDefault = ClassLayout.parseClass(Object.class).instanceSize();

        System.out.println("Empty Object size: " + headerDefault + " bytes");
        System.out.println();

        Class<?>[] types = {
                Object.class, String.class, Integer.class, Long.class,
                OrderEntity.class, OrderResponse.class, CacheEntry.class,
                IntWrapper.class, BooleanWrapper.class
        };
        String[] names = {
                "Object", "String", "Integer", "Long",
                "OrderEntity", "OrderResponse", "CacheEntry",
                "IntWrapper", "BooleanWrapper"
        };

        System.out.printf("%-20s %10s %12s%n", "Type", "Size (bytes)", "Header ratio");
        System.out.println("-".repeat(44));

        for (int i = 0; i < types.length; i++) {
            long size = ClassLayout.parseClass(types[i]).instanceSize();
            double ratio = (double) headerDefault / size * 100;
            System.out.printf("%-20s %10d %10.1f%%%n", names[i], size, ratio);
        }
    }

    private static Class<?> nodeClass(String name) {
        try {
            return Class.forName(name);
        } catch (ClassNotFoundException e) {
            return null;
        }
    }
}

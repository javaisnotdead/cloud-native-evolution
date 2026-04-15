package com.javaisnotdead.coh;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cache.annotation.EnableCaching;

@SpringBootApplication
@EnableCaching
public class CohBenchmarkApplication {

    public static void main(String[] args) {
        SpringApplication.run(CohBenchmarkApplication.class, args);
    }
}

package com.javaisnotdead.gclatency.payment;

import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "payments")
public class Payment {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    private String transactionId;
    private String sender;
    private String receiver;
    private BigDecimal amount;
    private String currency;
    private String status;
    private String riskScore;
    private Instant createdAt;

    public Payment() {}

    public Payment(String sender, String receiver, BigDecimal amount, String currency) {
        this.transactionId = UUID.randomUUID().toString();
        this.sender = sender;
        this.receiver = receiver;
        this.amount = amount;
        this.currency = currency;
        this.status = "PENDING";
        this.createdAt = Instant.now();
    }

    public Long getId() { return id; }
    public String getTransactionId() { return transactionId; }
    public String getSender() { return sender; }
    public String getReceiver() { return receiver; }
    public BigDecimal getAmount() { return amount; }
    public String getCurrency() { return currency; }
    public String getStatus() { return status; }
    public void setStatus(String status) { this.status = status; }
    public String getRiskScore() { return riskScore; }
    public void setRiskScore(String riskScore) { this.riskScore = riskScore; }
    public Instant getCreatedAt() { return createdAt; }
}

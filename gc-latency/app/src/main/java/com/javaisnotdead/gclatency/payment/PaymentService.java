package com.javaisnotdead.gclatency.payment;

import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

@Service
public class PaymentService {

    private final PaymentRepository repository;

    public PaymentService(PaymentRepository repository) {
        this.repository = repository;
    }

    /**
     * Processes a payment with realistic allocation pressure.
     *
     * Each call creates ~50-100KB of short-lived objects:
     * - Fraud check builds temporary collections and string concatenations
     * - Risk scoring creates intermediate calculation objects
     * - Audit trail serializes the full transaction context
     *
     * At 2000 req/s this generates ~100-200 MB/s of young gen garbage,
     * enough to trigger frequent GC cycles and expose pause differences.
     */
    @Transactional
    public PaymentResult process(PaymentRequest request) {
        Payment payment = new Payment(
                request.sender(), request.receiver(),
                request.amount(), request.currency()
        );

        // Step 1: Fraud detection - builds temporary object graph
        FraudCheckResult fraudResult = runFraudCheck(payment);

        // Step 2: Risk scoring - intermediate BigDecimal calculations
        String riskScore = calculateRiskScore(payment, fraudResult);
        payment.setRiskScore(riskScore);

        // Step 3: Compliance check - string processing and hashing
        String complianceHash = runComplianceCheck(payment);

        // Step 4: Persist
        payment.setStatus(fraudResult.approved() ? "APPROVED" : "DECLINED");
        Payment saved = repository.save(payment);

        // Step 5: Build audit trail - creates serialization overhead
        Map<String, Object> auditTrail = buildAuditTrail(saved, fraudResult, complianceHash);

        return new PaymentResult(
                saved.getTransactionId(),
                saved.getStatus(),
                riskScore,
                auditTrail.size()
        );
    }

    /**
     * Simulates fraud detection by building a temporary feature vector.
     * Creates ~20KB of short-lived objects per call.
     */
    private FraudCheckResult runFraudCheck(Payment payment) {
        // Build feature vector - lots of temporary String and BigDecimal allocations
        List<Map<String, Object>> features = new ArrayList<>(50);
        for (int i = 0; i < 50; i++) {
            Map<String, Object> feature = new HashMap<>(8);
            feature.put("feature_" + i, ThreadLocalRandom.current().nextDouble());
            feature.put("weight", BigDecimal.valueOf(ThreadLocalRandom.current().nextDouble())
                    .setScale(6, RoundingMode.HALF_UP));
            feature.put("sender_hash", payment.getSender() + "_" + i);
            feature.put("normalized", String.valueOf(ThreadLocalRandom.current().nextGaussian()));
            features.add(feature);
        }

        // Simulate scoring - iterates feature vector, creates intermediate results
        double score = 0.0;
        for (Map<String, Object> feature : features) {
            double value = (double) feature.get("feature_" + features.indexOf(feature));
            BigDecimal weight = (BigDecimal) feature.get("weight");
            score += value * weight.doubleValue();
        }

        boolean approved = score < 25.0;
        return new FraudCheckResult(approved, score, features.size());
    }

    /**
     * Multi-factor risk scoring with intermediate BigDecimal math.
     * Creates ~10KB of temporary objects.
     */
    private String calculateRiskScore(Payment payment, FraudCheckResult fraudResult) {
        BigDecimal base = payment.getAmount();
        List<BigDecimal> factors = new ArrayList<>(20);

        // Generate risk factors
        for (int i = 0; i < 20; i++) {
            BigDecimal factor = base
                    .multiply(BigDecimal.valueOf(ThreadLocalRandom.current().nextDouble(0.01, 0.1)))
                    .add(BigDecimal.valueOf(fraudResult.score()))
                    .divide(BigDecimal.valueOf(i + 1), 8, RoundingMode.HALF_UP);
            factors.add(factor);
        }

        // Aggregate
        BigDecimal total = BigDecimal.ZERO;
        for (BigDecimal f : factors) {
            total = total.add(f);
        }

        BigDecimal normalized = total.divide(BigDecimal.valueOf(factors.size()), 4, RoundingMode.HALF_UP);

        if (normalized.compareTo(BigDecimal.valueOf(100)) > 0) return "HIGH";
        if (normalized.compareTo(BigDecimal.valueOf(50)) > 0) return "MEDIUM";
        return "LOW";
    }

    /**
     * Compliance check with SHA-256 hashing.
     * String concatenation + byte array allocation.
     */
    private String runComplianceCheck(Payment payment) {
        // Build compliance payload - string concatenation creates garbage
        StringBuilder payload = new StringBuilder(2048);
        payload.append(payment.getTransactionId()).append("|");
        payload.append(payment.getSender()).append("|");
        payload.append(payment.getReceiver()).append("|");
        payload.append(payment.getAmount().toPlainString()).append("|");
        payload.append(payment.getCurrency()).append("|");
        payload.append(payment.getCreatedAt()).append("|");

        // Add padding to simulate real compliance data (KYC fields, etc.)
        for (int i = 0; i < 10; i++) {
            payload.append(UUID.randomUUID()).append("|");
            payload.append("FIELD_").append(i).append("=").append(ThreadLocalRandom.current().nextLong()).append("|");
        }

        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(payload.toString().getBytes(StandardCharsets.UTF_8));
            return bytesToHex(hash);
        } catch (NoSuchAlgorithmException e) {
            throw new RuntimeException(e);
        }
    }

    /**
     * Builds audit trail map - simulates JSON serialization overhead.
     * Creates ~15KB of temporary objects.
     */
    private Map<String, Object> buildAuditTrail(Payment payment, FraudCheckResult fraudResult,
                                                 String complianceHash) {
        Map<String, Object> audit = new HashMap<>(32);
        audit.put("transactionId", payment.getTransactionId());
        audit.put("sender", payment.getSender());
        audit.put("receiver", payment.getReceiver());
        audit.put("amount", payment.getAmount().toPlainString());
        audit.put("currency", payment.getCurrency());
        audit.put("status", payment.getStatus());
        audit.put("riskScore", payment.getRiskScore());
        audit.put("fraudScore", fraudResult.score());
        audit.put("fraudFeatureCount", fraudResult.featureCount());
        audit.put("complianceHash", complianceHash);
        audit.put("timestamp", payment.getCreatedAt().toString());

        // Simulate additional audit fields (regulatory requirements)
        for (int i = 0; i < 15; i++) {
            audit.put("audit_field_" + i, UUID.randomUUID().toString());
        }

        return audit;
    }

    private static String bytesToHex(byte[] hash) {
        StringBuilder hex = new StringBuilder(hash.length * 2);
        for (byte b : hash) {
            hex.append(String.format("%02x", b));
        }
        return hex.toString();
    }

    public record PaymentRequest(String sender, String receiver, BigDecimal amount, String currency) {}
    public record PaymentResult(String transactionId, String status, String riskScore, int auditFieldCount) {}
    record FraudCheckResult(boolean approved, double score, int featureCount) {}
}

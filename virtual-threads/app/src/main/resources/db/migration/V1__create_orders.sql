CREATE TABLE orders (
    id            BIGSERIAL PRIMARY KEY,
    customer_name VARCHAR(255)   NOT NULL,
    product_name  VARCHAR(255)   NOT NULL,
    quantity      INTEGER        NOT NULL,
    price         DECIMAL(10, 2) NOT NULL,
    status        VARCHAR(50)    NOT NULL,
    created_at    TIMESTAMP      NOT NULL
);

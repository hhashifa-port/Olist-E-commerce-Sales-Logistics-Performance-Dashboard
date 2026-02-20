-- Database: Olist_Ecommerce

-- DROP DATABASE IF EXISTS "Olist_Ecommerce";

CREATE DATABASE "Olist_Ecommerce"
    WITH
    OWNER = postgres
    ENCODING = 'UTF8'
    LC_COLLATE = 'English_Indonesia.1252'
    LC_CTYPE = 'English_Indonesia.1252'
    LOCALE_PROVIDER = 'libc'
    TABLESPACE = pg_default
    CONNECTION LIMIT = -1
    IS_TEMPLATE = False;

-- CREATE MASTER VIEW FOR SALES AND PRODUCT PERFORMANCE ANALYSIS
-- granularity: item/order 
-- main table: order_items, join with: products, orders, sellers
CREATE OR REPLACE VIEW data_sales AS
SELECT
	-- transaction
	oi.order_id,
	oi.order_item_id,

	-- time of transaction
	o.order_purchase_timestamp,
	EXTRACT(YEAR FROM o.order_purchase_timestamp) AS purchase_year,
	EXTRACT(MONTH FROM o.order_purchase_timestamp) AS purchase_month,
	TO_CHAR(o.order_purchase_timestamp, 'Month') AS purchase_month_name,

	-- customer
	c.customer_unique_id,
	c.customer_city,
	c.customer_state,

	-- product
	p.product_id,
	p.product_category_name,

	-- amount of purchase
	oi.price,
	oi.freight_value,
	(oi.price + oi.freight_value) AS total_item_value,

	-- seller and performance
	oi.seller_id,
	s.seller_city,
	s.seller_state,
	r.review_score
FROM order_items oi
JOIN orders o ON oi.order_id = o.order_id
JOIN customers c ON o.customer_id = c.customer_id
JOIN products p ON oi.product_id = p.product_id
JOIN sellers s ON oi.seller_id = s.seller_id
LEFT JOIN order_reviews r ON o.order_id = r.order_id
WHERE o.order_status = 'Delivered';


-- CREATE MASTER VIEW FOR ORDER LOGISTIC ANALYSIS
-- granularity: order_id
CREATE OR REPLACE VIEW data_logistic AS
SELECT
	o.order_id,

	-- location
	c.customer_city,
	c.customer_state,

	-- timestamp
	o.order_purchase_timestamp,
	o.order_delivered_carrier_date,
	o.order_delivered_customer_date,
	o.order_estimated_delivery_date,

	-- total duration (end-to-end)
	EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_purchase_timestamp)) AS actual_delivery_days,

	-- seller handling time
	EXTRACT(DAY FROM (o.order_delivered_carrier_date - o.order_purchase_timestamp)) AS seller_handling_days,

	-- carrier shipping time
	EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_delivered_carrier_date)) AS carrier_shipping_days,

	-- difference actual vs estimation
	EXTRACT(DAY FROM (o.order_delivered_customer_date - o.order_estimated_delivery_date)) AS days_diff_from_estimation,

	-- delivery status
	CASE
		WHEN o.order_delivered_customer_date <= o.order_estimated_delivery_date THEN 'On Time'
		ELSE 'Late'
	END AS delivery_status
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE order_status = 'Delivered'
	AND order_delivered_customer_date IS NOT NULL;



-- CREATE MASTER VIEW FOR PAYMENT ANALYSIS
-- granularity: payment_sequential/order_id
-- main table: order_payments, join with: orders
CREATE OR REPLACE VIEW data_payment AS
SELECT
	op.order_id,
	MAX(op.payment_type) AS main_payment_type,
	MAX(op.payment_installments) AS max_installments,
	SUM(op.payment_value) AS total_payment_value,

	-- number of payment sequential
	CASE
		WHEN MAX(op.payment_installments) <= 1 THEN '01. Full Payment'
		WHEN MAX(op.payment_installments) BETWEEN 2 AND 4 THEN '02. Short-term (2-4x)'
		WHEN MAX(op.payment_installments) BETWEEN 5 AND 12 THEN '03. Mid-term (5-12x)'
		ELSE '04. Long-term (>12x)'
	END AS installment_type,

	-- payment value segmentation
	CASE
		WHEN SUM(op.payment_value) < 60 THEN '01. Economy'
		WHEN SUM(op.payment_value) BETWEEN 60 AND 100 THEN '02. Standard'
		WHEN SUM(op.payment_value) BETWEEN 101 AND 175 THEN '03. Premium'
		ELSE '04. Luxury'
	END AS ticket_size,

	-- purchase datetime
	MAX(o.order_purchase_timestamp) AS order_purchase_timestamp,
	EXTRACT(YEAR FROM MAX(o.order_purchase_timestamp)) AS purchase_year,
	TO_CHAR(MAX(o.order_purchase_timestamp), 'Month') AS purchase_month
FROM order_payments op
JOIN orders o ON op.order_id = o.order_id
WHERE o.order_status = 'Delivered'
GROUP BY op.order_id;


-- CREATE MASTER VIEW FOR CUSTOMER LOYALTY ANALYSIS
-- granularity: customer_unique_id
-- main table: customers, join with: orders
CREATE OR REPLACE VIEW data_customer AS
WITH customer_metrics AS(
	SELECT
		c.customer_unique_id,
		MAX(c.customer_city) AS city,
		MAX(c.customer_state) AS state,
		COUNT(DISTINCT o.order_id) AS total_orders,
		COUNT(oi.order_item_id) AS total_items,
		SUM(op.payment_value) AS total_spent,
		ROUND((SUM(op.payment_value) / COUNT(DISTINCT o.order_id))::numeric, 2) AS avg_order_value,
		MIN(o.order_purchase_timestamp) AS first_purchase,
		MAX(o.order_purchase_timestamp) AS last_purchase,
		EXTRACT(DAY FROM (DATE '2018-10-17' - MAX(o.order_purchase_timestamp))) AS recency_days
	FROM customers c
	JOIN orders o ON c.customer_id = o.customer_id
	LEFT JOIN order_items oi ON o.order_id = oi.order_id
	LEFT JOIN order_payments op ON o.order_id = op.order_id
	WHERE o.order_status = 'Delivered'
	GROUP BY customer_unique_id
),
thresholds AS(
	SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY recency_days) AS recency_q1,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY recency_days) AS recency_q2,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY recency_days) AS recency_q3,
        PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY total_spent) AS monetary_q2,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_spent) AS monetary_q3,
        PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY total_spent) AS monetary_p90
    FROM customer_metrics
)

SELECT
	m.*,
	
	-- customer segmentation by its recency
	CASE 
        WHEN m.recency_days <= t.recency_q1 THEN '01. Very Active'
        WHEN m.recency_days <= t.recency_q2 THEN '02. Active'
        WHEN m.recency_days <= t.recency_q3 THEN '03. Sleeping'
        ELSE '04. Inactive'
    END AS activity_status,
	
	-- customer segmentation by its monetary
	CASE
		WHEN m.total_spent >= t.monetary_p90 THEN '01. Whale (Top 10%)'
        WHEN m.total_spent >= t.monetary_q3 THEN '02. High Spender'
        WHEN m.total_spent >= t.monetary_q2 THEN '03. Medium Spender'
        ELSE '04. Low Spender'
	END AS spending_tier,
	
	-- customer segmentation by its frequency
	CASE
		WHEN m.total_orders >= 2 THEN 'Repeat Buyer'
		ELSE 'One-time Buyer'
	END AS loyalty_type
	
FROM customer_metrics m, thresholds t;

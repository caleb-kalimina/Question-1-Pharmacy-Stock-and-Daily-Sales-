-- ============================================================================
-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales (50 marks)
-- PostgreSQL Implementation
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS v_low_stock CASCADE;
DROP TABLE IF EXISTS daily_sales CASCADE;
DROP TABLE IF EXISTS stock_audit CASCADE;
DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS medicines CASCADE;

-- ----------------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ----------------------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL CHECK (total_amount >= 0)
);

-- ----------------------------------------------------------------------------
-- (b) Function: fn_sale_value(p_medicine_id, p_quantity) [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INTEGER,
    p_quantity    INTEGER
) RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity (%): must be a positive integer.', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
      FROM medicines
     WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- ----------------------------------------------------------------------------
-- (c) Procedure: pr_record_sale(p_medicine_id, p_quantity, p_sold_on) [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price     NUMERIC(10, 2);
    v_stock     INTEGER;
    v_sale_val  NUMERIC(12, 2);
BEGIN
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date (p_sold_on) cannot be NULL.';
    END IF;

    -- Validate medicine and quantity via function
    v_sale_val := fn_sale_value(p_medicine_id, p_quantity);

    -- Lock medicine row to safely check stock and prevent race conditions
    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: available %, requested %.',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- ----------------------------------------------------------------------------
-- (d) Trigger: AFTER UPDATE row trigger on medicines [8 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_medicines_stock_audit();

-- ----------------------------------------------------------------------------
-- (a cont.) Seed at least 3 medicines and 6 valid sales via pr_record_sale
-- ----------------------------------------------------------------------------
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg',  15.00, 25),
    ('Amoxicillin 250mg',  45.50, 14),
    ('Ibuprofen 400mg',    22.00, 30),
    ('Cetirizine 10mg',    18.00,  8);

CALL pr_record_sale(1, 5,  CURRENT_DATE - 2);
CALL pr_record_sale(1, 12, CURRENT_DATE - 1); -- drops stock from 20 to 8 (< 10)
CALL pr_record_sale(2, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 2,  CURRENT_DATE);     -- drops stock from 10 to 8 (< 10)
CALL pr_record_sale(3, 10, CURRENT_DATE);
CALL pr_record_sale(4, 3,  CURRENT_DATE);     -- drops stock from 8 to 5 (< 10)

-- ----------------------------------------------------------------------------
-- (e) View: v_low_stock [5 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10
ORDER BY stock_qty ASC, medicine_name ASC;

-- Query the view after sales
SELECT * FROM v_low_stock;

-- ----------------------------------------------------------------------------
-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite B-tree index on (medicine_id, sold_on) supports
-- equality lookup on medicine_id followed immediately by an ordered range scan
-- on sold_on without sorting or scanning unrelated medicines.
-- ----------------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on
    ON sales (medicine_id, sold_on);

EXPLAIN
SELECT sale_id, medicine_id, quantity, unit_price, sold_on
  FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- ----------------------------------------------------------------------------
-- (g) Scheduled job: pr_refresh_sales(p_day) & pg_cron [6 marks]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty    INTEGER;
    v_total_amount NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Target day (p_day) cannot be NULL.';
    END IF;

    SELECT COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0.00)
      INTO v_total_qty, v_total_amount
      FROM sales
     WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Test idempotent refresh
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);

COMMIT;

-- Schedule daily at 00:15 for the previous day (requires pg_cron extension)
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'pharmacy_daily_sales_refresh',
    '15 0 * * *',
    $$CALL pr_refresh_sales(CURRENT_DATE - 1);$$
);

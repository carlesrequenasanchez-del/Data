WITH initials AS (
    -- 1. Tu query original para detectar la entrada (Trials)
    SELECT          
        s.id,
        s.requested_unsubscribed_date,
        t.created_at AS trial_date,
        t.created_at::date AS date,
        TO_CHAR(DATE_TRUNC('week',t.created_at), 'DD') || '-' || TO_CHAR(DATE_TRUNC('week',t.created_at) + INTERVAL '6 days', 'DD Mon YYYY') || ' (W' || TO_CHAR(t.created_at, 'IW') || ')' AS week,
        c.ip_country
    FROM pdfeditor.customers c
    LEFT JOIN pdfeditor.transactions t ON t.customer_id = c.id
    LEFT JOIN pdfeditor.invoices_sii is2 ON is2.transaction_id = t.id
    LEFT JOIN pdfeditor.subscriptions s ON s.id = t.subscription_id 
    WHERE 
        t.created_at::date > '2026-01-01'
        AND c.email NOT LIKE '%leadtech%'
        AND t.transaction_status = 1
        AND t.transaction_type = 0
        AND t.amount < 5
        AND is2.invoice_number IS NOT NULL
),
payment_ranks AS (
    -- 2. Listamos todas las recurrencias exitosas (> 5) y las ordenamos cronológicamente
    SELECT 
        subscription_id,
        created_at,
        ROW_NUMBER() OVER (PARTITION BY subscription_id ORDER BY created_at ASC) AS seq
    FROM pdfeditor.transactions
    WHERE transaction_status = 1 
      AND transaction_type = 0 
      AND amount > 5
),
sub_milestones AS (
    -- 3. Extraemos la fecha exacta de R1 y R2 por cada usuario
    SELECT 
        subscription_id,
        MAX(CASE WHEN seq = 1 THEN created_at END) AS r1_date,
        MAX(CASE WHEN seq = 2 THEN created_at END) AS r2_date,
        MAX(CASE WHEN seq = 3 THEN created_at END) AS r3_date
    FROM payment_ranks
    GROUP BY subscription_id
),
user_stats AS (
    -- 4. Calculamos las recurrencias y clasificamos los eventos en ventanas de tiempo
    SELECT          
        i.id,
        i.ip_country,
        i.date,
        i.week,
        -- Tu lógica original de recurrencias reales (Pagas - Devueltas)
        SUM(CASE WHEN t.transaction_type = 0 AND t.amount > 5 THEN 1 ELSE 0 END) - 
        COALESCE(SUM(CASE WHEN t.transaction_type = 1 AND t.amount > 5 THEN 1 ELSE 0 END), 0) AS recurrences,
        -- Banderas de Unsubscribe (Requests)
        MAX(CASE 
            WHEN i.requested_unsubscribed_date IS NOT NULL 
                 AND (sm.r1_date IS NULL OR i.requested_unsubscribed_date < sm.r1_date) 
            THEN 1 ELSE 0 END) AS req_before_r1,
        MAX(CASE 
            WHEN i.requested_unsubscribed_date IS NOT NULL 
                 AND sm.r1_date IS NOT NULL 
                 AND i.requested_unsubscribed_date >= sm.r1_date
                 AND (sm.r2_date IS NULL OR i.requested_unsubscribed_date < sm.r2_date) 
            THEN 1 ELSE 0 END) AS req_before_r2,
        MAX(CASE 
            WHEN i.requested_unsubscribed_date IS NOT NULL 
                 AND sm.r2_date IS NOT NULL 
                 AND i.requested_unsubscribed_date >= sm.r2_date
                 AND (sm.r3_date IS NULL OR i.requested_unsubscribed_date < sm.r3_date) 
            THEN 1 ELSE 0 END) AS req_before_r3,
        -- Banderas de Refunds
        MAX(CASE 
            WHEN t.transaction_type = 1 
                 AND (sm.r1_date IS NULL OR t.created_at < sm.r1_date)
            THEN 1 ELSE 0 END) AS ref_before_r1,   
        MAX(CASE 
            WHEN t.transaction_type = 1 
                 AND sm.r1_date IS NOT NULL 
                 AND t.created_at >= sm.r1_date
                 AND (sm.r2_date IS NULL OR t.created_at < sm.r2_date)
            THEN 1 ELSE 0 END) AS ref_before_r2,
        MAX(CASE 
            WHEN t.transaction_type = 1 
                 AND sm.r2_date IS NOT NULL 
                 AND t.created_at >= sm.r2_date
                 AND (sm.r3_date IS NULL OR t.created_at < sm.r3_date)
            THEN 1 ELSE 0 END) AS ref_before_r3
    FROM initials i
    LEFT JOIN sub_milestones sm ON i.id = sm.subscription_id
    LEFT JOIN pdfeditor.transactions t ON t.subscription_id = i.id
    LEFT JOIN pdfeditor.invoices_sii is2 ON is2.transaction_id = t.id
    WHERE 
        t.transaction_status = 1
        AND is2.invoice_number IS NOT NULL
    GROUP BY 
        i.id, i.ip_country, i.date, i.week, i.requested_unsubscribed_date, sm.r1_date, sm.r2_date
)
-- 5. Tabla Final Agrupada
SELECT 
    date,
    week,
    ip_country,
    COUNT(id) AS sales,
    SUM(CASE WHEN recurrences > 0 THEN 1 ELSE 0 END) AS renewal_1,
    SUM(CASE WHEN recurrences > 1 THEN 1 ELSE 0 END) AS renewal_2,
    SUM(CASE WHEN recurrences > 2 THEN 1 ELSE 0 END) AS renewal_3,
    -- Usuarios que cancelaron la suscripción en las distintas ventanas
    SUM(req_before_r1) AS req_before_r1,
    SUM(req_before_r2) AS req_before_r2,
    SUM(req_before_r3) AS req_before_r3,
    -- Usuarios que solicitaron devoluciones (refunds) en las distintas ventanas
    SUM(ref_before_r1) AS ref_before_r1,
    SUM(ref_before_r2) AS ref_before_r2,
    SUM(ref_before_r3) AS ref_before_r3
FROM user_stats
GROUP BY 1, 2, 3
ORDER BY date DESC, ip_country
SELECT  
    COUNT(s.*) AS total,
	s.subscription_status
FROM transactions t 
LEFT JOIN invoices_sii is2 
    ON is2.transaction_id = t.id
LEFT JOIN subscriptions s 
    ON s.id = t.subscription_id 
LEFT JOIN customers c 
    ON s.customer_id_np = c.id 
WHERE 
    t.transaction_status = 1
    AND t.transaction_type = 0
    AND t.amount < 10
    AND c.email NOT LIKE '%leadtech%'
    AND is2.invoice_number IS NOT null
    --exclude subscriptions with refunds 
    AND s.id NOT IN (
        SELECT DISTINCT sub_s.id
        FROM transactions sub_t 
        LEFT JOIN invoices_sii sub_is2 
            ON sub_is2.transaction_id = sub_t.id
        LEFT JOIN subscriptions sub_s 
            ON sub_s.id = sub_t.subscription_id 
        WHERE 	
            sub_t.transaction_status = 1
            AND sub_t.transaction_type = 1
            AND sub_is2.invoice_number IS NOT NULL
            AND sub_s.id IS NOT NULL
    )
GROUP BY 2
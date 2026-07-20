SELECT
	s.id AS subscription_id,
	SUM(CASE WHEN t.transaction_type = 0 THEN 1 ELSE 0 END) - coalesce((SUM(CASE WHEN t.transaction_type = 1 THEN 1 ELSE 0 END)),0) AS tenure,
	SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - coalesce((SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END)),0) AS user_revenue,				
	MIN(t.payment_date) AS initial_payment_date,
	TO_CHAR(MIN(t.payment_date),'YYYY-MM') AS cohort,
	MAX(t.payment_date) AS latest_payment_date,	
	CASE WHEN (s.unsubscribed_date IS not null or s.subscription_status = 'Unsuscribed') THEN 'churned' ELSE 'active' END AS status,
    p.amount, 
    p.amount_trial,
    max(coalesce(hua.ip_country_iso_code, c.ip_country)) as ip_country 
FROM pdfeditor.transactions t
LEFT JOIN pdfeditor.subscriptions s	
    ON t.subscription_id = s.id	
join invoices_sii is2
	on is2.transaction_id = t.id
left join pdfeditor.products p2
on p2.id = s.product_id 
LEFT JOIN pdfeditor.subscription_types st
    ON st.id = s.subscription_type_id
LEFT JOIN pdfeditor.prices p
    ON p.id = st.price_id
left join pdfeditor.http_user_agents hua 
on hua.id = t.user_agent_id 
JOIN pdfeditor.customers c
    ON c.id = s.customer_id_np
    and c.email not like '%leadtech%'
where 
	s.subscription_status != 'Registered'
    and s.created_at::date > '2024-01-01'
    and t.transaction_status = 1
    and s.id not in ('25', '26','27','28') --filter subscription test
GROUP BY
    s.id,
    s.unsubscribed_date,
    p.amount,
    p.amount_trial
having				
    SUM(CASE WHEN t.transaction_type = 0 THEN 1 ELSE 0 END) - coalesce((SUM(CASE WHEN t.transaction_type = 1 THEN 1 ELSE 0 END)),0) > 0	
SELECT				
	s.id AS subscription_id,				
	SUM(CASE WHEN t.transaction_type = 0 THEN 1 ELSE 0 END) - coalesce((SUM(CASE WHEN t.transaction_type = 1 THEN 1 ELSE 0 END)),0) AS tenure,				
	SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - coalesce((SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END)),0) AS user_revenue,				
	MIN(t.payment_date) AS initial_payment_date,				
	TO_CHAR(MIN(t.payment_date),'YYYY-MM') AS cohort,				
	MAX(t.payment_date) AS latest_payment_date,				
	CASE WHEN (s.unsubscribed_date IS not null or s.subscription_status = 'Unsuscribed') THEN 'churned' ELSE 'active' END AS status,
	CASE WHEN utm_term like '%free%' then 'free' else 'other' end as keyword,
	p2.sub_product,
	LOWER(SPLIT_PART(c.email, '@', 2)) AS email_domain,
    CASE 
        WHEN LOWER(SPLIT_PART(c.email, '@', 2)) IN (      
        'gmail.com','yahoo.com','ymail.com','myyahoo.com',
        'hotmail.com','hotmail.es',
        'outlook.com','outlook.com.au','live.com',
        'icloud.com','me.com','mac.com',
        'aol.com','msn.com',       
        'protonmail.com','proton.me',
        'mail.com','gmx.com','mailfence.com','fastmail.com',      
        'comcast.net','verizon.net','att.net','bellsouth.net',
        'sbcglobal.net','earthlink.net','frontier.com',
        'cox.net','charter.net','windstream.net',
        'netzero.net','pacbell.net','prodigy.net',     
        '126.com','mail.ru','hushmail.com'
        ) THEN 'B2C' 
        ELSE 'B2B' 
    END AS user_segment,
    hua.device,
    p.amount, 
    p.amount_trial,
    coalesce(hua.ip_country_iso_code, c.ip_country) as ip_country 
FROM pdfeditor.subscriptions s	
left join pdfeditor.products p2
on p2.id = s.product_id 
LEFT JOIN pdfeditor.subscription_types st				
    ON st.id = s.subscription_type_id				
LEFT JOIN pdfeditor.prices p				
    ON p.id = st.price_id				
LEFT JOIN pdfeditor.transactions t				
    ON t.subscription_id = s.id				
AND t.transaction_status = 1
left join pdfeditor.http_user_agents hua 
on hua.id = t.user_agent_id 
left join pdfeditor.utms u 
    on u.id = t.utms_id 
JOIN pdfeditor.customers c				
    ON c.id = s.customer_id_np				
    and c.email not like '%leadtech%'				
where s.subscription_status != 'Registered'		
    and s.created_at::date > '2024-01-01'
    --and u.utm_term is not null
GROUP BY				
    s.id,				
    s.unsubscribed_date,
    keyword,
    p2.sub_product,
    email_domain,
    user_segment,
    device,  --start with mobile 01/09/2025,
    13,14,15
having				
    SUM(CASE WHEN t.transaction_type = 0 THEN 1 ELSE 0 END) - coalesce((SUM(CASE WHEN t.transaction_type = 1 THEN 1 ELSE 0 END)),0) > 0				
    and s.id not in ('25', '26','27','28')	
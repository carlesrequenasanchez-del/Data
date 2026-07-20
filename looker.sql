select  
	  	SUM(case when t.transaction_type = 0 and p.amount_trial = t.amount then 1 else 0 end) as sales,
	  	t.created_at::date as date,
	  	c.ip_country,
	  	concat(extract(year FROM t.created_at),'-W',extract(week FROM t.created_at)) as week,
	  	CASE
		    WHEN ip_country = 'AU' THEN '98,88'
		    WHEN ip_country = 'ES' THEN '101,60'
		    WHEN ip_country = 'DE' THEN '115,02'
		    WHEN ip_country = 'CA' THEN '86,52'
		    WHEN ip_country = 'MX' THEN '97,45'
		    WHEN ip_country = 'US' THEN '101,60'
		    WHEN ip_country = 'IT' THEN '88,83'
		    WHEN ip_country = 'GB' THEN '86,98'
		    WHEN ip_country = 'FR' THEN '77,02'
		    WHEN ip_country = 'NL' THEN '76,70'
		    WHEN ip_country = 'BR' THEN '64,88'
		    WHEN ip_country = 'PL' THEN '108,31'
		    WHEN ip_country = 'SA' THEN '89,47'
		    WHEN ip_country = 'PH' THEN '45,72'
		    WHEN ip_country = 'IN' THEN '19,22'
		    ELSE '101,60'
		END AS ltv,
	  	(SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END), 0))::BIGINT AS user_revenue,
	  	--SUM(CASE WHEN t.transaction_type = 0 and t.amount >5 then 1 else 0 end) - coalesce((SUM(CASE WHEN t.transaction_type = 1 and t.amount >5 then 1 else 0 end)),0) AS recurrences,
	  	sum(case when t.transaction_type = 1 then 1 else 0 end) as refunds,
	  	COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END), 0)::BIGINT AS amount_refunds
	from customers c
	left join transactions t 
	on t.customer_id = c.id and t.transaction_status = 1
	left join http_user_agents hua 
	on hua.id = t.user_agent_id 
	left join invoices_sii is2 
	on is2.transaction_id = t.id
	left join subscriptions s 
	on s.id = t.subscription_id 
	left join subscription_types st
	on st.id = s.subscription_type_id 
	left join prices p 
	on p.id = st.price_id
	where 
		t.created_at::date >= '2026-01-01'
		and email not like '%leadtech%'
		and is2.invoice_number is not null
	group by 2,3,4
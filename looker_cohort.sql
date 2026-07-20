with 
	initials as (
		select     		
		    s.id,
		    t.created_at::date as date,
		    TO_CHAR(DATE_TRUNC('week',t.created_at), 'DD') || '-' || TO_CHAR(DATE_TRUNC('week',t.created_at) + INTERVAL '6 days', 'DD Mon YYYY') || ' (W' || TO_CHAR(t.created_at, 'IW') || ')' as week,
		   	c.ip_country
		from pdfeditor.customers c
		left join pdfeditor.transactions t 
			on t.customer_id = c.id
		left join pdfeditor.invoices_sii is2 
			on is2.transaction_id = t.id
		left join pdfeditor.subscriptions s 
			on s.id = t.subscription_id 
		left join pdfeditor.subscription_types st
			on  st.id = s.subscription_type_id
		left join pdfeditor.prices p
			on p.id = st.price_id
		where 
			t.created_at::date > '2026-01-01'
			--and t.created_at < current_timestamp - interval '8 days'
			and email not like '%leadtech%'
			and t.transaction_status = 1
			and t.transaction_type = 0
			and t.amount <5
			and is2.invoice_number is not null
	),
	recurrences as (
		select     		
		    i.id,
		    i.ip_country,
		    date,
		    week,
		    (SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END), 0))::BIGINT AS user_revenue,
		    SUM(CASE WHEN t.transaction_type = 0 and t.amount >5 then 1 else 0 end) - coalesce((SUM(CASE WHEN t.transaction_type = 1 and t.amount >5 then 1 else 0 end)),0) AS recurrences,
		    SUM(CASE WHEN t.transaction_type = 1 then 1 else 0 end) AS refunds
		from initials i
		left join pdfeditor.transactions t 
		on t.subscription_id = i.id
		left join pdfeditor.invoices_sii is2 
		on is2.transaction_id = t.id
		left join pdfeditor.subscriptions s 
		on s.id = t.subscription_id 
		where 
			t.transaction_status = 1
			--and t.transaction_type = 0
			and is2.invoice_number is not null
		group by 1,2,3,4
)
select 
	count(id) as sales,
	ip_country,
	date,
	week,
	sum(user_revenue) as revenue,
	SUM(CASE WHEN recurrences >0 then 1 else 0 end) as renewal,
	SUM(CASE WHEN recurrences >1 then 1 else 0 end) as renewal_2,
	sum (refunds) as refunds
from recurrences
group by 2,3,4

		
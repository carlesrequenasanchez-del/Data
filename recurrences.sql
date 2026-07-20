  --price increase to 49,95 Mar 25 
  --price increase to 39,95 JAn 07 
with 
	initials as (
		select     		
		    s.id,
		    t.created_at::date as initial_purchase_date,
		   	c.ip_country,
		   	p.amount
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
			t.created_at::date > '2026-01-07'
			and t.created_at < current_timestamp - interval '8 days'
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
		    i.initial_purchase_date,
		    i.amount
		from initials i
		left join pdfeditor.transactions t 
		on t.subscription_id = i.id
		left join pdfeditor.invoices_sii is2 
		on is2.transaction_id = t.id
		left join pdfeditor.subscriptions s 
		on s.id = t.subscription_id 
		where 
			t.transaction_status = 1
			and t.transaction_type = 0
			and is2.invoice_number is not null
		order by id asc
)
select 
	id,
	ip_country,
	initial_purchase_date,
	amount,
	count(id)-1 as n_recurrences
from recurrences
group by 1,2,3,4
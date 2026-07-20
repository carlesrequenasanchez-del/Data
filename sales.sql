select  
    count(t.*) as n_sales,
    t.created_at::date,
    --date(c.created_at) as created_at_register,  
    --extract(week FROM created_at) as week, 
    --st."name" 
   -- hua.platform,
   -- hua.device
   c.ip_country 
from pdfeditor.customers c
left join pdfeditor.transactions t 
on t.customer_id = c.id
left join pdfeditor.http_user_agents hua 
on hua.id = t.user_agent_id 
left join pdfeditor.invoices_sii is2 
on is2.transaction_id = t.id
left join pdfeditor.subscriptions s 
on s.id = t.subscription_id 
left join pdfeditor.subscription_types st
on st.id = s.subscription_type_id 
where t.created_at::date < '2026-03-19'
and email not like '%leadtech%'
and t.transaction_status = 1
and t.transaction_type = 0
and t.amount < 10
and is2.invoice_number is not null
--and ip_country = 'C'
--and hua.device = 'Mobile'
--in ('AU','IT','CA','DE','GB','FR','ES','JP','NL')
group by 2,3--,3


select	
    date(r.created_at) as created_at,	
    null as a,	
    null as a2,	
    r.email,	
    r.rating,	
    replace(replace(r.comment, chr(10), ' '), chr(13), ' ') as comment,	
    s.subscription_status,	
    st.name	
from pdfeditor.reviews r	
left join pdfeditor.customers c	
    on r.email = c.email	
left join (	
    select distinct on (customer_id_np) *	
    from pdfeditor.subscriptions	
    order by customer_id_np, created_at desc	
) s	
    on s.customer_id_np = c.id	
left join pdfeditor.subscription_types st	
    on st.id = s.subscription_type_id	
where 
    r.created_at > '2026-02-03'	
    and (r.email not like '%leadtech%' or r.email not like '%test%')	
    order by 1 ASC	
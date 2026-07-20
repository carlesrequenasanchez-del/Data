select  
    count(s.*),
    s.subscription_status 
from transactions t 
left join subscriptions s 
on s.id = t.subscription_id 
left join customers c 
on s.customer_id_np = c.id 
where 
	t.transaction_status =1
	and t.transaction_type = 0
	and t.amount <5
	and email not like '%leadtech%'
group by 2
select  
    count(*) as n_registers,  
    date(c.created_at) as created_at_register,  
    ip_country
from customers c  
where c.created_at::date = '2026-03-19'-- between '2025-12-22 00:00:00.000' and '2025-12-28 23:59:59.999'
and email not like '%leadtech%'
--and ip_country in ('AU','IT','CA','DE','GB','FR','ES','JP','NL')
group by 2,3
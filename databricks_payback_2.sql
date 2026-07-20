
with 
sales_cohort as (
    select
        s.id,
        t.created_at::date as cohort_date,
        coalesce(c.ip_country,hua.ip_country_iso_code) as ip_country,
        er.rate
    FROM bronze.pdf.customers c
    LEFT JOIN bronze.pdf.transactions t
        ON t.customer_id = c.id
        and t.transaction_status = 1
        and t.transaction_type = 0
        and t.created_at::DATE >= '2026-01-01'
    LEFT JOIN silver.currencies.eur_exchange_rates er 
        on er.date = t.created_at::date and er.code = t.currency
    LEFT JOIN bronze.pdf.http_user_agents hua
        ON hua.id = t.user_agent_id
    INNER JOIN bronze.pdf.invoices_sii is2
        ON is2.transaction_id = t.id
    LEFT JOIN bronze.pdf.subscriptions s
        ON s.id = t.subscription_id
    LEFT JOIN bronze.pdf.subscription_types st
        ON st.id = s.subscription_type_id
    LEFT JOIN bronze.pdf.prices p
        ON p.id = st.price_id
    where
        c.email not like '%leadtech%'
        and p.amount_trial = t.amount
)
select
    sc.cohort_date,
    sc.ip_country,
    SUM(t.amount / NULLIF(sc.rate, 0)) AS total_amount,
    (
        SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END / NULLIF(sc.rate, 0)) 
        - COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END / NULLIF(sc.rate, 0)), 0)
    )::NUMERIC(10, 2) AS real_revenue
from sales_cohort sc
left join bronze.pdf.transactions t
        ON sc.id = t.subscription_id
        and t.transaction_status = 1
group by 1, 2

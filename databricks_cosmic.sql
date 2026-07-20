 
  with 
    charges as (
        select
          c.captured_at::date as date,
           c.description,
           c.id,
           c.amount/100 as amount, --the amount is setted incorrectly
           er.rate,
           c.amount_refunded/100 as amount_refunded,--the amount is setted incorrectly
           coalesce(c.card_country,c.card_address_country, 'UNKNOWN') as ip_country,
           i.subscription_id,
           r.amount as refund_amount
        from bronze.stripe.charges c
        left join (
          select
            r.amount/100 as amount,
            r.id,
            r.charge_id
          from bronze.stripe.refunds r
          where
            r.merchant_id = 'acct_1TYnL9Ir47dcqvAx'
            and r.status = 'succeeded'
          ) r
          on c.id = r.charge_id
        inner join bronze.stripe.invoices i
          on c.id = i.charge_id
        LEFT JOIN silver.currencies.eur_exchange_rates er 
          on er.date = c.captured_at::date and lower(er.code) = c.currency
        inner join bronze.stripe.customers c2
          on c.customer_id = c2.id and (c2.email not like '%leadtech%' or c2.email is null)
        where
          c.merchant_id = 'acct_1TYnL9Ir47dcqvAx'
          and c.status = 'succeeded'),
    sales_cohort as (
      select
          subscription_id,
          date as cohort_date,
          ip_country,
          rate
          from charges c
          where description = 'Subscription creation'
            and subscription_id = 'sub_1TlG11Ir47dcqvAx5CSp9gIp'
          ),
    transactions_ranked as (
      select 
        sc.cohort_date,
        sc.ip_country,
        count(c.id) as sub_charges,
        sum(case when c.refund_amount > 0 then 1 else 0 end)  as sub_refunds,
        (SUM(c.amount / NULLIF(c.rate, 0)) - COALESCE(SUM(c.amount_refunded / NULLIF(c.rate, 0)), 0))::NUMERIC(10, 2) AS real_revenue
      from sales_cohort sc
      left join charges c
        on sc.subscription_id = c.subscription_id
      group by 1,2
    )
    select *
    from transactions_ranked
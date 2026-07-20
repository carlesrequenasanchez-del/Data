--select * 
--from bi.web_bi_dashboards.pdf_metrics
with 
	country_mapping AS (
		select 
			LOWER(TRIM(c.country_name)) as c_name, 
			c.country_iso_2 as iso
		from silver.dicts.countries c
	),
	sem_spend as (
		select 
			date,
			case when geo = 'UK' then 'GB' else geo end as ip_country,  
			round(sum(costs), 2) as spend 
    from silver.pdf.marketing_spends
    where date >= '2026-01-01' 
    group by 1, 2),
	db as (
		select  
				SUM(case when t.transaction_type = 0 and p.amount_trial = t.amount then 1 else 0 end) as sales,
				t.created_at::date as date,
				c.ip_country,
				CASE
					WHEN ip_country = 'AU' THEN 98.88
					WHEN ip_country = 'ES' THEN 101.60
					WHEN ip_country = 'DE' THEN 115.02
					WHEN ip_country = 'CA' THEN 86.52
					WHEN ip_country = 'MX' THEN 97.45
					WHEN ip_country = 'US' THEN 101.60
					WHEN ip_country = 'IT' THEN 88.83
					WHEN ip_country = 'GB' THEN 86.98
					WHEN ip_country = 'FR' THEN 77.02
					WHEN ip_country = 'NL' THEN 76.70
					WHEN ip_country = 'BR' THEN 64.88
					WHEN ip_country = 'PL' THEN 108.31
					WHEN ip_country = 'SA' THEN 89.47
					WHEN ip_country = 'PH' THEN 45.72
					WHEN ip_country = 'IN' THEN 19.22
					ELSE 101.60
				END AS ltv,
				(SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END), 0))::BIGINT AS user_revenue,
				sum(case when t.transaction_type = 1 then 1 else 0 end) as refunds,
				COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END), 0)::BIGINT AS amount_refunds
			from bronze.pdf.customers c
			left join bronze.pdf.transactions t 
				on t.customer_id = c.id
			left join bronze.pdf.http_user_agents hua 
				on hua.id = t.user_agent_id 
			left join bronze.pdf.invoices_sii is2 
				on is2.transaction_id = t.id
			left join bronze.pdf.subscriptions s 
				on s.id = t.subscription_id 
			left join bronze.pdf.subscription_types st
				on st.id = s.subscription_type_id 
			left join bronze.pdf.prices p
				on p.id = st.price_id
			where 
				t.created_at::date >= '2026-01-01'
				and email not like '%leadtech%'
				and t.transaction_status = 1
				and is2.invoice_number is not null
			group by 2,3,4),
	amplitude as (
		select 
			count(distinct if(event_type = 'landing_page_viewed', amplitude_id, null)) as landing_page_viewers,
			count(distinct if(event_type = 'upload_document', amplitude_id, null)) as upload_document_users,
			count(distinct if(event_type = 'sign_up', amplitude_id, null)) as usign_ups,
			count(distinct if(event_type = 'payment_page_viewed', amplitude_id, null)) as payment_page_viewers,
			event_time::date as date,
			coalesce(m.iso, a.country) as ip_country
		from silver.amplitude.events a
		left join country_mapping m 
            on lower(trim(a.country)) = m.c_name
		where 
			a.project_id in ('pdf-web', 'pdf_editor') 
			and a.environment = 'prod'
			and event_time::date >= '2026-01-01' 
		group by date, ip_country
		),
	master_dim as (
		select 
			date, 
			ip_country 
		from sem_spend
			union 
		select 
			date, 
			ip_country 
		from db
			union 
		select 
			date, 
			ip_country 
		from amplitude
	),
	payback as (
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
				),
			transactions_ranked as (
                select
					sc.id as subscription_id,
                    sc.cohort_date,
                    sc.ip_country,
                    sc.rate,
                    t.transaction_type,
                    t.amount,
                    t.created_at,
                    row_number() over (
                        partition by sc.id, t.transaction_type 
                        order by t.created_at
                    ) as tx_rank,
					sum(case when t.transaction_type = 0 then 1 else 0 end) over (partition by sc.id) as sub_charges,
                    sum(case when t.transaction_type = 1 then 1 else 0 end) over (partition by sc.id) as sub_refunds
                from sales_cohort sc
                left join bronze.pdf.transactions t
                    ON sc.id = t.subscription_id
                    and t.transaction_status = 1
				)
		select
			cohort_date,
			ip_country,
			sum(sub_charges) as charges, 
			sum(sub_refunds) as refunds,
			(
				SUM(CASE WHEN transaction_type = 0 THEN amount ELSE 0 END / NULLIF(rate, 0)) 
				- COALESCE(SUM(CASE WHEN transaction_type = 1 THEN amount ELSE 0 END / NULLIF(rate, 0)), 0)
			)::NUMERIC(10, 2) AS real_revenue,
			(
                SUM(CASE WHEN transaction_type = 0 AND tx_rank <= 3 THEN amount ELSE 0 END / NULLIF(rate, 0)) 
                - COALESCE(SUM(CASE WHEN transaction_type = 1 AND created_at::date <= cohort_date + 37 THEN amount ELSE 0 END / NULLIF(rate, 0)), 0)
            )::NUMERIC(10, 2) AS real_revenue_37d,
			count(distinct case when (sub_charges - sub_refunds) > 1 then subscription_id end) as first_renewals
		from transactions_ranked
		group by 1, 2
		)
select 
    m.date,
    m.ip_country,
    coalesce(s.spend, 0) as spend,
    coalesce(db.sales, 0) as sales,
	coalesce(db.ltv, 0) as ltv,
    coalesce(db.user_revenue, 0) as user_revenue,    
    --coalesce(db.refunds, 0) as refunds,
    coalesce(db.amount_refunds, 0) as amount_refunds,
    coalesce(a.landing_page_viewers, 0) as landing_page_viewers,
    coalesce(a.payment_page_viewers, 0) as payment_page_viewers,
    coalesce(a.upload_document_users, 0) as upload_document_users, 
    coalesce(a.usign_ups, 0) as usign_ups,
	coalesce(pb.real_revenue, 0) as real_revenue,
	coalesce(pb.real_revenue_37d, 0) as real_revenue_37d,
	coalesce(pb.charges, 0) as charges,
	coalesce(pb.refunds, 0) as refunds,
	coalesce(pb.first_renewals, 0) as first_renewals,
	sum(db.sales) over (partition by m.date) as grand_total_sales,
	sum(s.spend) over (partition by m.date) as grand_total_spend
from master_dim m
left join sem_spend s on m.date = s.date and m.ip_country = s.ip_country
left join db on m.date = db.date and m.ip_country = db.ip_country
left join amplitude a on m.date = a.date and m.ip_country = a.ip_country
left join payback pb on m.date = pb.cohort_date and m.ip_country = pb.ip_country
order by spend DESC
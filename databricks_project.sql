WITH
    transactions AS (        
        select 
            m.event_date as date,
            m.event_type,
            m.subscription_id,
            m.event_subtype,
            m.recurrence_cycle, 
            m.card_address_country as ip_country,
            m.gross_amount,
            m.payment_method_type,
            case 
                when m.merchant_id in ('acct_1TYnL9Ir47dcqvAx', 'acct_1TiU6PEdo9L76pmz') then 'Cosmic' 
                when m.merchant_id in ('acct_1SD2VNCVUJnyBfx6', 'acct_1TQoWFClqJv8asWw', 'acct_1QSfJrEeDNlVSPsk') then 'Merged'
                when m.merchant_id in ('acct_1TN7CJCpi1ShflFN', 'acct_1TQoq8CbB8Drwc9S') then 'Pdfhint' 
                else 'NULL'
            end as site
        from gold.dm_web.money_movements m
        where merchant_id in('acct_1SD2VNCVUJnyBfx6','acct_1TQoWFClqJv8asWw','acct_1QSfJrEeDNlVSPsk','acct_1TN7CJCpi1ShflFN','acct_1TQoq8CbB8Drwc9S','acct_1TYnL9Ir47dcqvAx','acct_1TiU6PEdo9L76pmz')
        and status = 'succeeded'
        and event_date >= '2026-01-01'
    ),
    sales as (
        select
            SUM(case when t.event_subtype = 'initial_purchase' then 1 else 0 end) as sales,
            date,
            site,
            ip_country,
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
                end as ltv,
                sum(t.gross_amount) as user_revenue,
                SUM(case when t.event_type = 'refund' then 1 else 0 end) as refunds,
                COALESCE(SUM(CASE WHEN t.event_type = 'refund' THEN t.gross_amount ELSE 0 END), 0)*-1.00 AS amount_refunds
        from transactions t
        group by 2, 3, 4, 5    
    ),
    sem_spend as (
		select 
			date,
			case when geo = 'UK' then 'GB' else geo end as ip_country, 
            'Merged' as site, 
			round(sum(costs), 2) as spend 
        from silver.pdf.marketing_spends
        where date >= '2026-01-01' 
        group by 1, 2, 3
    UNION
        select
           ms.date,
           coalesce(case when geo = 'UK' then 'GB' else geo end, 'UNKNOWN') as ip_country,
           'Cosmic' as site,
           sum(ms.costs) as spend
         from silver.web.marketing_spends ms
         where
           project_id = 'cosmic-pdf-web'
         group by
           1, 2, 3
    ),
    country_mapping AS (
		select 
			LOWER(TRIM(c.country_name)) as c_name, 
			c.country_iso_2 as iso
		from silver.dicts.countries c
	),
    amplitude_merged as (
    select 
			count(distinct if(event_type = 'landing_page_viewed', amplitude_id, null)) as landing_page_viewers,
			count(distinct if(event_type = 'upload_document', amplitude_id, null)) as upload_document_users,
			count(distinct if(event_type = 'sign_up', amplitude_id, null)) as usign_ups,
			count(distinct if(event_type = 'payment_page_viewed', amplitude_id, null)) as payment_page_viewers,
			event_time::date as date,
            'Merged' as site,
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
    amplitude_cosmic as (
        with
            events as (
                select 
	            	event_time::date as date,
	            	event_properties:page_name::string AS page_name, 
	            	amplitude_id, 
	            	event_type,
	            	coalesce(m.iso, a.country) as ip_country
	            from silver.amplitude.events a
	            left join country_mapping m 
                    on lower(trim(a.country)) = m.c_name
	            where 
	            	a.project_id = ('pdf_cosmic-web') 
	            	and a.environment = 'prod'
	            	and event_time::date >= '2026-01-01' 
	            	and event_type in ('view_page', 'begin_checkout','click','view')
            )
        select 
		    	count(distinct if(event_type = 'view_page' and page_name ='tool_page', amplitude_id, null)) as landing_page_viewers,
		    	date,
		    	ip_country,
                'Cosmic' as site
		    from events e
		    group by date, ip_country
    ),
    amplitude as (
        select 
            landing_page_viewers,
            date,
            ip_country,
            site
        from amplitude_merged
        UNION
        select 
            landing_page_viewers,
            date,
            ip_country,
            site
        from amplitude_cosmic
    ),
	master_dim as (
		select 
			date, 
			ip_country,
            site
		from sem_spend
			union 
		select 
			date, 
			ip_country,
            site 
		from sales
			union 
		select 
			date, 
			ip_country,
            site 
		from amplitude
    ),
    payback as (
        WITH
            sales_cohort as (
                select 
                    t.subscription_id,
                    t.date as cohort_date,
                    t.ip_country,
                    site
                from transactions t
                where event_subtype = 'initial_purchase'
            ),
            transactions_ranked as (
                select
					sc.subscription_id,
                    sc.cohort_date,
                    sc.ip_country,
                    sc.site,
                    t.event_subtype,
                    t.event_type,
                    t.gross_amount,
                    t.date,
                    row_number() over (
                        partition by sc.subscription_id, t.event_type 
                        order by t.date
                    ) as tx_rank,
					sum(case when t.event_type in ('charge') then 1 else 0 end) over (partition by sc.subscription_id) as sub_charges,
                    sum(case when t.event_type in ('refund') then 1 else 0 end) over (partition by sc.subscription_id) as sub_refunds
                from sales_cohort sc
                left join transactions t
                    ON sc.subscription_id = t.subscription_id
				)
            select
        			cohort_date,
        			ip_country,
                    site,
        			sum(sub_charges) as charges, 
        			sum(sub_refunds) as refunds,
                    SUM(gross_amount) AS real_revenue,
        			SUM(CASE WHEN  tx_rank <= 3 THEN gross_amount ELSE 0 END) AS real_revenue_37d,
        			count(distinct case when (sub_charges - sub_refunds) > 1 then subscription_id end) as first_renewals
        	from transactions_ranked
        	group by 1, 2, 3
		)
select 
    m.date,
    m.ip_country,
    m.site,
    coalesce(s.spend, 0) as spend,
    coalesce(sa.sales, 0) as sales,
	coalesce(sa.ltv, 0) as ltv,
    coalesce(sa.user_revenue, 0) as user_revenue,    
    --coalesce(db.refunds, 0) as refunds,
    coalesce(sa.amount_refunds, 0) as amount_refunds,
    coalesce(a.landing_page_viewers, 0) as landing_page_viewers,
    --coalesce(a.payment_page_viewers, 0) as payment_page_viewers,
    --coalesce(a.upload_document_users, 0) as upload_document_users, 
    --coalesce(a.usign_ups, 0) as usign_ups,
	coalesce(pb.real_revenue, 0) as real_revenue,
	coalesce(pb.real_revenue_37d, 0) as real_revenue_37d,
	coalesce(pb.charges, 0) as charges,
	coalesce(pb.refunds, 0) as refunds,
	coalesce(pb.first_renewals, 0) as first_renewals,
	sum(sa.sales) over (partition by m.date) as grand_total_sales,
	sum(s.spend) over (partition by m.date) as grand_total_spend
from master_dim m
left join sem_spend s on m.date = s.date and m.ip_country = s.ip_country and m.site = s.site
left join sales sa on m.date = sa.date and m.ip_country = sa.ip_country and m.site = sa.site
left join amplitude a on m.date = a.date and m.ip_country = a.ip_country and m.site = a.site
left join payback pb on m.date = pb.cohort_date and m.ip_country = pb.ip_country and m.site = pb.site

 

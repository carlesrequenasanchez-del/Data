with
	initials as (
		select     		
		    s.id,
		    CASE WHEN utm_term ilike ('%free%') or utm_term ilike ('%gratis%') or utm_term ilike ('%gratuit%')  then 'free' else 'other' end as keyword,
		    t.created_at::date as cohort_date,
			-- Conversion amount_recurrence
		   	p.amount * CASE 
                WHEN p.currency = 'EUR' THEN 1.0
                WHEN p.currency = 'AUD' THEN 0.61124
                WHEN p.currency = 'USD' THEN 0.85614
                WHEN p.currency = 'CAD' THEN 0.628425
                WHEN p.currency = 'GBP' THEN 1.157
                ELSE 1.0 
            END AS amount_recurrence,
            -- Conversión de amount_trial
		   	p.amount_trial * CASE 
                WHEN p.currency = 'EUR' THEN 1.0
                WHEN p.currency = 'AUD' THEN 0.61124
                WHEN p.currency = 'USD' THEN 0.85614
                WHEN p.currency = 'CAD' THEN 0.628425
                WHEN p.currency = 'GBP' THEN 1.157
                ELSE 1.0 
            END AS amount_trial,
		   	p.currency
		FROM pdfeditor.customers c
        LEFT JOIN pdfeditor.transactions t ON t.customer_id = c.id
        LEFT JOIN pdfeditor.utms u on u.id = t.utms_id
        LEFT JOIN pdfeditor.invoices_sii is2 ON is2.transaction_id = t.id
        LEFT JOIN pdfeditor.subscriptions s ON s.id = t.subscription_id 
        LEFT JOIN pdfeditor.subscription_types st ON st.id = s.subscription_type_id
        LEFT JOIN pdfeditor.prices p ON p.id = st.price_id
		where 
		 	t.created_at::DATE >= '2026-01-01' --cohort dates start 
			and email not like '%leadtech%'
			and t.transaction_status = 1
			and t.transaction_type = 0
			and t.amount <10
			and is2.invoice_number is not null
		),
		user_activity as (
		select 
			i.id,
			i.cohort_date,
			i.keyword,
            i.amount_trial,
            i.amount_recurrence,
            --net revenue today
            (SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - COALESCE(SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END), 0))::NUMERIC(10,2) AS real_user_revenue,
            --net recurrences today
            SUM(CASE WHEN t.transaction_type = 0 AND t.amount > 5 THEN 1 ELSE 0 END) - COALESCE(SUM(CASE WHEN t.transaction_type = 1 AND t.amount > 5 THEN 1 ELSE 0 END), 0) AS recurrences
		from initials i
		LEFT JOIN pdfeditor.transactions t ON t.subscription_id = i.id
        LEFT JOIN pdfeditor.invoices_sii is2 ON is2.transaction_id = t.id
        LEFT JOIN pdfeditor.subscriptions s ON s.id = t.subscription_id 
        WHERE 
            t.transaction_status = 1
            AND is2.invoice_number IS NOT NULL
        GROUP BY 1, 2, 3, 4, 5
		)
		SELECT 
		    ua.cohort_date,
		    ua.keyword,
		    COUNT(ua.id) AS new_sales,
		    REPLACE(ROUND(SUM(
		        CASE WHEN ua.recurrences = 0 THEN ua.amount_trial
		             WHEN ua.recurrences = 1 THEN ua.amount_trial + ua.amount_recurrence
		             WHEN ua.recurrences >= 2 THEN ua.amount_trial + (2 * ua.amount_recurrence)
		             ELSE 0 END
		    )::NUMERIC, 2)::TEXT, '.', ',') AS real_d35_revenue
		FROM user_activity ua
		GROUP BY 1,2
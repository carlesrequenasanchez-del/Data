with initials as (
  select
    s.id,
    t.created_at::date as cohort_date,
    c.ip_country,
    --hua.device,
    -- Conversion amount_recurrence
    p.amount
      * CASE
        WHEN p.currency = 'EUR' THEN 1.0
        WHEN p.currency = 'AUD' THEN 0.61124
        WHEN p.currency = 'USD' THEN 0.85614
        WHEN p.currency = 'CAD' THEN 0.628425
        WHEN p.currency = 'GBP' THEN 1.157
        ELSE 1.0
      END AS amount_recurrence,
    -- Conversión de amount_trial
    p.amount_trial
      * CASE
        WHEN p.currency = 'EUR' THEN 1.0
        WHEN p.currency = 'AUD' THEN 0.61124
        WHEN p.currency = 'USD' THEN 0.85614
        WHEN p.currency = 'CAD' THEN 0.628425
        WHEN p.currency = 'GBP' THEN 1.157
        ELSE 1.0
      END AS amount_trial,
    p.currency
  FROM
    customers c
      LEFT JOIN transactions t
        ON t.customer_id = c.id
        and t.transaction_status = 1
        and t.transaction_type = 0
        and t.amount < 5
        and t.created_at::DATE >= '2026-01-01'
      LEFT JOIN http_user_agents hua
        ON hua.id = t.user_agent_id
      LEFT JOIN invoices_sii is2
        ON is2.transaction_id = t.id
      LEFT JOIN subscriptions s
        ON s.id = t.subscription_id
      LEFT JOIN subscription_types st
        ON st.id = s.subscription_type_id
      LEFT JOIN prices p
        ON p.id = st.price_id
  where
    c.email not like '%leadtech%'
    and is2.invoice_number is not null
),
user_activity as (
  select
    i.id,
    i.cohort_date,
    i.ip_country,
    --i.device,
    i.amount_trial,
    i.amount_recurrence,
    --net revenue today
    (
      SUM(
        CASE
          WHEN t.transaction_type = 0 THEN t.amount
          ELSE 0
        END
      )
        - COALESCE(
          SUM(
            CASE
              WHEN t.transaction_type = 1 THEN t.amount
              ELSE 0
            END
          ),
          0
        )
    )::NUMERIC(10, 2) AS real_user_revenue,
    --net recurrences today
    SUM(
      CASE
        WHEN
          t.transaction_type = 0
          AND t.amount > 5
        THEN
          1
        ELSE 0
      END
    )
      - COALESCE(
        SUM(
          CASE
            WHEN
              t.transaction_type = 1
              AND t.amount > 5
            THEN
              1
            ELSE 0
          END
        ),
        0
      ) AS recurrences
  from
    initials i
      LEFT JOIN transactions t
        ON t.subscription_id = i.id
      LEFT JOIN invoices_sii is2
        ON is2.transaction_id = t.id
      LEFT JOIN subscriptions s
        ON s.id = t.subscription_id
  WHERE
    t.transaction_status = 1
    AND is2.invoice_number IS NOT NULL
  GROUP BY
    1,
    2,
    3,
    4,
    5 --,6
),
historical_ratios AS (
  SELECT
    ip_country,
    COUNT(id) AS sample_size,
    (
      SUM(
        CASE
          WHEN recurrences > 0 THEN 1
          ELSE 0
        END
      )
        * 1.0
        / COUNT(id)
    ) AS r1, -- Probability to arrive to D7
    (
      SUM(
        CASE
          WHEN recurrences > 1 THEN 1
          ELSE 0
        END
      )
        * 1.0
        / COUNT(id)
    ) AS r2 -- Probability to arrive to D35
  FROM
    user_activity
  WHERE
    cohort_date <= CURRENT_DATE - INTERVAL '45 days'
  GROUP BY
    1
  HAVING
    COUNT(id) > 50
),
marketing_weekly AS (
  SELECT
    DATE_TRUNC('WEEK', date::date) AS cost_week,
    geo,
    SUM(costs) AS costs
  FROM
    silver.pdf.marketing_spends
  GROUP BY
    1,
    2
)
SELECT
  DATE_TRUNC('WEEK', ua.cohort_date) AS cohort_week,
  ua.ip_country,
  --ua.device,
  mw.costs,
  COUNT(ua.id) AS new_sales,
  -- Metric: Predictive revenue (Theorical)
  ROUND(
    SUM(
      ua.amount_trial
        + (ua.amount_recurrence * COALESCE(hr.r1, 0))
        + (ua.amount_recurrence * COALESCE(hr.r2, 0))
    )::NUMERIC,
    2
  ) AS predicted_d35_revenue,
  -- Metric: Real Revenue D35
  ROUND(
    SUM(
      CASE
        WHEN ua.recurrences = 0 THEN ua.amount_trial
        WHEN ua.recurrences = 1 THEN ua.amount_trial + ua.amount_recurrence
        WHEN ua.recurrences >= 2 THEN ua.amount_trial + (2 * ua.amount_recurrence)
        ELSE 0
      END
    )::NUMERIC,
    2
  ) AS real_d35_revenue,
  ROUND(
    SUM(
      CASE
        WHEN
          DATE_DIFF(CURRENT_DATE(), ua.cohort_date) > 37
        THEN
          -- If is major than 37 days, we use real revenue
          CASE
            WHEN ua.recurrences = 0 THEN ua.amount_trial
            WHEN ua.recurrences = 1 THEN ua.amount_trial + ua.amount_recurrence
            WHEN ua.recurrences >= 2 THEN ua.amount_trial + (2 * ua.amount_recurrence)
          END
        ELSE 0
      -- If not, we cannot calculate real Payback period
      END
    )::NUMERIC,
    2
  ) AS smart_d35_revenue
FROM
  user_activity ua
    LEFT JOIN marketing_weekly mw
      ON mw.cost_week = DATE_TRUNC('WEEK', ua.cohort_date)
      AND mw.geo = ua.ip_country
    LEFT JOIN historical_ratios hr
      ON hr.ip_country = ua.ip_country
where
  ua.ip_country is not null
  and ua.ip_country in ('US', 'AU', 'CA', 'BR', 'GB', 'FR', 'ES', 'DE', 'IT')
GROUP BY
  1,
  2,
  3 
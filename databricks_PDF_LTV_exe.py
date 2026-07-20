# ====================================================================
# Packages & Setup
# ====================================================================
import pandas as pd
import numpy as np
from scipy.optimize import curve_fit

# 1. Mathematical model definition (Power Law)
def power_law(t, alpha, beta):
    return alpha * (t ** beta)

# ====================================================================
# 2. Data Extraction and Preprocessing
# ====================================================================
# Executing your original SQL query directly into Pandas
spark_df = spark.sql("""
    SELECT                                           
        s.id AS subscription_id,                                        
        SUM(CASE WHEN t.transaction_type = 0 THEN 1 ELSE 0 END) - COALESCE((SUM(CASE WHEN t.transaction_type = 1 THEN 1 ELSE 0 END)), 0) AS tenure,                                      
        SUM(CASE WHEN t.transaction_type = 0 THEN t.amount ELSE 0 END) - COALESCE((SUM(CASE WHEN t.transaction_type = 1 THEN t.amount ELSE 0 END)), 0) AS user_revenue,                                      
        MIN(t.payment_date) AS initial_payment_date,                                            
        DATE_TRUNC('month', MIN(t.payment_date))::date AS cohort,                                
        MAX(t.payment_date) AS latest_payment_date,                                     
        CASE WHEN (s.unsubscribed_date IS NOT NULL OR s.subscription_status = 'Unsuscribed') THEN 'churned' ELSE 'active' END AS status,                                        
        p.amount,                                            
        p.amount_trial,                                          
        MAX(COALESCE(hua.ip_country_iso_code, c.ip_country)) AS ip_country                                          
    FROM (
            -- Transactions filter due to an error in the bronze.pdf.transactions table 
            SELECT * FROM (
                SELECT *,
                    ROW_NUMBER() OVER (PARTITION BY id ORDER BY payment_date DESC) as rn
                FROM bronze.pdf.transactions
            )
            WHERE rn = 1
    ) t                                          
    LEFT JOIN bronze.pdf.subscriptions s                                             
        ON t.subscription_id = s.id                                         
    JOIN bronze.pdf.invoices_sii is2                                             
        ON is2.transaction_id = t.id                                        
    LEFT JOIN bronze.pdf.products p2                                             
        ON p2.id = s.product_id                                         
    JOIN bronze.pdf.subscription_types st                                            
        ON st.id = s.subscription_type_id                                           
    LEFT JOIN bronze.pdf.prices p                                            
        ON p.id = st.price_id                                           
    LEFT JOIN bronze.pdf.http_user_agents hua                                            
        ON hua.id = t.user_agent_id                                         
    INNER JOIN bronze.pdf.customers c                                            
        ON c.id = s.customer_id_np                                          
        AND c.email NOT LIKE '%leadtech%'                                           
    WHERE                                            
        s.subscription_status != 'Registered'                                       
        AND s.created_at::date > '2024-01-01'                                           
        AND t.transaction_status = 1                                            
        AND s.id NOT IN ('25', '26', '27', '28') -- filter subscription test                             
    GROUP BY                                             
        s.id,                                           
        s.unsubscribed_date,                                             
        s.subscription_status,
        p.amount,                                            
        p.amount_trial                                                  
    HAVING                                           
        SUM(CASE WHEN t.transaction_type = 0 THEN 1 ELSE 0 END) - COALESCE((SUM(CASE WHEN t.transaction_type = 1 THEN 1 ELSE 0 END)), 0) > 0""")
df = spark_df.toPandas()
# Quick data cleaning
obs_end = pd.to_datetime('2026-07-05')
df['initial_payment_date'] = pd.to_datetime(df['initial_payment_date'])
df = df[(df['initial_payment_date'] <= obs_end) & (df['amount'] < 100) & (df['tenure'] >= 0)].copy()
df['account_age_days'] = (obs_end - df['initial_payment_date']).dt.days

# Segmenting high-volume target countries
target_countries = ['US', 'AU', 'FR', 'GB', 'CA']
df = df[df['ip_country'].isin(target_countries)].copy()

# Time milestones for the new pricing tiers
date_39 = pd.to_datetime('2026-01-07')
date_49 = pd.to_datetime('2026-03-25')

# Split strategic datasets
df_baseline = df[(df['initial_payment_date'] < date_39)].copy()
df_new_39 = df[(df['initial_payment_date'] >= date_39) & (df['amount'] == 39.95)].copy()
df_new_49 = df[(df['initial_payment_date'] >= date_49) & (df['amount'] == 49.95)].copy()

# ====================================================================
# 3. Historical Baseline Curves Training (Price $29.95)
# ====================================================================
max_months = 36
base_curves = {}

for country in target_countries:
    df_c = df_baseline[df_baseline['ip_country'] == country]
    real_points = []
    
    for r in range(1, 13):
        min_days = (7 + (r-1)*28) + 8 if r > 1 else 7 + 8
        eligible = df_c[df_c['account_age_days'] >= min_days]
        if len(eligible) >= 50:
            real_points.append(len(eligible[eligible['tenure'] >= (r + 1)]) / len(eligible))
        else:
            break
            
    if len(real_points) >= 3:
        try:
            popt, _ = curve_fit(power_law, np.arange(1, len(real_points)+1), real_points, p0=[0.5, -0.5])
            base_curves[country] = [real_points[m-1] if m <= len(real_points) else power_law(m, *popt) for m in range(1, max_months+1)]
        except Exception:
            continue

# ====================================================================
# 4. Processing & Generating the Simplified Output Table with N
# ====================================================================
output_rows = []

for country in target_countries:
    if country not in base_curves:
        continue
        
    base_curve = np.array(base_curves[country])
    
    # 4.1 Historical Scenario ($29.95)
    # Get the sample size of historical users who had a chance to reach at least Month 1
    df_c_baseline = df_baseline[df_baseline['ip_country'] == country]
    eligible_baseline = df_c_baseline[df_c_baseline['account_age_days'] >= 15]
    
    output_rows.append({
        'Country': country,
        'Price': 29.95,
        'LT_36m': np.round(np.sum(base_curve), 2),
        'N': len(eligible_baseline)
    })
    
    # 4.2 New Price Scenario $39.95 (Stitching)
    df_c_39 = df_new_39[df_new_39['ip_country'] == country]
    eligible_r1_39 = df_c_39[df_c_39['account_age_days'] >= 15]
    
    if len(eligible_r1_39) >= 20:
        r1_real = len(eligible_r1_39[eligible_r1_39['tenure'] >= 2]) / len(eligible_r1_39)
        curve_39 = [r1_real]
        for i in range(1, max_months):
            marginal_rate = base_curve[i] / base_curve[i-1]
            curve_39.append(curve_39[-1] * marginal_rate)
        
        output_rows.append({
            'Country': country,
            'Price': 39.95,
            'LT_36m': np.round(np.sum(curve_39), 2),
            'N': len(eligible_r1_39)
        })
        
    # 4.3 New Price Scenario $49.95 (Stitching)
    df_c_49 = df_new_49[df_new_49['ip_country'] == country]
    eligible_r1_49 = df_c_49[df_c_49['account_age_days'] >= 15]
    
    if len(eligible_r1_49) >= 20:
        r1_real = len(eligible_r1_49[eligible_r1_49['tenure'] >= 2]) / len(eligible_r1_49)
        curve_49 = [r1_real]
        for i in range(1, max_months):
            marginal_rate = base_curve[i] / base_curve[i-1]
            curve_49.append(curve_49[-1] * marginal_rate)
            
        output_rows.append({
            'Country': country,
            'Price': 49.95,
            'LT_36m': np.round(np.sum(curve_49), 2),
            'N': len(eligible_r1_49)
        })

# Convert final list to a standard Pandas DataFrame
df_output = pd.DataFrame(output_rows)

# Force the LT_36m column to consistently display exactly two decimal places
df_output['LT_36m'] = df_output['LT_36m'].map('{:.2f}'.format)

# Ensure columns are in a logical order
df_output = df_output[['Country', 'Price', 'LT_36m', 'N']]

# Render results directly into the Databricks UI
display(df_output)

# ====================================================================
# 5. Output sql format to include as a CTE
# ====================================================================
sql_rows = []
for _, row in df_output.iterrows():
    # Format each row as: SELECT 'US' AS Country, 39.95 AS Price, 3.46 AS LT_36m
    sql_rows.append(f"SELECT '{row['Country']}' AS Country, {row['Price']} AS Price, {row['LT_36m']} AS LT_36m")

# Join all rows together with a UNION ALL
inline_sql_table = "\n    UNION ALL\n    ".join(sql_rows)
print(f"WITH ltv_projections AS (\n    {inline_sql_table}\n)")


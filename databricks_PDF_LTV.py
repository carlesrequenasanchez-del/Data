
# ====================================================================
# Packages
# ====================================================================

# pip install arviz pymc bambi pandas
# dbutils.library.restartPython()
##import arviz as az
import pandas as pd
import numpy as np
##import pymc as pm
##import pytensor.tensor as pt
import matplotlib.pyplot as plt
##from sklearn.metrics import roc_auc_score
##from scipy.special import expit
##import seaborn as sns
from scipy.optimize import curve_fit

# ====================================================================
# Query
# ====================================================================

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
print(df.head())

#Math Model
def power_law(t, alpha, beta):
    return alpha * (t ** beta)

# ====================================================================
# Data Preprocessing
# ====================================================================
#No annual plan
#Churned normalized
#Tiers definition
#Country filter (more than 50 users)

obs_end = pd.to_datetime('2026-07-01') 
df['initial_payment_date'] = pd.to_datetime(df['initial_payment_date'])
df = df[df['initial_payment_date'] <= obs_end].copy()
df = df[df['amount'] < 100].copy() # No anual plan

df = df[df['tenure'] >= 0].copy()
df['churned'] = np.where(df['status'] == 'churned', 1, 0)

tier_map = {
    'US': 'T1_CORE_ENG', 'CA': 'T1_CORE_ENG', 'GB': 'T1_CORE_ENG', 'AU': 'T1_CORE_ENG', 'NZ': 'T1_CORE_ENG',
    'DE': 'T2_WEST_EU', 'FR': 'T2_WEST_EU', 'NL': 'T2_WEST_EU', 'BE': 'T2_WEST_EU', 'AT': 'T2_WEST_EU', 'CH': 'T2_WEST_EU', 'DK': 'T2_WEST_EU', 'SE': 'T2_WEST_EU', 'NO': 'T2_WEST_EU', 'PL': 'T2_WEST_EU',
    'ES': 'T3_MED_LATAM_PREM', 'IT': 'T3_MED_LATAM_PREM', 'MX': 'T3_MED_LATAM_PREM', 'CL': 'T3_MED_LATAM_PREM', 'BR': 'T3_MED_LATAM_PREM',
    'CO': 'T4_EMERGING', 'AR': 'T4_EMERGING', 'PE': 'T4_EMERGING', 'EC': 'T4_EMERGING', 'UY': 'T4_EMERGING', 'VE': 'T4_EMERGING', 'TR': 'T4_EMERGING', 'IN': 'T4_EMERGING', 'PH': 'T4_EMERGING',
    'JP': 'T5_SPECIAL', 'KR': 'T5_SPECIAL', 'SG': 'T5_SPECIAL', 'SA': 'T5_SPECIAL'
}

df['account_age_days'] = (obs_end - df['initial_payment_date']).dt.days
df['tier'] = df['ip_country'].map(tier_map)
country_counts = df['ip_country'].value_counts()
valid_countries = country_counts[country_counts >= 50].index.tolist()

df= df[
    (df['tier'].notna()) &             
    (df['ip_country'].isin(valid_countries)) #Enought volume
].copy()

# ====================================================================
# Descriptive Statistics
# ====================================================================
#Volume
print(df.shape[0])  #146602

print(df['ip_country'].value_counts().head(5))

print(df['amount'].value_counts().head(3))

print(df.groupby('amount').agg(
    Users=('subscription_id', 'count'),
    Tenure_avg=('tenure', 'mean'),
    Tenure_Max=('tenure', 'max'),
).sort_values('Users', ascending=False).head(3))

# Minimum days for a 'mature' user (8 days first renewal + 37 days second renewal)
DAYS_FOR_R1 = 8
DAYS_FOR_R2 = 37

def calcular_cr(grupo):
    total = len(grupo)
    grupo_r1 = grupo[grupo['account_age_days'] >= DAYS_FOR_R1]
    total_r1_elegibles = len(grupo_r1)
    rec_1 = len(grupo_r1[grupo_r1['tenure'] >= 2])
    cr_1 = (rec_1 / total_r1_elegibles * 100) if total_r1_elegibles > 0 else np.nan
    grupo_r2 = grupo[grupo['account_age_days'] >= DAYS_FOR_R2]
    total_r2_elegibles = len(grupo_r2)
    rec_2 = len(grupo_r2[grupo_r2['tenure'] >= 3])
    cr_2 = (rec_2 / total_r2_elegibles * 100) if total_r2_elegibles > 0 else np.nan

    return pd.Series({
        'N': total,
        'Elegibles_R1': total_r1_elegibles,
        'CR_Sale_to_R1 (%)': cr_1,
        'Elegibles_R2': total_r2_elegibles,
        'CR_Sale_to_R2 (%)': cr_2
    })

resumen_cr = df.groupby('amount').apply(calcular_cr).reset_index()
print(resumen_cr)
resumen_cr['CR_Sale_to_R1 (%)'] = resumen_cr['CR_Sale_to_R1 (%)'].round(2)
resumen_cr['CR_Sale_to_R2 (%)'] = resumen_cr['CR_Sale_to_R2 (%)'].round(2)

##Empirical Curve
target_countries = ['US', 'AU', 'FR', 'GB', 'CA']
df = df[df['ip_country'].isin(target_countries)]

max_r = 4
results = []

for country in target_countries:
    for price in [29.95, 39.95, 49.95]:
        row = {'Country': country, 'Price': price}

        row['Trial'] = "100.0%"

        for r in range(1, max_r):
            min_days = 8 if r == 1 else 7 + (r-1)*28 + 2
            eligible = df[(df['ip_country'] == country) & (df['amount'] == price) & (df['account_age_days'] >= min_days)]
            if len(eligible) >= 20:
                survived = len(eligible[eligible['tenure'] >= r + 1])
                rate = survived / len(eligible) * 100
                row[f'R{r} (%)'] = f"{rate:.1f}%"
                row[f'R{r} (n)'] = len(eligible)
            else:
                row[f'R{r} (%)'] = "N/A"
                row[f'R{r} (n)'] = "<20"

        results.append(row)

res_df = pd.DataFrame(results)
print(res_df.to_string(index=False))

precios = [29.95, 39.95, 49.95]
max_r_to_check = 12
fig, axes = plt.subplots(nrows=2, ncols=3, figsize=(18, 10))
axes = axes.flatten()
colores = {29.95: '#1f77b4', 39.95: '#ff7f0e', 49.95: '#2ca02c'}
marcadores = {29.95: 'o', 39.95: 's', 49.95: '^'}

for idx, country in enumerate(target_countries):
    ax = axes[idx]
    df_country = df[df['ip_country'] == country]

    for price in precios:
        rates = [1.0]

        for r in range(1, max_r_to_check + 1):
            min_days = 8 if r == 1 else 7 + (r-1)*28 + 2
            eligible = df_country[(df_country['amount'] == price) & (df_country['account_age_days'] >= min_days)]
            if len(eligible) < 20:
                break

            survived = len(eligible[eligible['tenure'] >= r + 1])
            rate = survived / len(eligible)
            rates.append(rate)

        if len(rates) > 1:
            x = range(1, len(rates) + 1)
            y = [rate * 100 for rate in rates]
            ax.plot(x, y, marker=marcadores[price], color=colores[price], linewidth=2, markersize=6, label=f'${price}')

            for i, txt in enumerate(y):
                if i in [1, 2]:
                    ax.annotate(f'{txt:.1f}%', (x[i], y[i]), textcoords="offset points", xytext=(0,8), ha='center', fontsize=8, color=colores[price])

    ax.set_title(f'Retention in {country}', fontsize=12, fontweight='bold')
    ax.set_xlabel('Cycles (1=Trial)')
    ax.set_ylabel('Retention (%)')
    ax.set_ylim(0, 105)
    ax.set_xticks(range(1, 14))
    ax.grid(True, linestyle='--', alpha=0.5)
    ax.legend(title='Price', fontsize=9)

fig.delaxes(axes[5])

# ====================================================================
# Model
# ====================================================================
# ====================================================================
# Helper Functions for Modeling
# ====================================================================
def get_survival_curves_by_country(df_input, countries, max_months=36):
    survival_curves = {}
    for country in countries:
        df_c = df_input[df_input['ip_country'] == country]
        real_points = []
        for r in range(1, 13):
            min_days = (7 + (r-1)*28) + 8 if r > 1 else 7 + 8
            eligible = df_c[df_c['account_age_days'] >= min_days]
            if len(eligible) >= 50:
                real_points.append(len(eligible[eligible['tenure'] >= (r + 1)]) / len(eligible))
            else:
                break

        if len(real_points) < 3:
            continue

        try:
            popt, _ = curve_fit(power_law, np.arange(1, len(real_points)+1), real_points, p0=[0.5, -0.5])
            full_curve = [real_points[m-1] if m <= len(real_points) else power_law(m, *popt) for m in range(1, max_months+1)]
            survival_curves[country] = full_curve
        except Exception:
            continue

    return pd.DataFrame(survival_curves, index=range(1, max_months+1))

def prepare_historico_rows(df_base_curves, df_baseline, countries):
    rows = []
    for country in countries:
        if country in df_base_curves.columns:
            sample = len(df_baseline[df_baseline['ip_country'] == country])
            curve = df_base_curves[country].values
            lt_acumulado = np.cumsum(curve)

            row = {'Country': country, 'Scenario': 'Historico_Antiguo', 'Sample_Size': sample, 'LT_36m': sum(curve)}
            for i, v in enumerate(lt_acumulado):
                row[f'Month_{i+1}'] = v
            rows.append(row)
    return pd.DataFrame(rows)

def generate_full_lt_report_v3(df_new, price_label, df_base_curves, max_rebills=36):
    report_data = []
    DAYS_FOR_R1 = 7 + 8
    DAYS_FOR_R2 = 35 + 8

    for country in df_base_curves.columns:
        df_c = df_new[df_new['ip_country'] == country]
        eligible_r1 = df_c[df_c['account_age_days'] >= DAYS_FOR_R1]

        if len(eligible_r1) < 20:
            continue

        r1_real = len(eligible_r1[eligible_r1['tenure'] >= 2]) / len(eligible_r1)
        eligible_r2 = df_c[df_c['account_age_days'] >= DAYS_FOR_R2]

        base_curve = df_base_curves[country].values
        stitched_curve = [r1_real]

        if len(eligible_r2) >= 20:
            r2_real = len(eligible_r2[eligible_r2['tenure'] >= 3]) / len(eligible_r2)
            stitched_curve.append(r2_real)
            start_proj = 2
        else:
            start_proj = 1

        for i in range(start_proj, max_rebills):
            marginal_rate = base_curve[i] / base_curve[i-1]
            stitched_curve.append(stitched_curve[-1] * marginal_rate)

        lt_acumulado = np.cumsum(stitched_curve)

        row = {'Country': country, 'Scenario': f'Precio_{price_label}', 'Sample_Size': len(eligible_r1), 'LT_36m': sum(stitched_curve)}
        for m_idx, val in enumerate(lt_acumulado):
            row[f'Month_{m_idx+1}'] = val

        report_data.append(row)

    return pd.DataFrame(report_data)

# ====================================================================
# Execution Pipeline
# ====================================================================
date_39 = pd.to_datetime('2026-01-07')
date_49 = pd.to_datetime('2026-03-25')

df_baseline = df[(df['initial_payment_date'] < date_39) & (df['account_age_days'] >= 180)].copy()
df_new_39 = df[(df['initial_payment_date'] >= date_39) & (df['amount'] == 39.95)].copy()
df_new_49 = df[(df['initial_payment_date'] >= date_49) & (df['amount'] == 49.95)].copy()

# Sacamos la lista de los países con más volumen (Corregida Indentación)
top_countries = df_baseline['ip_country'].value_counts()[df_baseline['ip_country'].value_counts() >= 500].index.tolist()

print("1. Calculando curva base histórica...")
df_survival_curves = get_survival_curves_by_country(df_baseline, top_countries)
df_hist = prepare_historico_rows(df_survival_curves, df_baseline, top_countries)

print("2. Calculando reporte para $39.95...")
report_39 = generate_full_lt_report_v3(df_new_39, '39.95', df_survival_curves)

print("3. Calculando reporte para $49.95...")
report_49 = generate_full_lt_report_v3(df_new_49, '49.95', df_survival_curves)

print("4. Uniendo los datos...")
final_sheets_upload = pd.concat([df_hist, report_39, report_49], ignore_index=True)

print("\n✅ ¡Misión Cumplida! Aquí tienes un resumen:")
print(final_sheets_upload[['Country', 'Scenario', 'Sample_Size', 'LT_36m', 'Month_1']].head(10))


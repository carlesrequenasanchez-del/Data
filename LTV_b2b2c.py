import pandas as pd
import numpy as np
import pymc as pm
import pytensor.tensor as pt
import arviz as az
import matplotlib.pyplot as plt
from sklearn.metrics import roc_auc_score
from scipy.special import expit
import seaborn as sns

file_path = "/content/drive/MyDrive/Colab Notebooks/LTV_2y.csv"
df = pd.read_csv(file_path)

#data preprocesing
obs_end = pd.to_datetime('2026-02-28')
df['initial_payment_date'] = pd.to_datetime(df['initial_payment_date'])
df = df[df['initial_payment_date'] <= obs_end].copy()
df['tenure'] = df['tenure'] - 1
df = df[df['tenure'] >= 0].copy()
df['churned'] = np.where(df['status'] == 'churned', 1, 0)

#descriptive
descriptiva_kw = df.groupby('user_segment').agg(
    users=('subscription_id', 'count'),
    avg_churn_rate=('churned', 'mean')
).reset_index()
print(descriptiva_kw)

#retention curve

km_data = []
for kw in df['user_segment'].unique():
    sub = df[df['user_segment'] == kw]
    for t in range(int(sub['age'].max()) + 1):
        n_risk = len(sub[(sub['age'] >= t) & (sub['tenure'] >= t)])
        n_event = len(sub[(sub['tenure'] == t) & (sub['churned'] == 1)])
        if n_risk > 0:
            km_data.append({'user_segment': kw, 'month': t, 'n_risk': n_risk, 'n_event': n_event})
df_km = pd.DataFrame(km_data)

df_km['p_survival'] = 1 - (df_km['n_event'] / df_km['n_risk'])
df_km['survival_rate'] = df_km.groupby('user_segment')['p_survival'].cumprod()
plt.figure(figsize=(10, 6))
sns.lineplot(data=df_km[df_km['month'] <= 12], x='month', y='survival_rate', hue='user_segment', marker='o')
plt.title('Retention curve - US Market', fontsize=14)
plt.ylabel('% Active users')
plt.xlabel('Months (month 0 = initial_purchase)')
plt.grid(True, alpha=0.3)
plt.ylim(0, 1.05)
plt.legend(title='User segment')
plt.show()
#lifetime 
lt_simple = df_km.groupby('user_segment')['survival_rate'].sum().reset_index()
lt_simple.columns = ['user_segment', 'LT Empírico (Meses)']
print("\n--- ESTIMACIÓN DE LIFETIME (Área bajo la curva observada) ---")
print(lt_simple)

#MODEL
df_us = df.copy()
df_us['kw_idx'] = pd.Categorical(df_us['user_segment']).codes
user_segment = pd.Categorical(df_us['user_segment']).categories.tolist()
aggregated_data = []

for k_idx_val, k_name in enumerate(user_segment):
    sub = df_us[df_us['kw_idx'] == k_idx_val]
    max_t = sub['tenure'].max()
    for t in range(int(max_t) + 1):
        n_risk = len(sub[sub['tenure'] >= t])      # Gente viva al inicio del mes
        n_event = len(sub[(sub['tenure'] == t) & (sub['churned'] == 1)]) # Gente que se fue

        if n_risk > 0:
            aggregated_data.append({
                'kw_idx': k_idx_val,
                'user_segment': k_name,
                'month': t,
                'n_risk': n_risk,
                'n_event': n_event
            })
df_bayes = pd.DataFrame(aggregated_data)
print(df_bayes.head())

#start model
import pymc as pm

k_idx_model = df_bayes['kw_idx'].values
m_idx_model = df_bayes['month'].values
n_risk_model = df_bayes['n_risk'].values
n_event_model = df_bayes['n_event'].values
max_horizon = m_idx_model.max()

with pm.Model() as final_model_kw:
    # A. Intercepto por keyword (como el offset de países)
    alpha_kw = pm.Normal('alpha_kw', mu=0, sigma=1.5, shape=len(user_segment))

    # B. Componente Temporal (Random Walk) con el mismo sigma que usaste
    beta_time = pm.GaussianRandomWalk('beta_time', sigma=0.2, shape=int(max_horizon + 1))

    # C. Probabilidad
    logit_p = alpha_kw[k_idx_model] + beta_time[m_idx_model]
    p_churn = pm.math.invlogit(logit_p)

    # D. Likelihood
    obs = pm.Binomial('obs', n=n_risk_model, p=p_churn, observed=n_event_model)

    # E. Sampling
    trace = pm.sample(draws=1000, tune=1000, chains=2, target_accept=0.95)

#start modeling
from scipy.special import expit
# 1. Extraemos las medias posteriores del trace
post_alpha = trace.posterior['alpha_kw'].mean(dim=['chain', 'draw']).values
post_beta = trace.posterior['beta_time'].mean(dim=['chain', 'draw']).values

results = []

# Definimos los tramos exactos que queremos calcular
meses_objetivo = [1, 3, 6, 12, 24, 36]

for i, user_segment_name in enumerate(user_segment):
    # Reconstruimos la curva de logits
    logits = post_alpha[i] + post_beta
    p_churn_curve = expit(logits)
    survival_curve = np.cumprod(1 - p_churn_curve)

    current_len = len(survival_curve)

    # Diccionario temporal para guardar los cálculos de esta keyword
    lt_dict = {}

    # 2. Calculamos áreas bajo la curva de forma dinámica
    for m in meses_objetivo:
        if current_len >= m:
            # Si tenemos suficientes datos o m=0, sumamos hasta el mes 'm'
            # Nota: Si m=0, survival_curve[:0].sum() da automáticamente 0.0
            lt_dict[m] = survival_curve[:m].sum()
        else:
            # Extrapolamos plano si el horizonte pedido es mayor que nuestra curva
            tail_value = survival_curve[-1]
            missing_months = m - current_len
            lt_dict[m] = survival_curve.sum() + (tail_value * missing_months)

    # Conteo de usuarios reales por keyword
    n_usuarios = len(df_us[df_us['kw_idx'] == i])

    # 3. Guardamos los resultados
    results.append({
        'user_segment': user_segment_name,
        'Nº Usuarios': n_usuarios,
        'LT 1 Meses': round(lt_dict[1], 2),
        'LT 3 Meses': round(lt_dict[3], 2),
        'LT 6 Meses': round(lt_dict[6], 2),
        'LT 12 Meses': round(lt_dict[12], 2),
        'LT 24 Meses': round(lt_dict[24], 2),
        'LT 36 Meses': round(lt_dict[36], 2)
    })

# 4. Mostramos la tabla ordenada
df_results = pd.DataFrame(results).sort_values('LT 12 Meses', ascending=False)
print("\n--- RESULTADOS FINALES (US - KEYWORDS) ---")
print(df_results.to_string(index=False))


#Cumulative curve ELTV
# 1. Business Configuration
arpu = 39.95
horizonte = 35 # Months to project

# Assuming 'keywords', 'post_alpha', and 'post_beta' are already defined in your environment
# Dummy example to avoid errors if copy-pasted:
# keywords = ['free', 'other']

# 2. Curve reconstruction from the Bayesian model (trace)
ltv_plot_data = []

for i, user_segment_name in enumerate(user_segment):
    # Reconstruct churn probability and survival
    logits = post_alpha[i] + post_beta
    p_churn_curve = expit(logits)
    survival_curve = np.cumprod(1 - p_churn_curve)

    # Extrapolate if the observed curve is shorter than 35 months
    current_len = len(survival_curve)
    if current_len < horizonte:
        tail_value = survival_curve[-1]
        # Note: Padding with tail_value assumes 0% churn from this point forward.
        padding = np.full(horizonte - current_len, tail_value)
        survival_curve_full = np.concatenate([survival_curve, padding])
    else:
        survival_curve_full = survival_curve[:horizonte]

    # Calculate Cumulative Lifetime (progressive sum)
    cum_lt = np.cumsum(survival_curve_full)

    # Convert to Dollars (LTV)
    cum_ltv = cum_lt * arpu

    # Save month-by-month data for the plot
    for month in range(horizonte):
        ltv_plot_data.append({
            'user_segment': user_segment_name,
            'Month': month + 1,        # Months will range from 1 to 35
            'LTV ($)': cum_ltv[month]
        })

df_plot = pd.DataFrame(ltv_plot_data)

# 3. Visualization for Marketing
plt.figure(figsize=(12, 7))

# Define corporate colors (ensure keys match exactly with your 'keywords' list)
colores = {'B2B': '#1f77b4', 'B2C': '#ff7f0e'}

# Main plot
sns.lineplot(data=df_plot, x='Month', y='LTV ($)', hue='user_segment',
             palette=colores, linewidth=3)

# Plot styling
plt.title('Cumulative LTV: "b2b" vs "b2c"', fontsize=16, fontweight='bold')
plt.xlabel('Months', fontsize=12)
plt.ylabel('Cumulative Value ($)', fontsize=12)
plt.xticks(np.arange(0, 36, 3)) # X-axis ticks every 3 months
plt.grid(True, alpha=0.3)
plt.legend(title='Segment', fontsize=11, loc='lower right')

# Extend X limit slightly so the final text doesn't get cut off
plt.xlim(0, horizonte + 3)

for kw in user_segment:
    # Filter by month 35 and the specific keyword
    final_val = df_plot[(df_plot['user_segment'] == kw) & (df_plot['Month'] == 35)]['LTV ($)'].values[0]

    # Place the text right at the end of the line
    plt.text(35.2, final_val, f'${final_val:.2f}', verticalalignment='center',
             fontsize=12, fontweight='bold', color=colores.get(kw, 'black'))

plt.tight_layout()
plt.show()

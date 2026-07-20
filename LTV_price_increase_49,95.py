##Packages
import arviz as az
import pandas as pd
import numpy as np
import pymc as pm
import pytensor.tensor as pt
import matplotlib.pyplot as plt
from sklearn.metrics import roc_auc_score
from scipy.special import expit
import seaborn as sns

#Import File
file_path = "/content/_SELECT_s_id_AS_subscription_id_SUM_CASE_WHEN_t_transaction_type_202605061303.csv"
df = pd.read_csv(file_path)

##Data preprocessing##
#No annual plan
#Churned normalized
#Tiers definition
#Country filter (more than 50 users)
obs_end = pd.to_datetime('2026-04-20')
df['initial_payment_date'] = pd.to_datetime(df['initial_payment_date'])
df = df[df['initial_payment_date'] <= obs_end].copy()
df = df[df['amount'] < 100].copy() # No anual plan
df['tenure'] = df['tenure'] - 1
df = df[df['tenure'] >= 0].copy()
df['churned'] = np.where(df['status'] == 'churned', 1, 0)
tier_map = {
    'US': 'T1_CORE_ENG', 'CA': 'T1_CORE_ENG', 'GB': 'T1_CORE_ENG', 'AU': 'T1_CORE_ENG', 'NZ': 'T1_CORE_ENG',
    'DE': 'T2_WEST_EU', 'FR': 'T2_WEST_EU', 'NL': 'T2_WEST_EU', 'BE': 'T2_WEST_EU', 'AT': 'T2_WEST_EU', 'CH': 'T2_WEST_EU', 'DK': 'T2_WEST_EU', 'SE': 'T2_WEST_EU', 'NO': 'T2_WEST_EU', 'PL': 'T2_WEST_EU',
    'ES': 'T3_MED_LATAM_PREM', 'IT': 'T3_MED_LATAM_PREM', 'MX': 'T3_MED_LATAM_PREM', 'CL': 'T3_MED_LATAM_PREM', 'BR': 'T3_MED_LATAM_PREM',
    'CO': 'T4_EMERGING', 'AR': 'T4_EMERGING', 'PE': 'T4_EMERGING', 'EC': 'T4_EMERGING', 'UY': 'T4_EMERGING', 'VE': 'T4_EMERGING', 'TR': 'T4_EMERGING', 'IN': 'T4_EMERGING', 'PH': 'T4_EMERGING',
    'JP': 'T5_SPECIAL', 'KR': 'T5_SPECIAL', 'SG': 'T5_SPECIAL', 'SA': 'T5_SPECIAL'
}
df['tier'] = df['ip_country'].map(tier_map)
country_counts = df['ip_country'].value_counts()
valid_countries = country_counts[country_counts >= 50].index.tolist()
df= df[
    (df['tier'].notna()) &              # Inside the tier
    (df['ip_country'].isin(valid_countries)) # Enought volume
].copy()
##############################
##Descriptive
#volume
print(df.shape[0])
print(df['ip_country'].value_counts().head(5))
print(df['amount'].value_counts().head(3))
print(df.groupby('amount').agg(
    Users=('subscription_id', 'count'),
    Tenure_avg=('tenure', 'mean'),
    Tenure_Max=('tenure', 'max'),
).sort_values('Users', ascending=False).head(3))
#CR between initials and rebills
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

#Agrupar por cohorte y precio
resumen_cr = df.groupby('amount').apply(calcular_cr).reset_index()
print(resumen_cr)
#Limpieza visual y Exportación
resumen_cr['CR_Sale_to_R1 (%)'] = resumen_cr['CR_Sale_to_R1 (%)'].round(2)
resumen_cr['CR_Sale_to_R2 (%)'] = resumen_cr['CR_Sale_to_R2 (%)'].round(2)

#######
#Empirical curve and table
#Empirical Table
# Filtramos precios raros/anuales
target_countries = ['US', 'AU', 'FR', 'GB', 'CA']
df = df[df['ip_country'].isin(target_countries)]

max_r = 4 
results = []

for country in target_countries:
    for price in [29.95, 39.95, 49.95]:
        row = {'Country': country, 'Price': price}
        
        row['Trial'] = "100.0%"
        
        for r in range(1, max_r):
            # Lógica de madurez: 8 días para R1, luego +28 días por ciclo (+2 de gracia)
            min_days = 8 if r == 1 else 7 + (r-1)*28 + 2
            
            eligible = df[(df['ip_country'] == country) & (df['amount'] == price) & (df['account_age_days'] >= min_days)]
            
            # Exigimos base estadística de 20 usuarios mínimo
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

##Empirical Curve
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
        rates = [1.0] # Trial = Cicle 1
        
        for r in range(1, max_r_to_check + 1):
            min_days = 8 if r == 1 else 7 + (r-1)*28 + 2
            eligible = df_country[(df_country['amount'] == price) & (df_country['account_age_days'] >= min_days)]
            if len(eligible) < 20: #minimum 20 users
                break
                
            survived = len(eligible[eligible['tenure'] >= r + 1])
            rate = survived / len(eligible)
            rates.append(rate)
            
        if len(rates) > 1:
            x = range(1, len(rates) + 1)
            y = [rate * 100 for rate in rates]
            ax.plot(x, y, marker=marcadores[price], color=colores[price], linewidth=2, markersize=6, label=f'${price}')
            

            for i, txt in enumerate(y):
                if i in [1, 2]: # Just R1 and R2
                    ax.annotate(f'{txt:.1f}%', (x[i], y[i]), textcoords="offset points", xytext=(0,8), ha='center', fontsize=8, color=colores[price])

    ax.set_title(f'Retention in {country}', fontsize=12, fontweight='bold')
    ax.set_xlabel('Cycles (1=Trial)')
    ax.set_ylabel('Retention (%)')
    ax.set_ylim(0, 105)
    ax.set_xticks(range(1, 14))
    ax.grid(True, linestyle='--', alpha=0.5)
    ax.legend(title='Price', fontsize=9)

fig.delaxes(axes[5]) #Just omit the last graph

#Power LOW
#Survival model
def power_law(x, a, b):
    return a * (x ** b)
max_months = 36 # 36 cycles projection
ciclos = np.arange(1, max_months + 1)
curvas = {}

df_base = df[df['amount'] == 29.95]
real_points_base = [1.0]
for r in range(1, 13):
    min_days = 8 if r == 1 else 7 + (r-1)*28 + 2
    eligible = df_base[df_base['account_age_days'] >= min_days]
    if len(eligible) >= 100:
        real_points_base.append(len(eligible[eligible['tenure'] >= r + 1]) / len(eligible))
    else: break
#adjust with real data 
x_data = np.arange(1, len(real_points_base) + 1)
popt, _ = curve_fit(power_law, x_data, real_points_base, p0=[1.0, -0.5])
curvas[29.95] = power_law(ciclos, *popt)

#Slicjing with new prices
for price in [39.95, 49.95]:
    df_price = df[df['amount'] == price]
    real_points = [1.0]
    for r in range(1, 4):
        min_days = 8 if r == 1 else 7 + (r-1)*28 + 2
        eligible = df_price[df_price['account_age_days'] >= min_days]
        if len(eligible) >= 50:
            real_points.append(len(eligible[eligible['tenure'] >= r + 1]) / len(eligible))
        else: break
            
    stitched = list(real_points)
    for i in range(len(real_points) + 1, max_months + 1):
        marginal_rate = curvas[29.95][i-1] / curvas[29.95][i-2]
        stitched.append(stitched[-1] * marginal_rate)
    curvas[price] = np.array(stitched)

    #Create the table
    # Crear tabla detallada
tabla_detallada = pd.DataFrame({'Cycles': ciclos})

for price in [29.95, 39.95, 49.95]:
    # Retention 
    tabla_detallada[f'Retención ${price} (%)'] = (curvas[price] * 100).round(2)
    # LT Acumulate
    tabla_detallada[f'LT Acum. ${price}'] = np.cumsum(curvas[price]).round(4)

print(tabla_detallada.to_string(index=False))
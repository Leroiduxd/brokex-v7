---

## 0) Vision globale

Le contrat est un **grand livre comptable** (“virtual accounting”) qui simule un système de broker + vault LP :

* **Traders** : ont un solde interne en “USD 6 décimales” (type USDC), et ouvrent des trades.
* **LP Vault** : apporte la liquidité (Book B).

  * Si le trader gagne → le vault perd.
  * Si le trader perd → le vault gagne.
* **LP shares** : ce ne sont pas des ERC20. Ce sont des **parts virtuelles** (en 18 décimales) représentant la propriété du vault.
* **Epochs** : le prix de la part (LP token price) est “snapshotté” à chaque fin d’epoch. Les dépôts LP sont “lazy” (pas de distribution de shares utilisateur en storage, on calcule à la volée).
* **Retraits LP** : système FIFO par **buckets** d’epoch, combiné à des **payout tranches** qui “brûlent” des shares quand la trésorerie est disponible.
* **Sécurité anti-retraits infinis** : on ajoute une réserve obligatoire `minLpFreeReserve6` qui empêche l’ouverture de nouveaux trades si elle met en danger la capacité à honorer la file de retraits (au niveau funding/burn des shares).
* **Dust** : si le vault tombe dans un état “poussière” (< 5$), on hard reset et on envoie la poussière à `owner`.

---

## 1) Unités et conventions

### 1.1 Deux systèmes de décimales

1. **USD virtuel** (style USDC) : `6` décimales

* Variables suffixées `...6` (ex: `lpFreeCapital`, `freeBalance`).
* Exemple : `10_000_000` = 10.000000 USD

2. **Shares / prix** : `18` décimales (WAD)

* Variables suffixées `...18` (ex: `totalShares`, `sharesRequested18`).
* Prix `lpTokenPrice[epoch]` est en WAD : 1.0 = `1e18`.

### 1.2 Conversions

* `USDC_TO_WAD = 1e12`
* `_toWadFrom6(amount6) = amount6 * 1e12`
* `_to6FromWad(amount18) = amount18 / 1e12`

Idée : on calcule en 18 décimales pour la précision, puis on redescend en 6.

---

## 2) Rôles et sécurité

### 2.1 Owner

* `owner` a le contrôle de certaines actions (au minimum le premier `rollEpoch`).
* Il reçoit une partie des commissions.
* Il reçoit les poussières lors du reset dust.

### 2.2 Ouverture pour un autre trader (important)

Les fonctions `createOrder` et `createPosition` prennent une adresse `trader` en argument.
**Mais** on garde une garde :

* `_requireAuth(trader)` impose : `msg.sender == trader` **ou** `msg.sender == owner`.

Donc :

* Soit le trader ouvre lui-même
* Soit l’owner peut agir pour lui (cas d’executor/meta-tx plus tard, etc.)

---

## 3) Comptabilité Trader

### 3.1 Soldes traders

* `freeBalance[addr]` : argent libre (6 décimales)
* `lockedBalance[addr]` : argent verrouillé dans un trade / ordre (6 décimales)

### 3.2 Dépôt / retrait trader

* `traderDeposit(amount6)` : ajoute au free
* `traderWithdraw(amount6)` : retire du free (virtuel)

### 3.3 Verrouillage interne

* `_lockTrader(trader, amount)` : free → locked
* `_unlockTrader(trader, amount)` : locked → free

Ces deux fonctions servent à simuler :

* marge + commission bloquées au moment de l’ouverture d’un ordre/position

---

## 4) Comptabilité LP Vault

### 4.1 Capital LP

* `lpFreeCapital` : capital disponible (6 décimales)
* `lpLockedCapital` : capital réservé par trades ouverts (6 décimales)

Le verrouillage LP représente le “max liability” (gain maximum théorique du trader), ce qui garantit la solvabilité.

### 4.2 Lock / unlock du vault

#### `_lpLock(amount6)`

Avant : vérifier seulement `lpFreeCapital >= amount6`
Maintenant : on impose un garde supplémentaire :

> `lpFreeCapital >= minLpFreeReserve6 + amount6`

Ce qui signifie :

* on doit conserver une partie du capital libre **réservée** aux retraits LP en attente (file non servie).
* l’ouverture d’un nouveau trade ne peut pas entamer cette réserve.

#### `_lpUnlock(amount6)`

* `lpLockedCapital -= amount6`
* `lpFreeCapital += amount6`

---

## 5) Trades (Book B)

### 5.1 Structure

```
Trade {
  id
  owner (trader)
  margin6
  commission6
  lpLock6
  state
}
```

### 5.2 Create Order vs Create Position

1. **createOrder** : crée un ordre “Pending”

* lock trader : `margin + commission`
* pas de lock LP tout de suite

2. **executeOrder** : exécute l’ordre

* `_lpLock(lpLock)`
* `_collectCommission(trader, commission)`
* passe Open

3. **createPosition** : ouvre directement Open

* lock trader + lock LP + collecte commission directement

### 5.3 Commission (30% owner, 70% LP)

La commission est prélevée depuis `lockedBalance[trader]`, puis :

* 30% → `freeBalance[owner]`
* 70% → `lpFreeCapital`

C’est fait dans `_collectCommission(trader, commission6)`.

### 5.4 Closing / settlement (PnL)

`closeTrade(tradeId, pnl18)` :

* `pnl18` est en WAD (USD 18 décimales) et signé.
* On applique un cap :

  * profit max = `lpLock` (converti en 18)
  * loss max = `margin` (converti en 18)

Ensuite :

* `_lpUnlock(lpLock)` : libère le passif réservé.
* `_unlockAndSettle(trader, margin, actualPnl18)` : règle margin + pnl.

### 5.5 Fee sur profit trader : 1% au LP uniquement

Dans `_unlockAndSettle` :

* si pnl > 0 :

  * le vault doit payer un profit au trader
  * **on prend 1% de profit** qui reste dans LP (donc le trader reçoit 99% du profit)
  * Le vault débite seulement `profit - fee`
* si pnl < 0 :

  * pas de taxe supplémentaire
  * le trader perd jusqu’à son margin
  * la perte est ajoutée au `lpFreeCapital`

> Important : cette fee n’affecte pas l’owner, uniquement le LP (conformément à ce qu’on a acté).

---

## 6) Système LP Epoch (pricing + lazy shares)

### 6.1 Objectif

* Éviter de recalculer et stocker la part de chaque LP à chaque epoch (trop cher, boucles).
* On stocke :

  * les **dépôts par epoch**
  * le **prix de la part par epoch**
* Puis on calcule les shares d’un LP “à la volée” via des fonctions `view`.

### 6.2 Données stockées

* `currentEpoch`
* `epochStartTimestamp`
* `lpTokenPrice[epoch]` (WAD)
* `epochEquitySnapshot18[epoch]` (debug)
* `totalShares` (supply globale)

Dépôts :

* `pendingDepositOf[lp][epoch]` en 6 décimales
* `totalPendingDeposits[epoch]`
* `epochsWithDeposits[lp]` liste des epochs où l’lp a déposé (pour calculer sans scanner tous les epochs)

### 6.3 requestLpDeposit

Ajoute une demande de dépôt pour l’epoch actuelle :

* ajoute à `pendingDepositOf[msg.sender][currentEpoch]`
* ajoute à `totalPendingDeposits[currentEpoch]`
* track l’epoch dans `epochsWithDeposits` si pas déjà listée

### 6.4 rollEpoch (principe)

À la fin de l’epoch e :

1. **Dust check** (important)
   Si `lpFree + lpLocked < 5 USD` → hard reset + sweep au owner + ignore unrealizedPnl.

2. **Calcul equity**
   `equity18 = (lpFree + lpLocked) en 18 - unrealizedPnLTraders18`

3. **Calcul du prix**

* si `totalShares == 0` :

  * prix = 1.0 (WAD)
  * impose `unrealizedPnLTraders18 == 0`
* sinon :

  * impose `equity18 > 0`
  * `price = equity18 * 1e18 / totalShares`

4. **Snapshot**
   `lpTokenPrice[e] = price`

5. **Mint global shares** pour les dépôts de l’epoch e

* `sharesMinted = deposit18 * 1e18 / price`
* `totalShares += sharesMinted`
* `lpFreeCapital += deposits6`

> Les shares “existent globalement”, mais on ne crédite aucun utilisateur individuellement en storage.

6. **Gestion des retraits** : creation de payout tranche (voir section 7)

7. **Update reserve** `minLpFreeReserve6` (voir section 8)

8. **Epoch++**

### 6.5 Lazy evaluation : computeLpShares

`computeLpShares(lp)` :

* parcourt `epochsWithDeposits[lp]`
* pour chaque epoch e :

  * si `pendingDepositOf[lp][e] > 0` et `lpTokenPrice[e] > 0`
  * shares = deposit18 / price
* retourne :

  * shares18 total
  * pendingCurrentEpoch6 (dépôt pas encore “price” car epoch pas fermé)

---

## 7) Système de retraits LP (Buckets + Payout tranches)

C’est le cœur.

### 7.1 Pourquoi deux objets : bucket vs tranche ?

* **Bucket** = “demande de retrait” groupée par epoch de demande
  → contient les shares demandées, et les USD alloués au fil du temps.

* **Tranche** = “cash disponible” à une fin d’epoch
  → correspond aux shares qu’on a réussi à financer à la fin de l’epoch e (brûlées), au prix de l’epoch.

Ensuite, `processWithdrawals` fait la jonction FIFO :

* prend les tranches (cash) et les applique aux buckets (demandes) en ordre chronologique

### 7.2 requestLpWithdrawFromEpochs

Le LP fournit une liste `depositEpochs[]`.
Pour chaque epoch de dépôt :

* lit `pendingDepositOf[user][epoch]` (en 6)
* lit `lpTokenPrice[epoch]` (doit être >0, sinon epoch pas clos)
* calcule shares correspondant au dépôt à ce prix
* met `pendingDepositOf[user][epoch] = 0` (on “sort” ces dépôts du ledger)

Puis :

* ajoute ces shares au bucket de `requestEpoch = currentEpoch`

  * `bucket.totalSharesInitial += shares`
  * `bucket.sharesRemaining += shares`
* ajoute à `userWithdraws[requestEpoch][user].sharesRequested += shares`
* augmente `totalWithdrawSharesOutstanding18` (logique existante)
* **NOUVEAU** : augmente `withdrawSharesUnfunded18` (réserve anti-infini)

> Les shares demandées restent exposées au risque jusqu’à la clôture d’epoch + pricing, car le paiement ne se base pas sur le prix du dépôt initial mais sur la capacité de funding epoch par epoch.

### 7.3 rollEpoch : créer la tranche (burn)

À la fin d’epoch, après le pricing :

On calcule ce qu’on peut payer :

* `unpaidMinusPaid = totalWithdrawSharesOutstanding - totalPaidSharesPendingAlloc`
* calcule max shares payables par `lpFreeCapital` au prix `priceWad`

On choisit `payShares18` = min(ce max, unpaidMinusPaid, withdrawSharesUnfunded18)

Ensuite :

* calcule `usdReserved6 = payShares18 * price / 1e18` (convert en 6)
* retire `usdReserved6` de `lpFreeCapital`
* **brûle** `payShares18` en retirant de `totalShares`
* stocke dans `payoutByEpoch[e]` une tranche :

  * `sharesRemaining18 += payShares18`
  * `priceWad = priceWad`
* augmente `totalPaidSharesPendingAlloc18`

Et surtout, **NOUVEAU** :

* `withdrawSharesUnfunded18 -= payShares18`
  (car elles sont désormais “funded” via burn)

> Important : ce burn est l’instant où on considère “ok, ces shares ont été payées/fundées”, même si l’utilisateur n’a pas encore claim.

### 7.4 processWithdrawals (FIFO)

Boucle contrôlée par `maxSteps` (pas de boucle user).

Elle prend :

* la tranche la plus ancienne non vide
* le bucket le plus ancien non payé

Elle assigne `assignShares` = min(tranche.sharesRemaining, bucket.sharesRemaining)

Puis :

* convertit en `usdAllocated6` au prix de la tranche
* ajoute au bucket `totalUsdAllocated6`
* diminue `bucket.sharesRemaining`
* diminue `tranche.sharesRemaining`
* met à jour `totalPaidSharesPendingAlloc18` et `totalWithdrawSharesOutstanding18`

Résultat :

* les buckets accumulent de l’USD au fil du temps, selon les tranches successives.

### 7.5 claimWithdraw(requestEpoch)

L’utilisateur claim dans un bucket.

On calcule :

* `totalDue6 = bucket.totalUsdAllocated6 * userShares / bucket.totalSharesInitial`
* `payNow = totalDue6 - user.usdWithdrawn6`

Puis :

* on crédite `freeBalance[user] += payNow`
* on met `usdWithdrawn6 = totalDue6` pour permettre des claims partiels au fil des allocations.

---

## 8) Nouveau mécanisme anti-“withdrawal infinity”

### 8.1 Le problème

Sans garde, si beaucoup de retraits sont en attente, le capital libre pourrait être consommé par de nouveaux trades, ce qui peut rendre le funding de la file de retraits **très lent**.

### 8.2 La solution (une seule variable de réserve + une seule variable de tracking)

* `withdrawSharesUnfunded18` : parts en attente de funding (pas encore brûlées)
* `minLpFreeReserve6` : montant USD minimum à laisser libre

Mise à jour :

* `withdrawSharesUnfunded18` augmente quand un retrait est demandé.
* Elle diminue **quand on burn** (au funding epoch).

Ensuite, à la fin de chaque epoch (dans `rollEpoch`), on met :

* `minLpFreeReserve6 = withdrawSharesUnfunded18 * lastPrice`

Donc la réserve représente : “si je devais financer le reste de la file au prix actuel, combien de USD je dois préserver”.

Puis `_lpLock` vérifie que :

* après lock, on garde `lpFreeCapital >= minLpFreeReserve6`

Ainsi :

* tant que la file est grosse, on réduit la capacité à ouvrir des positions nouvelles
* mécaniquement, au fur et à mesure que des positions se ferment (unlock LP), le free capital remonte et les tranches de payout se créent.

---

## 9) Dust reset (anti-états pourris)

### 9.1 Problème

Avec des divisions entières et des claims partiels, il peut rester :

* des poussières de capital (ex: 0.000001$)
* des poussières de shares (ex: 2 wei shares)

Cela peut corrompre le prix (ex: shares trop petites vs capital restant), et donner des prix absurdes.

### 9.2 Solution adoptée

Si `lpFreeCapital + lpLockedCapital < 5 USD` :

* on transfère cette somme au `freeBalance[owner]`
* on remet à zéro :

  * `lpFreeCapital`
  * `lpLockedCapital`
  * `totalShares`
  * et on remet aussi à zéro le système de réserve anti-infini :

    * `withdrawSharesUnfunded18`
    * `minLpFreeReserve6`

On le fait :

* via `sweepDust()` callable
* et automatiquement au début de `rollEpoch`

---

## 10) Invariants à garder en tête (ce qui doit rester vrai)

1. `lpFreeCapital + lpLockedCapital` = capital total (hors dust reset)
2. `lpLockedCapital` ne peut jamais underflow (guard)
3. Un trade Open a toujours `lpLock` réservé (lpLocked)
4. Le vault ne paie un profit trader que si `lpFreeCapital >= profit`
5. Les retraits :

   * `withdrawSharesUnfunded18` représente ce qui n’a pas encore été brûlé
   * `minLpFreeReserve6` dérive du prix d’epoch (snapshot)

---

## 11) Guide de lecture “par fonctionnalités” (pour dev / audit)

### 11.1 Flux trader (position direct)

1. traderDeposit
2. createPosition(tradeId, trader, margin, commission, lpLock)

   * lock trader
   * lock LP (avec réserve)
   * collect commission (30 owner / 70 LP)
3. closeTrade(tradeId, pnl)

   * unlock LP
   * settle :

     * pnl positif : trader reçoit profit - 1% fee
     * pnl négatif : trader perd, LP gagne

### 11.2 Flux LP dépôt

1. requestLpDeposit(amount6) dans epoch N
2. rollEpoch() clôture N :

   * price calculé
   * sharesMinted globalement
   * lpFreeCapital += deposits
3. computeLpShares() permet au front d’afficher shares utilisateur

### 11.3 Flux LP retrait

1. requestLpWithdrawFromEpochs([epochs]) dans epoch N

   * transforme dépôts passés → shares
   * ajoute shares dans bucket N
   * withdrawSharesUnfunded18 augmente
2. rollEpoch() clôture N :

   * crée une tranche payée en burn selon lpFree disponible
   * withdrawSharesUnfunded18 diminue du burn
   * minLpFreeReserve6 est recalculée
3. processWithdrawals(steps) :

   * alloue tranches → buckets FIFO
4. claimWithdraw(N) :

   * le LP récupère son USD virtuel (dans freeBalance)

---

## 12) Points importants / limites actuelles (assumées)

1. Le calcul de shares LP se base sur `pendingDepositOf` (ledger) et `lpTokenPrice`.
   Cela veut dire que **“dépôt” = une entrée comptable** qui devient tradable une fois l’epoch clos.

2. Le système de reserve anti-infini ne force pas de fermeture de positions ouvertes.
   Il empêche seulement de **nouvelles** ouvertures qui aggraveraient la situation.

3. Dust reset : solution volontairement pragmatique “test-friendly”.
   En prod, on pourrait raffiner, mais là c’est clean et stable.

---









## 1) Vue d’ensemble : rôle du Core

Ton contrat **BrokexCore** est le “cerveau” qui :

1. **Liste les assets** (lot size, spread, commission, funding, paramètres de risque).
2. **Stocke les trades** (ordres et positions).
3. **Calcule les coûts** (commission, spread, funding, weekend funding, liquidation).
4. **Maintient l’exposition** par asset (lots long/short + moyennes de prix).
5. **Ajoute un module de calcul du PnL latent** (unrealized PnL) global, en mode batch/epoch de calcul, avec protection contre les changements d’assets pendant la fenêtre.

Le **Vault** est l’exécuteur comptable : il réserve/mouline les fonds (margin, commission, locks LP, settlement, etc.) via ton interface `IBrokexVault`.

---

## 2) States du Trade (système d’état)

Tu as un état dans `Trade.state` (uint8) :

* **0 = Order** : ordre limite (ou ordre en attente). Position pas ouverte.
* **1 = Open Position** : position ouverte (market ou limit exécuté).
* **2 = Closed Position** : position fermée.
* **3 = Cancelled Order** : ordre annulé.

La fonction `_updateTradeState()` impose :

* 0 → (1 ou 3)
* 1 → 2
* sinon bloqué

Et tu `emit TradeEvent(tradeId, newState)`.

Important : ton event `TradeEvent` est “code = newState”. Dans tes anciens messages tu avais un mapping (1=order placed, 2=market open, 3=cancel, 4=close, 5=update SLTP). Là, ton code actuel émet “newState” (0/1/2/3). Donc soit :

* tu assumes `code==state`
* soit tu veux un event différent (ex: `TradeEvent(tradeId, code)` où code suit ton standard 1..5).
  Actuellement, **ce n’est pas le même système** que ton “1..5”.

---

## 3) Unités : le point le plus important

### 3.1 Prix : **1e6 (USDC-like)** partout dans tes calculs internes

Dans `Trade` :

* `openPrice` : `uint48` → **prix en 1e6**
* `closePrice` : `uint48` → **prix en 1e6**
* `stopLoss` / `takeProfit` : `uint48` → **prix en 1e6**

Dans tes fonctions :

* `getVerifiedPrice1e6ForAsset()` retourne `price1e6` → normalisé en **1e6**.
* `calculateOpenCommission()` prend `price1e6` → **1e6**.
* `calculateMargin6()` attend `entryPrice1e6` → **1e6**.

Donc ton “monde prix” dans ce Core est clair : **1e6**.

✅ Conclusion : **tous les prix et niveaux (target, SL, TP, liquidation) doivent être stockés en 1e6**.

---

### 3.2 Montants en USDC : **1e6** (margin, commission, locks)

Dans l’interface vault :

* `margin6`, `commission6`, `lpLock6` : ce sont clairement des **USDC à 6 décimales**.

Dans `Trade` tu ajoutes :

* `marginUsdc` (`uint64`) : tu l’as nommé “marginUsdc” → **cohérent si c’est en 1e6**.
* `lpLockedCapital` (`uint64`) : pareil → **en 1e6**.

⚠️ Point à bien fixer : **`lpLockedCapital` doit être exactement la même unité que `lpLock6`** que tu passes au vault. Sinon ton exposure cap (max profit) est incohérent.

✅ Conclusion : **marginUsdc et lpLockedCapital doivent être en USDC 1e6**.

---

### 3.3 Lots et quantité : attention, tu as un mélange

Tu as dans `Asset` :

* `numerator`
* `denominator`

Ça sous-entend que :

* quantité réelle = `lots * numerator / denominator`
  (ça correspond à une unité “qtyUnits” ou “contrats”, selon ton design)

Mais dans ton Core actuel, tu as **deux styles différents** :

#### A) Dans `calculateOpenCommission()`

Tu fais :

```solidity
notional6 = (price1e6 * lotSize * numerator) / denominator;
```

Donc là tu utilises bien le ratio pour convertir les lots → quantité.

✅ Bien.

#### B) Dans `calculateMargin6()`

Tu fais :

```solidity
notional6 = entryPrice1e6 * lotSize;
margin6 = notional6 / leverage;
```

Là tu n’utilises **pas** numerator/denominator.

⚠️ Donc si `numerator/denominator ≠ 1`, ta marge est fausse par rapport à ta commission et par rapport à ta notion de taille réelle.

#### C) Dans `calculateLockedCapital()`

Tu fais :

```solidity
notional = entryPrice * lotSize;
margin = notional / leverage;
...
physicalProfit = priceMove * lotSize;
```

Là aussi tu ignores numerator/denominator.

✅ Conclusion : aujourd’hui, ton système est **hybride** :

* Commission : lots → qty via (num/den)
* Margin/Lock/Liquidation : lots utilisés “brut” (1 lot = 1 unité)

C’est acceptable **uniquement si** tu décides que :

* **`lotSize` est déjà la quantité réelle** (donc num=den=1 en pratique)
  ou que tu **acceptes l’incohérence** (mais ça va te casser les caps PnL / la gestion du risque).

---

### 3.4 Leverage : unit = “X” (entier)

* `leverage` est un `uint8` : tu appliques directement `/ leverage`.
* Donc `20` = x20 (et pas 2000 ou 20e2).

✅ Conclusion : leverage est un entier simple.

---

### 3.5 Spread / Funding / WeekendFunding : unité “points de prix” en 1e6

Tu as :

* `Asset.spread` (uint32)
* `Asset.weekendFunding` (uint32)
* `Asset.baseFundingRate` (uint32)
* funding indices (uint128 long/shortFundingIndex)

Dans tes commentaires / tes intentions :

* spread est “price delta per lot”
* weekendFunding tu veux le traiter “comme le spread” (ajout au prix de fermeture du côté défavorable)
* funding index : tu veux le transformer en coût en points

Dans tes fonctions :

* `calculateSpread()` retourne un nombre basé sur `a.spread` et l’exposure ratio → c’est **un delta de prix**.
* `calculateWeekendFunding(tradeId)` retourne `weekendsCrossed * a.weekendFunding`.

Donc par construction :
✅ `spread` et `weekendFunding` sont des **deltas de prix en 1e6**.

⚠️ Le funding index : tu le manipules comme un accumulateur “en points de prix” aussi (vu que tu comptes l’utiliser comme delta au close). Donc :
✅ `baseFundingRate`, `fundingIndex`, `fundingDelta` doivent être pensés comme des **points de prix en 1e6** (pas des %).

---

## 4) Logique Spread / Funding / Weekend : ta philosophie

Tu as une philosophie très claire :

* Tu ne “déduis” pas du cash upfront pour spread/funding.
* Tu fais un **prix d’entrée défavorable** (oracle ± spread).
* Et un **prix de sortie défavorable** (oracle ∓ spread).
* Et tu appliques les “coûts” (funding + weekend funding) comme **ajustements de prix** du côté défavorable au close (ou en PnL).

C’est cohérent pour un broker type CFD book B.

Mais tu dois être **rigoureux** sur l’endroit où tu appliques quoi :

### Exemple LONG

* Oracle = 110.000000
* Spread = +0.100000

Entrée affichée/stockée :

* openPrice = 110.100000

Sortie (si oracle=120) :

* fermeture spread défavorable : close = 119.900000
* puis funding/weekend défavorable : close = close - fundingCost - weekendCost
  => donc encore plus bas.

### Exemple SHORT

* Oracle = 110.000000
* Spread = 0.100000
  Entrée :
* openPrice = 109.900000
  Sortie (oracle=100) :
* fermeture défavorable : close = 100.100000
* puis + funding/weekend défavorable : close = close + costs

Cette logique est la plus simple à mentaliser : **tout est un prix** (1e6), et “les coûts” sont juste des **deltas de prix** appliqués au close.

---

## 5) Exposures : ce que tu stockes et ce que tu veux en faire

Tu as dans `Exposure` :

* `longLots`, `shortLots`
* `longValueSum`, `shortValueSum`

Ces 2 derniers servent à calculer un prix moyen :

```solidity
avgLongPrice = longValueSum / longLots;
```

Mais attention : tu stockes `value = lotSize * openPrice` (openPrice est uint48 1e6). Donc :

* valueSum est en **(lots * prix1e6)**.
* avgPrice ressort bien en **prix1e6**.

✅ OK.

Ensuite tu ajoutes :

* `longMaxProfit` / `shortMaxProfit` : somme des `lpLockedCapital` (max profit cap)
* `longMaxLoss` / `shortMaxLoss` : somme des `marginUsdc` (max loss cap)

L’idée : ton **PnL latent** de l’asset ne peut pas dépasser :

* en gain : ce que le LP a lock (cap profit)
* en perte : la marge totale des traders (cap loss)

Ça correspond à ta philosophie “house ne peut pas perdre plus que X” / “trader ne peut pas perdre plus que marge”.

✅ Le principe est bon.

⚠️ Mais il dépend totalement de la cohérence unités :

* `lpLockedCapital` doit être en USDC6
* `marginUsdc` doit être en USDC6
* et ton calcul de PnL latent doit produire aussi du USDC6
  Sinon tu compares des pommes et des oranges.

---

## 6) Module “Unrealized PnL run” : ce que ça fait réellement

Tu as ajouté un système de batch de calcul :

### 6.1 Pourquoi ce système existe

Tu veux calculer le PnL latent sur **tous les assets** sans exploser le gas.
Donc tu fais un run qui peut être alimenté sur plusieurs transactions.

### 6.2 Comment le run fonctionne

* Il y a un `currentPnlRunId`.
* Un run a :

  * startTimestamp
  * totalAssetsAtStart (snapshot = `listedAssetsCount`)
  * assetsProcessed
  * cumulativePnlX6
  * completed

Et une protection :

* pendant qu’un run est actif, tu empêches `listAsset()` (`require(!pnlCalculationActive)`).

### 6.3 Démarrage / reprise

Dans `updateUnrealizedPnl()` :

* si pas de run, ou run expiré (>2 min), ou completed :

  * tu démarres un nouveau run
  * tu mets `pnlCalculationActive = true`
* sinon tu reprends le run en cours

### 6.4 Traitement

Pour chaque assetId fourni :

* tu vérifies qu’il est listed
* tu vérifies qu’il n’est pas déjà traité
* tu lis un proof et tu prends `priceInfo.prices[0]` et `decimal[0]`
* tu vérifies `block.timestamp - priceInfo.timestamp[0] < 60`

⚠️ Ici, tu assumes que dans le proof :

* `priceInfo.timestamp[0]` correspond au bon asset
* `prices[0]` est le bon price pour cet asset
  Or l’API Supra te donne des arrays, et l’asset peut être à un index différent.
  Donc dans cette fonction, tu ne “matches” pas `assetId`. Tu prends index 0.

✅ Concept du run : très bon
⚠️ Implémentation : il faut matcher la bonne paire, comme tu le fais dans `getVerifiedPrice1e6ForAsset()`.

---

## 7) Calcul du PnL latent `_calculateAssetPnlCapped`

Ton algo fait :

1. calcule `avgLongPrice`, `avgShortPrice`
2. normalise `currentPrice` en 1e6
3. calcule :

* longPnl = (normalizedPrice - avgLongPrice) * longLots
* shortPnl = (avgShortPrice - normalizedPrice) * shortLots

Puis applique cap :

* long gain <= longMaxProfit
* long loss <= longMaxLoss
* pareil short

Enfin :

```solidity
return -(longPnl + shortPnl);
```

Donc tu retournes le **PnL du Vault** (house) : si les traders sont gagnants, vault perd => PnL vault négatif (d’où le signe moins).

✅ C’est cohérent avec Book B.

⚠️ Mais unité : ton `longPnl` est en :

* (prix1e6 * lots)

Or ton cap `longMaxProfit` est en USDC6 (si tu stockes bien lpLock6 là-dedans).
Donc tu compares :

* (prix * lots) vs (USDC)
  Ça n’est cohérent **que si** 1 lot = 1 unité et que le prix est un prix direct en USDC par lot (ce qui est ton modèle actuel dans la plupart de tes calculs).
  Mais ça redevient incohérent dès que numerator/denominator ≠ 1.

---

## 8) Résumé clair des unités (à suivre strictement)

### Prix / niveaux (open/close/SL/TP/liq/target/spread/funding/weekend)

* **1e6** (ex: 110.10$ = 110_100_000)

### USDC montants (margin, commission, lpLock, balances vault)

* **1e6**

### Leverage

* entier simple (ex: 20 = x20)

### Lots

Tu dois choisir l’un des 2 modèles et t’y tenir :

#### Modèle 1 (le plus simple)

* `lotSize` est déjà l’unité réelle
* => `numerator/denominator` doivent rester 1/1 ou devenir inutiles

#### Modèle 2 (le plus “pro”)

* `qty = lots * numerator / denominator`
* et **tous** les calculs margin/pnl/lock/liquidation doivent utiliser `qty` au lieu de `lots` bruts.

Actuellement tu es **entre les deux** : commission utilise num/den mais pas les autres.

---

## 9) Ce que j’en pense (avis technique)

### Points forts

* Architecture claire : Core = logique, Vault = cashflow.
* Prix en 1e6 partout : bon choix (cohérent USDC).
* Spread dynamique basé sur imbalance L/S : très bon pour un market maker interne.
* Ajout des caps de PnL latent via `longMaxProfit/longMaxLoss` : très bon pour éviter des estimations absurdes.
* Le système de “PnL run” est une bonne approche pour batcher.

### Points à corriger / clarifier (priorité haute)

1. **Incohérence lots vs numerator/denominator**
   Soit tu supprimes num/den, soit tu l’appliques partout.

2. **updateUnrealizedPnl lit le mauvais index du proof**
   Tu dois retrouver l’index correspondant à `assetId`, sinon tu peux calculer un PnL complètement faux.

3. **pnlX6 vs pnl18**
   Ton Vault interface dit `closeTrade(tradeId, int256 pnl18)`.
   Mais ton Core parle partout en “X6”.
   Donc tu dois décider :

* soit le vault attend du **1e6**, et tu renommes `pnl18` → `pnl6`
* soit tu convertis réellement en 1e18 (multiplier par 1e12).
  Actuellement ton Core est entièrement orienté 1e6.

4. **Weekend funding / funding / spread**
   Tu as bien établi que ce sont des **deltas de prix**. Parfait.
   Il faudra juste être cohérent : à l’exécution close, tu dois appliquer :

* spreadClose (delta de prix)
* * fundingDelta (delta)
* * weekendFunding (delta)
    dans le sens défavorable au trader.

---



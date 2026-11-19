# Best price and Top It Off (ADAddOn 1.7.0.0, 2026-11-19)

How the add-on and AutoDrive Overdrive's "Best price unload" setting work together, and why.

## The rule (built in 1.7.0.0)

With the add-on button ON for a truck, the unload target decides:

| Unload target | Counts as | Top It Off | Best price |
|---|---|---|---|
| A place **your farm owns** (veggie factory, your BGAs, your silos, any production you bought) | Own | Fills it with exactly what it still takes | **Off**, whatever the truck's setting says |
| A selling point **you don't own** (Aldi, Edeka, Harbor, Train Station, Farmers Market, a BGA you haven't bought) | Seller | Plans a full load (a seller never fills up, the log shows "takes inf") | **On** if the truck has it on: picks the best-paying seller in the target's folder |

With the add-on button OFF, nothing changes: AutoDrive's best price setting works as normal.

### How "own" is decided
- `ADAddOn.isOwnTarget(vehicle)` in `scripts/ADAddOn.lua`.
- Looks at every unloading station on the map, takes the one nearest the truck's unload target (2nd marker)
  within 60 m (the same distance best price uses), and checks its placeable's owner:
  `owningPlaceable:getOwnerFarmId() == vehicle:getOwnerFarmId()`.
- Map selling points (no owning placeable, or farm 0) count as sellers.
- No unloading station within 60 m counts as own, so best price stays off (the safe side).
- The add-on's override of `ADBestPrice.getMode` returns OFF only when the add-on is on AND the target is own.

### Why ownership and not "has a selling point"
Nearly every production on the server also has a built-in selling point: Gemüsefabrik (veggie factory), BGA
500 kW / 1 MW / 2 MW, the map's BGA and BGA Nord, Zuckerfabrik, Sägewerk, Molkerei, Futterfabrik, Brauerei and
dozens more in the Fed Production Pack. "Has a selling point = seller" would have let best price send carrots
to the Roadside Stand instead of the veggie factory. Once you own a production you can't sell there, so
ownership is the right test (user's rule).

### Never do this
Do NOT let best price run when the target is one of your own places. When it did, trucks told to
top off a production took the load to a seller instead (carrots to the Roadside Stand, not the veggie factory).

## Log lines
Written once each time the target or its answer changes (`getMode` is called on every unload check, so not every
call is logged):

    [ADAddOn] <truck>: best price: target 'Aldi - Delivery' is a seller (best price allowed) ('nil', 20 m)
    [ADAddOn] <truck>: best price: target 'Veggie factory' is own (Top It Off, best price off) ('Gemuesefabrik', 12 m)

## How best price itself behaves (AutoDrive Overdrive, `scripts/Manager/BestPrice.lua`)
- It decides when the truck **leaves the pickup loaded**, not when you press start
  (PickupAndDeliverMode, STATE_PICKUP -> setDeliverTarget). Until then the HUD shows the target you set.
- It only chooses between targets in the **same folder** as the target you set (e.g. "Trade - Sale").
  A target in a folder with no sellers (e.g. "BGA") never switches.
- A selling point only counts for the folder's target nearest to its unload spot, within 60 m.
- Setting saved per truck as an index: 1 = Off, 2 = One stop, 3 = Each product.
- It is also skipped when "Rotate targets" covers deliveries (only deliver / pickup and deliver).

## What happened (2026-11-19)
- Wood-chip truck (PHOENIX 6x6 Agro-Truck), best price One stop, target Aldi. Aldi doesn't buy wood chips; the
  Harbor and Hardware Store in the same folder do. The truck still went to Aldi, then to the BGA when set there.
- Checked and fine: the NF Marsch Harbor (sellingStation_Hafen) buys WOODCHIPS; the "Harbor - Delivery" marker is
  19 m from its unload point.
- Cause: the add-on overrode best price to OFF whenever its button was on, on purpose, to protect Top It Off.
  Grain trucks with the add-on off switched fine. Turning the add-on off on the wood-chip truck made it switch.
- Fix: 1.7.0.0, the rule above.

## Tests
- Lupa stub test of `isOwnTarget` (2026-11-19), 5/5 passed: own BGA = own; Aldi (map) = seller; BGA not owned =
  seller; seller 5 m away beside an owned production 30 m away = seller (nearest decides); nothing within 60 m = own.
- Not yet tested in game or on the server.

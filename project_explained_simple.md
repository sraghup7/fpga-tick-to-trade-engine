# FPGA Tick-to-Trade Project — Full Explanation (All 9 Steps Stacked)

> A super-fast *simulated* trading system on an FPGA chip. No real money, no real exchange — it's a portfolio demo to prove you can make trading decisions in ~176 nanoseconds with perfectly fixed latency.
> This document stacks the complete, un-shortened explanation for each step as given in chat, so nothing is lost.

---

## Overview: The 9 Steps
1. The Problem — Why speed matters
2. The Mail Format — How price messages look (and the two envelopes)
3. The Ears — How the FPGA receives mail
4. The Notebook — Tracking the best prices (Top of Book)
5. The Clues — Extracting 8 market hints
6. The AI Brain — Predicting a risky trade
7. The Trading Rule — Deciding to Buy/Sell
8. The 9 Security Guards — Blocking dangerous orders
9. The Exit & The Stopwatch — Sending the order and proving speed

---

## Step 1: The Problem — Why Speed Matters

Think of the stock market like a **live auction**.

Everyone in the room hears "Price for Apples is now $10" at the exact same second. The first person to shout "I'LL BUY!" gets the best deal. If you are 1 microsecond slower, someone else took it.

On a normal computer, your reaction time is unpredictable — sometimes 2 microseconds, sometimes 50 microseconds because the computer is busy doing other things. That's bad, because you get slow exactly when the market is most busy.

This project solves it with a **FPGA** — which is not a normal computer. Imagine it as a **fixed assembly line in a factory** instead of a person multitasking.

Every price message goes through the exact same physical path: Station 1 -> Station 2 -> Station 3 -> ... -> Order comes out. The time is always *identical*, e.g., exactly 22 ticks (about 176 nanoseconds). It's not just fast, it's **perfectly predictable**.

**Goal of the project:** Build that assembly line that:
1. Listens to fake price messages from a laptop
2. Decides if it's a good time to trade
3. Double-checks with an AI if it's risky
4. Sends a fake order back — all in a fixed, tiny amount of time

And then prove it worked without ever losing a message, even at 1 million messages in a row.

---

## Step 2: The Mail Format — How Price Messages Look

In Step 1 we said the laptop sends fake price updates to the FPGA. But how does a price update *look* as bytes?

Think of it like a **standard postcard**. Every postcard is exactly **16 bytes** and has the same 6 boxes to fill, always in the same place. Because it's always the same size, the FPGA doesn't have to guess where one message ends and the next begins — it just counts.

Here's the postcard:

| Box | What it means | Simple example |
| :--- | :--- | :--- |
| **Type** (1 byte) | What kind of news is this? | `0x01` = "Price updated", `0x02` = "A trade just happened", `0x03` = "Clear the prices", `0xFF` = "Heartbeat - I'm still here" |
| **Symbol** (1 byte) | Which item? | `1` = Apples, `2` = Oranges. The FPGA only watches 4 items by default. |
| **Side** (1 byte) | Which side of the auction? | `0` = People wanting to BUY, `1` = People wanting to SELL. For a trade, it's who *started* the trade. |
| **Price** (4 bytes) | Price in cents | `10001` means $100.01. No decimals, just whole numbers to keep it simple and exact. |
| **Quantity** (4 bytes) | How many available? | `50` apples for sale. If this is `0`, it means "no one wants to buy/sell anymore" |
| **Quantity** (4 bytes) | How many available? | `50` apples for sale. If this is `0`, it means "no one wants to buy/sell anymore" |
| **Sequence Number** (4 bytes) | Counting number `1,2,3...` | To detect if we *missed* any postcards. If we get 1, 2, **4**, we know 3 was lost. |

*Also has 1 byte for `Flags` (bit0 end-of-burst, bit1 snapshot) — total = 16 bytes, big-endian (network byte order).*

**Two important tricks:**

1.  **Packing:** One big envelope (an Ethernet frame) can hold **1 to 88 postcards** back-to-back. 88 × 16 = 1408 bytes. The FPGA has to handle them streaming one after another, not just one at a time.

2.  **Two Envelope Types:** There are two ways to send the envelope. Mode 0 is super simple (just raw Ethernet). Mode 1 is realistic (looks like internet UDP traffic). The FPGA can do both.

When the FPGA decides to trade, it sends back a *reply postcard* that is also 16 bytes: "I want to BUY 100 of Apples at $100.01, and this was triggered by message #542, and it took me 11 ticks to decide." That reply also tells us the latency for free.

Reply format: `Type 0x10 new order / 0x11 risk reject / 0x12 stats | Symbol | Side | reject_reason (0x00 accepted else gate ID) | Price | Quantity | trigger_seq (low 16 bits of seq) | latency_cyc`

### Clarification: Simple Envelope vs Realistic Envelope

Think of two ways to send a letter:

**Option A: Simple Envelope (called `Mode 0` in the spec)**
This is like **handing a note directly to your friend** in the same room.
*   You write on the envelope: `For FPGA Only - Type 0x88B5` (local-experimental EtherType)
*   Inside is just your 16-byte postcards, nothing else.
*   No address, no stamp, no post office needed.

**Why use it?** It's the easiest way to test if the FPGA is working at all. When you're first building the hardware, you don't want to fight with internet rules. You just want to see "did my postcard arrive?"
You need a special tool on the laptop (a "raw socket") to send it, because normal programs can't send such a bare envelope.

**Option B: Realistic Envelope (called `Mode 1` in the spec)**
This is like **sending a real letter through the post office**.
*   The envelope has: To/From address (IP Address), Check code (to make sure address wasn't smudged — IPv4 header checksum, IHL must be 5), and a Port number (like an apartment number — e.g., `60000`). The FPGA only opens letters addressed to apartment `60000`.
*   EtherType `0x0800`, IPv4, protocol 17 (UDP). UDP checksum is *not* verified (intentional trade-off — verifying would require buffering the whole datagram and destroying latency).
*   Inside is still the same 16-byte postcards.

**Why use it?** Because this is how *real* stock exchanges send data — over the internet protocol (UDP). It proves your design would work in the real world.
For this to work without a real post office, you have to tell your laptop once: `sudo arp -s 192.168.1.10 00:0a:35:01:02:03`. That's the static ARP entry — no ARP responder in v1.

**In short:**
> **Mode 0 = Training wheels.** Super simple, for early testing.
> **Mode 1 = Real road.** Looks like real internet traffic, for the final demo.

The FPGA chip is wired to understand **both**, and you pick which one with a setting called `LINK_MODE`. The rest of the assembly line doesn't care which envelope it came in — once the envelope is opened, it's just postcards.

---

## Step 3: The Ears — How the FPGA Receives the Mail

Imagine the cable from the laptop to the FPGA is a **highway with 4 lanes, and cars drive on both sides of the road at the same time**.

That's what `RGMII` means. It's just the physical wires from the JLSemi JL2121(D) PHY chip. It's fast and complicated, so:

**Station A — The Translator (`rgmii_to_gmii`):**
This just translates the crazy 4-lane-both-sides highway (4-bit DDR @125 MHz) into a normal **1-lane, 8-bit wide road** inside the FPGA where everything moves at 125 MHz (125 million ticks per second). Think of it as converting a highway into a single-file conveyor belt. From here on, everything is very orderly: 1 byte per tick.

**Station B — The Mailroom (`eth_mac_rx`):**
Every Ethernet envelope has extra packaging — a preamble (a knock on the door), SFD, and a check code at the end (FCS) that proves the envelope wasn't damaged in transit.

This station: 1. Strips the preamble/SFD away. 2. Checks the FCS. If the code is wrong, it silently throws the whole envelope in the trash and counts it (`err_fcs`). Only clean envelopes go forward.

**Station C — The Security Guard (`frame_classifier`):**
Looks at the stamp on the envelope.

*   If `LINK_MODE = 0`, does it say `0x88B5`? If yes, payload begins at byte 14. If not, trash it.
*   If `LINK_MODE = 1`, does it have EtherType `0x0800`, IHL=5, valid IPv4 header checksum, protocol 17, and UDP port == `cfg_udp_port` (default 60000)? Any failure = discard and increment the matching counter (`err_ethertype`, `err_ip`, `err_udp_port`). Wrong port, bad checksum, IHL !=5 all discarded.

This is also why trash has many different counters — you want to know *why* it was thrown away.

**Station D — The Opener (`md_parser`):**
Now we are inside. This station cuts the payload into exact **16-byte postcards**. It is byte-serial → structured message.

It has one simple rule: **The total length must be divisible by 16**. If you get 17 bytes or 15 bytes or 0 bytes, the whole envelope is trash (`err_frame_len`) because it means the messages are corrupted, and the parser resets to idle before the next frame. If it's 32 or 48 or 1408 bytes (1–88 messages), it streams them out one postcard at a time, cycle by cycle, accepting minimum inter-frame gap (IFG) without loss.

At the **very last byte of each postcard entering this station, we stamp the time**. That timestamp is our "start" time for the speed stopwatch. It will travel with the postcard all the way to the end, carried with the message. At egress we will compute latency.

Everything up to here has been about just *getting the mail cleanly* without dropping anything, at minimum IFG for 10,000 frames.

---

## Step 4: The Notebook — Tracking the Best Prices (Top of Book)

Now the clean postcards arrive inside. What do we do with them?

Imagine the FPGA keeps a tiny **notebook with 4 pages** (because it watches only 4 symbols by default, `NUM_SYMBOLS=4`, like Apples, Oranges, Bananas, Grapes). Each page has just 4 things written on it:

*   **Best price someone will BUY for** (Bid Price) + how many they want (Bid Qty) + a `valid` bit
*   **Best price someone will SELL for** (Ask Price) + how many they have (Ask Qty) + a `valid` bit

That's called the **"Top of Book"** — just the single best buy and single best sell price. Not the whole list of all buyers, just the #1 on each side. `Spread = ask - bid` in ticks, `Mid = (bid + ask) >> 1` integer floor.

There are 3 stations here before we write in the notebook:

**Station E — The Bouncer (`symbol_filter`):**
The FPGA gets mail for 256 possible symbols (0–255), but our notebook only has 4 pages (`SYMBOL_0..3` default 1,2,3,4, with `SYMBOL_EN` mask).

This guy checks the `symbol_id` on the postcard against a 4-entry CAM. Is it one of our 4 watched Apple/Orange IDs?
*   No -> Throw it away, count it (`cnt_filtered`), do nothing, no feature update.
*   Yes -> Send it to the notebook and count `cnt_msgs_accepted`.

Also filters `msg_type` outside defined set (`err_msg_type`) and reserved `flags` bits (`err_flags`).

**Station F — The Missed-Mail Detector (`seq_monitor`):**
Remember the sequence number `1,2,3,4...` on every postcard? It wraps at 2^32.

*   If we expect `#5` and we get `#7`, it knows we missed 2 postcards. It increments `cnt_seq_gap` by the gap, sets sticky `seq_gap`, and asserts `stale`. It also means our notebook might now be wrong, so later security guards will block trading until we get a `flags.snapshot=1` message or explicit CSR clear (`CTRL.bit3`).
*   If we get `#4` again (a duplicate or out-of-order, i.e., less than expected) → drop message, increment `cnt_seq_dup`, no book modification.

It also has a **staleness timer** (`cycles_since_update > cfg_max_age` default 1,250,000 cycles = 10ms). If we haven't heard *anything* for a long time, the data is considered stale/old and we shouldn't trade on it.

**Station G — The Notebook Keeper (`tob_engine`):**
This is simple and fast — 1 cycle register write, holds `bid_price`, `bid_qty`, `ask_price`, `ask_qty`, per-side `valid` bits:

*   Got a `0x01` update for the BUY side? **Erase and overwrite** that side's price/qty on that page, set `valid`. That's snapshot-replace per side, not incremental add/modify/cancel.
*   `quantity=0` means "that side is now empty" -> we clear `valid` without altering stored price.
*   Got a `0x03` clear? Erase *both* valid bits for that symbol, increment `cnt_book_clear`.
*   Got a `0x02` trade or `0xFF` heartbeat? Don't change the notebook at all. A heartbeat just resets the staleness timer ("I'm still alive"). Trade increments `cnt_trades`.

It also checks if the notebook is in an impossible state: **Is the best BUY price >= best SELL price?** (`bid_price >= ask_price` with both valid). That's called `crossed` (bid > ask) or `locked` (bid == ask). In a real market that's impossible/corrupt, so we flag `crossed` status, increment `cnt_crossed`, and later guards will block trading. Book initializes to invalid on reset.

At this point, we have a clean, up-to-date notebook. All the next steps will read from this notebook.

---

## Step 5: The Clues — Extracting 8 Hints About the Market

The notebook now knows the best BUY/SELL price. But to predict if a trade is risky, we need *hints* (features) about what the market is *doing*.

Think of it like a doctor checking 8 vitals before giving a diagnosis. The FPGA calculates these 8 clues after **every** notebook update, in just 1 tick (plus 1 for normalization), using only simple math (add, subtract, shift, compare — no multipliers or division on this stage).

For the watched symbol at event `t`, with best bid `b_t`, best ask `a_t`, bid size `q_b,t`, ask size `q_a,t`, mid `m_t = (b_t + a_t) >>1`:

| Clue | Name | Formula | What it asks in plain English |
| :--- | :--- | :--- | :--- |
| **F0** | **Spread** | `a_t - b_t` (unsigned ticks) | Is the gap between buyers and sellers wide or narrow? |
| **F1** | **Mid-price delta** | `m_t - m_{t-1}` (signed ticks) | Did the middle price go up or down since last time? |
| **F2** | **Book imbalance** | `q_b - q_a` v1 (signed, no division) | Are there way more buyers than sellers or vice-versa? `5 buyers vs 50 sellers` = heavy selling pressure |
| **F3** | **Bid-size change** | `q_{b,t} - q_{b,t-1}` (signed) | Did buyers just grow or shrink? |
| **F4** | **Ask-size change** | `q_{a,t} - q_{a,t-1}` (signed) | Did sellers just grow or shrink? |
| **F5** | **Update Rate** | updates in last `W` events (unsigned clipped) | How *busy* has it been in last 16 events? Lots = nervous |
| **F6** | **Last Trade Direction** | buy=+1, sell=-1, none=0 (from `0x02` side) | Who started the last trade? |
| **F7** | **Volatility Proxy** | sum of |mid deltas| over last `W` events (clipped) | How much did price *jitter* total? Calm vs shaky |

**Why Spread wide = low interest?**
*   Narrow (e.g., Buy $10.00, Sell $10.02, gap 2c) → lots of competition, buyers/sellers almost agree, crowded active market, cheap to trade → **high interest**.
*   Wide (Buy $8, Sell $12, gap $4) → lowball vs too high, far apart, no one wants to trade, if you buy now you pay $12 terrible deal → **low interest**. When few trade, nothing squeezes the gap.

To compute these, the FPGA needs tiny memory per symbol:
*   `prev_bid`, `prev_ask`, derived `prev_mid` (for F1)
*   A `W`-wide (default 16, allowed 4/8/16/32) update-window shift register + popcount (F5)
*   A `W`-deep delay line of |mid deltas| with running sum (F7)
*   `last_trade_side` (F6) — updated only by `0x02` trade prints (aggressor side), persists across book updates until next trade; also updates the window without changing book price/qty.

With `NUM_SYMBOLS=4` and `W=16`, this is a few dozen registers per symbol — registers, not BRAM.

**Squeezer (`feature_normalizer`):**
Raw clues can be big (qty 10,000). AI wants tiny numbers -128..127.
```
tiny x_i = saturate_{[-128,127]}( (raw_i - offset_i) >>> shift_i )
```
Like converting Celsius to 0–100. `offset_i` and `shift_i` (power-of-two only, arithmetic right shift floor toward -∞) are chosen during training and loaded into registers `ML_OFFSET_0..7` / `ML_SHIFT_0..7`. `>>` must be *arithmetic* floor, not truncation — `np.right_shift` or `// (2**shift)`, never `int(v/2**shift)`. Saturate, never wrap.

Result: **8 tiny `int8` numbers**. These are the exact input to the AI. Features are computed only for watched symbols; filtered messages produce no feature update. When side is invalid/crossed/locked/gap, classifier input is forced to safe state and `adverse_risk` forced to 1.

---

## Step 6: The AI Brain — Predicting a Risky Trade

This is the "smart" part, but it's actually a very **tiny and simple AI**. It does NOT decide to buy or sell. It only answers one question:

> **"If we put out a quote right now, is it likely the price will move against us in the next H events (H=20/50/100) and we'll be adversely selected?"**

Adverse selection = offering to sell at $10, price crashes to $8 a second later, you got stuck.

**How does this tiny AI work?**

Remember the 8 squeezed clues (-128..127). The AI does:
```
Score z = b + (w0*x0) + (w1*x1) + ... + (w7*x7)   // b is int32 bias, w_i int8 weights
```
*   `x0..7` = 8 clues.
*   `w0..7` = 8 **weights** learned during training ("how important is each clue?").
*   `b` = starting bias.
*   All products `w_i·x_i` → int16 exact, sum + bias → **int32 `z`**. Max |sum| = 8 × 16384 = 131072, so int32 never overflows. **No silent truncation.**

That's it. Just **8 multiplications + 8 additions**. Keras model is literally `Dense(1, use_bias=True, activation='linear')` with 8 inputs. That's why it fits (≤8 DSP48 v1, ≤16 v2).

**How is `z` turned into a decision?**

We have **two lines**, not one — **hysteresis** to stop flickering 1-0-1-0:

*   If `z >= T_high` (e.g., >=100) → **Risky = 1** (block)
*   If `z <= T_low` (e.g., <=80) → **Safe = 0** (allow)
*   If `T_low < z < T_high` → **hold previous value**.

`T_high > T_low`, both runtime registers `ML_TH_HIGH` / `ML_TH_LOW` (int32). We also produce `risk_level` (uint8) = `saturate((z + offset) >> shift)` via `ML_SCORE_OFFSET/SHIFT` for nice telemetry/graph.

**Three boundary facts:**
1. Feature extraction/normalization is in RTL, not in model.
2. You (ML) own normalization *parameters* (offsets/shifts) exported in `model_config.json`.
3. Threshold/hysteresis is in RTL (`ml_policy.v`), not in model — you export recommended `T_high/T_low`.

**Two safety rules:**
1. **Fail-Safe (FR-31):** If notebook invalid, crossed/locked, sequence gap, or stale → `adverse_risk` forced to **1** regardless of `z`. Better to block than trade on garbage. Counts as `cnt_ml_safe_forced`.
2. **Who builds it?** ML teammate trains in **Python only** (Keras/TF, numpy, hls4ml, Vitis HLS 2023.x, part `xc7a35tfgg484-2`, `Backend=Vitis`, `IOType=io_parallel`, `ReuseFactor=1`, `Precision ap_fixed<8,8>` int8). Must verify bit-exact: `hls_model.predict()` == `ml_golden.py` on every golden vector before hand-off. Weights/bias baked at synthesis (`weights.mem`, `bias.mem`); thresholds/offsets/shifts are runtime registers.

**The AI runs *in parallel* with the trading rule.** ML path (~7–10 cycles: extractor 1 + normalizer 1 + classifier 2–3 + policy 1) is deeper than signal path (~2 cycles). We delay the trading rule's order intent through a **fixed-depth alignment shift register `[ALIGN]` (depth ≈4–5 = ML depth − signal depth, compile-time constant)** so both arrive at risk engine **same cycle, every cycle, by construction**. This keeps total latency fixed and data-independent (NFR-14). Mismatch would be a race condition, not tuning.

---

## Step 7: The Trading Rule — Deciding to Buy or Sell

This is the **actual trader** — a very simple, fixed deterministic rule. It's not AI; the AI from Step 6 only *vetoes* this trader.

After each book-modifying update, the rule wakes up and asks: **Should we try to trade?** Evaluated on every book-modifying message, not on a timer; need not have changed value.

**BUY Rule (FR-35) — Do we want to BUY at the SELL price?**
We generate a *want-to-buy* order intent IF all true:
1. Both sides valid, not crossed (`bid < ask`)
2. `spread >= cfg_min_spread` (MIN_SPREAD register 0x1C default 2 ticks)
3. `bid_qty > (ask_qty << cfg_imb_shift)` (IMB_SHIFT 0x20 default 1 → ×2). Imbalance: way more buyers than sellers → price might rise, so buy now.

If all 3 pass → **order intent**: "Buy `cfg_order_qty` (0x24 default 100) at `ask_price`". Counts `cnt_signal_buy`.

**SELL Rule (FR-36) — Mirror:**
1. Both valid, not crossed
2. `spread >= cfg_min_spread`
3. `ask_qty > (bid_qty << cfg_imb_shift)` (way more sellers than buyers → price may drop, so sell now)

→ "Sell `cfg_order_qty` at `bid_price`". Counts `cnt_signal_sell`.

**Key facts:**
*   Uses only super cheap math: barrel-shift, compare, subtract. **No multipliers, no DSP on signal path**.
*   Both rules true at once is **impossible by construction** (can't have both `buy>>sell` AND `sell>>buy`). If ever detected → no order, increment `err_signal_conflict` (FR-37).
*   Takes just **1 tick** (`tob_engine → signal_engine`).
*   Intent is **delayed via fixed `[ALIGN]`** to meet AI verdict same cycle at risk engine. The signal branch is hidden inside ML latency; it adds nothing to total.

---

## Step 8: The 9 Security Guards — Blocking Dangerous Orders

At this point we have an **order intent** ("I want to buy 100 at $10.02") plus AI verdict (`Risky=1 or 0`). But we are **not allowed to send it yet**.

It must walk past **9 guards standing side-by-side**. They all check the order *in parallel in a single cycle* (FR-42). If *any* guard raises a hand, the order is blocked. **FR-41: No path emits an order bypassing the risk engine.** Any implementation where risk is slower, disable-able, or bypass-able fails.

| ID | Gate | Blocks if... | Rationale |
|---|---|---|---|
| **0x01** | **Kill Switch** | `kill_latched` | Operator halt, overrides everything. Blocks within 1 cycle of input registration, latches, deassertion alone doesn't resume — explicit CSR clear (`CTRL.bit1`) required. Readable as STATUS.bit0, drives dedicated LED. |
| **0x02** | **Max Size** | `order_qty > cfg_max_order_qty` (0x28 default 500) | No unbounded fat-finger order |
| **0x03** | **Max Position** | `|position ± order_qty| > cfg_max_position` (0x2C default 1000) | Bounds exposure. Position per symbol updated on each accepted order under fill model (v1: immediate full fill at limit price, optimistic) |
| **0x04** | **Price Band** | `|order_price - mid| > cfg_price_band` (0x30 default 50 ticks) | Protects against corrupt price |
| **0x05** | **Stale Data** | `cycles_since_update > cfg_max_age` (0x34 default 1,250,000 =10ms) | Don't trade on quiet/guessed book |
| **0x06** | **Sequence Gap** | `seq_gap` sticky | Messages missed; book unreliable until resync |
| **0x07** | **Crossed/Locked** | `bid_price >= ask_price` both valid | Physically impossible → corrupt |
| **0x08** | **Throttle** | Token bucket empty (`cfg_token_max` 8, `cfg_token_refill_cycles` 12500 =100µs) | Bounds rate, runaway signal |
| **0x09** | **Adverse Selection (ML)** | `adverse_risk==1` | ML estimates quote likely adversely selected within H. `cfg_ml_action` (ML_CTRL 0x50): `0x0` Block (default), `0x1` Reduce size by `cfg_ml_reduce_shift` (`qty>>shift`, floor ≥1). ML is advisory to risk engine, never overrides hard gates. |

**Why crossed book is blocked:**
In a *single* healthy centralized exchange, crossed (`bid > ask`) should *never* persist — engine would match instantly. Seeing `bid >= ask` means your data is corrupt/stale or you combined two different exchanges. Locked (`bid==ask`) is rare but also non-tradable. Correct professional response is *block until uncrossed or snapshot*, exactly what Guard 0x07 does. In fragmented US equities, NBBO should not be crossed; apparent cross = latency glitch. Our system counts `cnt_crossed` and forces AI to `Risky=1`.

**How it reports:**
*   Every blocked order increments that guard's counter (`cnt_rej_kill`, `cnt_rej_size`... `cnt_rej_ml`). If 2 guards fire at once, **both counters increment**, but `reject_reason` = **lowest-numbered gate** (so hard gates 0x01–0x08 dominate ML 0x09). Multiple gates → lowest wins.
*   `cfg_reject_report` (CTRL.bit4, 0x50 ML_CTRL.bit? actually CTRL.bit4): default 0 off, so diagnostics don't influence measured behavior. If 1, emit `0x11` diagnostic frame for blocked orders.
*   ML counters: `cnt_ml_events = cnt_ml_adverse + cnt_ml_benign`, `cnt_rej_ml ≤ cnt_ml_adverse`, `cnt_ml_safe_forced ≤ cnt_ml_adverse`.
*   Conservation invariants asserted: `cnt_msgs_rx = cnt_msgs_filtered + cnt_msgs_accepted + Σ(err_*)`, `cnt_signal_buy+sell = cnt_orders_tx + Σ(cnt_rej_*) + overflow`.

If *all 9* say PASS, intent becomes a real order and moves to final builder.

---

## Step 9: The Exit & The Stopwatch — Sending the Order and Proving It Was Fast

**1. The Exit (`order_builder` + `eth_mac_tx`):**

If all 9 guards passed, the intent is encoded per §4.5 and transmitted as a single frame with correct framing for active `LINK_MODE` (incl. IPv4 checksum in Mode 1). Takes ~1 tick `Risk → first order byte`, frame occupies TX ~84 cycles.

Takes settings from §9 register map (all CSR 0x20 write / 0x21 read request / 0x22 read response), effect on next message boundary. Maintains `lat_min`, `lat_max`, `lat_last`.

What if another trading signal fires *while* we're still sending? We have a tiny **2-deep order output register, not a deep FIFO**, with explicit overflow policy: 3rd order while 2 pending is **dropped**, `cnt_order_overflow` increments. Dropping is correct — queued stale order trades on outdated info, and unbounded queue would make latency history-dependent, violating NFR-1 (fixed constant). No FIFO whose fullness varies with content.

Orders are not reordered relative to triggering messages. A market-data message arriving during TX is still parsed/applied; only subsequent order TX may queue.

**2. The Stopwatch (The Most Important Proof):**

We have a free-running 32-bit cycle counter at 125MHz (8ns period).

*   **Timestamp IN:** At `md_parser` (Station D), captured at last byte of a message entering parser, carried with message.
*   **Timestamp OUT:** At `order_builder` handing first byte to MAC TX.
*   `latency = OUT - IN`, record in **64-bucket BRAM histogram** (`latency_histogram`), plus `lat_min/max/last` readable via stats frames every `cfg_stats_period` (0x44 default 12,500,000 =100ms) and on-demand CSR read. Reading never stalls fast path. Emitting `latency_cyc` inside order means host capture is simultaneously a latency log.

**Why the histogram is special:**
The project succeeds ONLY if histogram shows **exactly ONE occupied bucket** for the accepting path across full 1M-message soak (NFR-1/2). Second bucket = functional bug, not performance result. Target **≤22 cycles (176ns)**, exact value measured and published in §12. Design-target budget:

| Stage | Cycles | Notes |
|---|---|---|
| Parser ingress → structured message | 1 | timestamp at last byte |
| Symbol filter (CAM) | 1 | |
| Book update (register write) | 1 | |
| Feature extraction (F0–F7) | 1 | |
| Feature normalization (shift/saturate) | 1 | |
| ML classifier (hls4ml Dense parallel MAC) | 2–3 | |
| ML policy (hysteresis) | 1 | |
| Risk (all 9 gates incl. ML) | 1 | parallel |
| Order builder → first byte | 1 | serialize |
| **Engine total (tick-to-trade)** | **~10–11 (target ≤22)** | single fixed value |

Signal branch (`book→signal→intent` 1 cycle) is hidden inside ML branch via `[ALIGN]` ≈4–5 cycles.

Wire-to-wire latency (including MAC RX/TX) measured separately and reported as budget table.

**3. Slow Path (never backpressures fast path):**
*   `csr_block`: config + counters, UDP-addressed.
*   `stats_reporter`: periodic stats frame emitter.
*   `debug_uart`: fallback ingress accepting same 16-byte format for bring-up without Ethernet. Latency flagged not-meaningful in this mode.
*   `latency_histogram`: 64 buckets BRAM.
Single 125MHz clock domain for engine; any CDC (UART, buttons/KEY[0] kill switch, LED[3:0] status) confined to slow path with two-flop synchronizers. Fast path stall-free by construction, consumes 8 bits/cycle from MAC, no stage slower than predecessor, fully pipelined, no stalls/arbitration/dynamic memory/variable-iteration loops.

---

## One-Sentence Version (§1.7)

> A pipelined Artix-7 datapath that receives a Gigabit-Ethernet market-data feed, maintains top-of-book state, extracts fixed-point features, runs a quantized hls4ml-generated adverse-selection classifier, gates the order intent through deterministic risk checks plus the ML verdict, and emits a simulated order — at a measured, fixed tick-to-trade latency, verified against a golden model.

**Success Criteria (§1.6) — project succeeds if all demonstrated and documented:**
1. Back-to-back messages at Gigabit line rate without dropping/reordering, ≥1,000,000 messages
2. Tick-to-trade latency fixed — single histogram bucket, max==min
3. Every risk gate including ML 0x09 individually demonstrated blocking/reducing an order, with counter per reason
4. Full RTL output (orders *and* ML score `z` and `adverse_risk`) matches bit-exact Python golden models on randomized soak
5. hls4ml IP `z` matches Python fixed-point golden model bit-exactly for every regression vector
6. Meets timing at 125MHz on XC7A35T-2FGG484I with WNS>0; utilization/timing published (≤15% LUTs, ≤10% FFs, ≤8 BRAM, 0 DSP excluding ML; ML ≤8 DSP v1)
7. One-command reproduce: clone repo, run one command, reproduce simulation results

---

*Generated from `fpga_tick_to_trade_master_spec.md` v2.0 (single source of truth) and `ml_engineer_brief.md`. Spec-only, pre-implementation — no `rtl/`/`sim/` yet. Target: Artix-7 `XC7A35T-2FGG484I`, 125MHz single domain, Vivado/Vitis HLS 2023.x, Verilog-2001 (exception: hls4ml IP).*


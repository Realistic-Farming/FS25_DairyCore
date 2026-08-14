-- =========================================================
-- FS25_DairyCore - Constants (all tunables live here)
-- =========================================================
-- Author: TisonK
-- Global: DairyConstants. Categories: QUALITY, SPOILAGE, HERD, COLLECTION,
-- CONTRACTS, MYCOTOXIN, PROSTAFF, NETWORK.
--
-- NOTE (F12, gated on Tyson): the contract volume/payout figures below come from
-- the design balance pass but are NOT yet mapped to Ritter's per-cow age-curve.
-- They are tunable placeholders; confirm against the SDK base litersPerDay curve
-- before treating them as final.
-- =========================================================

DairyConstants = {}

-- Milk quality tiers, evaluated from the herd health score (0-100).
DairyConstants.QUALITY = {
    -- ordered high to low; first tier whose minScore <= score wins
    TIERS = {
        { name = "Premium",  key = "premium",  minScore = 85, priceMod = 1.20, processingMod = 1.15 },
        { name = "Standard", key = "standard", minScore = 60, priceMod = 1.00, processingMod = 1.00 },
        { name = "Reduced",  key = "reduced",  minScore = 35, priceMod = 0.85, processingMod = 1.00 },
        { name = "Poor",     key = "poor",     minScore = 0,  priceMod = 0.70, processingMod = 1.00 },
    },
}

-- Time-based spoilage. Stages are keyed off in-game days since last collection.
-- tierDrop reduces the quality tier by N steps; "Condemned" forces Poor.
DairyConstants.SPOILAGE = {
    FRESH_DAYS       = 1.0,   -- < 1 day: Fresh
    AGEING_DAYS      = 2.0,   -- 1-2 days: Ageing (-1 tier)
    ATRISK_DAYS      = 3.0,   -- 2-3 days: At Risk (-2 tiers)
    -- 3+ days: Condemned (Poor regardless)
    STAGES = {
        fresh     = { name = "Fresh",     tierDrop = 0 },
        ageing    = { name = "Ageing",    tierDrop = 1 },
        atrisk    = { name = "At Risk",   tierDrop = 2 },
        condemned = { name = "Condemned", tierDrop = 99 },
    },
    -- ProStaff L18 extends the Fresh window by this many in-game hours.
    L18_FRESH_BONUS_HOURS = 6,
}

-- Standard-mode herd-health modifiers (applied over the base globalProductionFactor).
DairyConstants.HERD = {
    OM_DEPLETED       = 3.5,   -- OM below this on a feed field: -5 herd health
    OM_SEVERE         = 2.0,   -- OM below this: severe penalty
    OM_DEPLETED_PEN   = 5,
    OM_SEVERE_PEN     = 12,
    BALANCED_NPK_BONUS = 5,    -- all of N/P/K "Good" on feed fields: +5
    WEED_PRESSURE_LIMIT = 50,  -- weed pressure above this at a feed field: -10 milk quality
    PEST_PRESSURE_LIMIT = 50,  -- pest pressure above this: herd health event risk
    WEED_QUALITY_PEN  = 10,
    LEGUME_QUALITY_FLOOR_BONUS = 5,  -- legume rotation on a feed field: +5 quality floor
    SCORE_MIN = 0,
    SCORE_MAX = 100,
}

-- Collection scheduling (administrative; no AI pathing).
DairyConstants.COLLECTION = {
    DEFAULT_INTERVAL_HOURS = 24,   -- in-game hours between scheduled collections
    -- Worker skill effect keyed to WorkerCosts' FOUR real levels (novice/experienced/
    -- master/legendary). speedMod < 1 = faster run.
    SKILL = {
        novice      = { speedMod = 1.00, fuelMod = 1.15, earlyFlag = false },
        experienced = { speedMod = 0.92, fuelMod = 1.00, earlyFlag = false },
        master      = { speedMod = 0.85, fuelMod = 1.00, earlyFlag = true  },  -- flags low feed/water early
        legendary   = { speedMod = 0.80, fuelMod = 1.00, earlyFlag = true  },  -- + herd-decline flag at ProStaff L16
    },
    -- The four ways milk can leave a barn (DC-9). `self` and `hauled` are detected
    -- passively from the level; `rota` and `office` are the mod's own active paths
    -- (DC-9's rota and DC-21's office sale) and record the collection themselves.
    SOURCES = {
        self   = "self",
        hauled = "hauled",
        rota   = "rota",
        office = "office",
    },
    -- The rota's published state. HireHall publishes EIGHT lifecycle states; three
    -- of them (available/hired/training/injured/onLeave/contract) are still on the
    -- round, the terminal states mean the man is gone, and anything unknown is
    -- treated as still on the round (DC-9 3.5).
    ROTA_STATES = {
        UNASSIGNED    = "unassigned",
        ASSIGNED_OK   = "assigned_ok",
        ASSIGNED_DEPARTED = "assigned_departed",
    },
    -- The six HireHall lifecycle values that mean the worker is STILL on the round
    -- (keys lowercase: lifecycle values are compared lowercased). `injured` and
    -- `onleave` are deliberately included: HireHallEvolution auto-moves a worker to
    -- onLeave at fatigue 95, and a two-way read would lapse the round the harder a
    -- farmer works his best man. The terminal states are the two NOT here.
    ON_ROUND_STATES = {
        available = true, hired = true, training = true,
        injured = true, onleave = true, contract = true,
    },
    -- The only KNOWN terminal states. Everything else, recognised or not, is treated
    -- as still on the round (DC-9 3.5: an unknown lifecycle must not silently lapse
    -- a round).
    TERMINAL_STATES = {
        retired = true, fired = true,
    },
}

-- DC-21: administrative milk disposal. The margin is the administrative cost of an
-- office/rota sale with no truck and no fuel, and its MAGNITUDE is a human ruling.
-- This default is a RECOMMENDATION (a percentage, because it scales with herd size),
-- named and tunable via SettingsHub, never hardcoded inline. Pending Arissani's call.
DairyConstants.SALE = {
    DEFAULT_MARGIN = 0.05,   -- 5% off the spot price
    MARGIN_MIN     = 0.0,
    MARGIN_MAX     = 0.25,
    INCOME_LABEL   = "Milk Sale (Administrative)",
}

-- Dairy contracts. termDays are in-game DAYS (Time Guard clock; no "week").
-- volumeTarget is total litres over the term. premiumRate multiplies the spot price.
DairyConstants.CONTRACTS = {
    TYPES = {
        standard = {
            key = "standard", name = "Standard Dairy Contract",
            volumeTarget = 8000,  termDays = 30, premiumRate = 1.12, qualityRequired = nil,
            prostaffLevel = 0,
        },
        premium_quality = {
            key = "premium_quality", name = "Premium Quality Contract",
            volumeTarget = 21000, termDays = 45, premiumRate = 1.18, qualityRequired = "standard",
            prostaffLevel = 0,
        },
        syndicate = {
            key = "syndicate", name = "Syndicate Dairy Contract",
            volumeTarget = 52000, termDays = 60, premiumRate = 1.22, qualityRequired = "standard",
            prostaffLevel = 15,
        },
        sovereign_floor = {
            -- Not a standalone contract: an ongoing modifier at ProStaff L20 that floors
            -- any active contract at 85% of the base-game sell price (pre-volatility).
            key = "sovereign_floor", name = "Sovereign Floor", floorFraction = 0.85,
            prostaffLevel = 20,
        },
    },
    -- Fill type name used to read the milk spot price from MarketDynamics / base game.
    MILK_FILLTYPE = "MILK",
    -- DairyCore's own premium applied while a "livestock_boom" world event is active.
    LIVESTOCK_BOOM_MILK_BONUS = 1.12,
    LIVESTOCK_BOOM_PROCESSING_BONUS = 1.08,
    -- OM-211: organic-fed herd milk premium, PER FARM, at settlement. SHIP value
    -- 1.0 is NEUTRAL (no premium until Arissani's unlock pass sets it, steward
    -- C2); the pay line floors at 1.0 so organic can only add. Awaiting the
    -- Economy spine.
    ORGANIC_MILK_PREMIUM_MAX = 1.0,
    INCOME_LABEL = "Livestock Contract Income",
}

-- Mycotoxin / contaminated-feed penalty (read-only herd-health penalty in BOTH modes;
-- never a Ritter disease injection - F13).
DairyConstants.MYCOTOXIN = {
    MIN_PENALTY = 15,
    MAX_PENALTY = 25,
    MIN_DAYS = 3,
    MAX_DAYS = 5,
}

-- Feed Provenance (authority #5, FP-1). The per-farm per-fill-type fraction vector.
-- Numbers ride the Option-Scaling Spine once it exists; these are the neutral
-- values the design ratified. CONTAMINATED_DECAY_PER_DAY is the fraction of the
-- remaining contamination healed each in-game day (Biological dial, neutral here).
-- ORGANIC_THRESHOLD is the share of the consumed organic fraction above which a
-- diet classifies organic (the ratified THRESHOLD default; strictness rides the
-- Livestock dial, neutral here).
DairyConstants.FEED_PROVENANCE = {
    LEDGER = "DairyCore_FeedProvenance",
    CONTAMINATED_DECAY_PER_DAY = 0.15,
    ORGANIC_THRESHOLD = 0.8,
}

-- ProStaff ladder multipliers DairyCore reads (all neutral 1.0 when absent).
DairyConstants.PROSTAFF = {
    L3_LOGISTICS = 1.05,
    L12_QUALITY  = 1.05,
    L19_GLOBAL   = 1.05,
    L20_GLOBAL   = 1.15,   -- supersedes L19 (does not stack)
    -- F143: "Herdsman Automation" renamed 2026-08-07. RealisticLivestock owns
    -- the word Herdsman (it ships a wage-bearing Herdsman subsystem); no
    -- player-facing string of ours uses it. DairyCore's own vocabulary for this
    -- job is collection scheduling, hence Collection. Internal identifier stays.
    HERDSMAN_EXPENSE_LABEL = "Collection Automation",
}

-- Wire contract for CHANNEL_BARNS. The NetworkSync value encoding carries
-- bool/int32/float32/string and nothing else, and a nil neither writes a slot nor
-- advances the array length, so every slot on the wire is a non-nil scalar and an
-- absent value travels as an explicit sentinel. Writer and reader must agree on
-- BARN_STRIDE exactly: a record one slot short reads every later barn at the wrong
-- offset, which puts one barn's numbers into another barn's typed fields.
DairyConstants.NETWORK = {
    CHANNEL_BARNS = "DairyCore_BarnState",
    CHANNEL_COLLECTIONS = "DairyCore_Collections",
    BARN_STRIDE = 10,
    NONE_STRING = "",   -- absent string slot (worker id, feed field list)
    NONE_NUMBER = -1,   -- absent numeric slot (last collection day, next due)
}

-- NetworkSync admin-gated actions (all default adminOnly = true; DC-9 and DC-21
-- take the default rather than overriding it).
DairyConstants.ACTIONS = {
    SELL_MILK     = "DairyCore_SellMilk",      -- DC-21 office sale (args: barnId, quantity)
    ASSIGN_ROTA   = "DairyCore_AssignRota",    -- DC-9 rota assignment (args: barnId, workerId)
    UNASSIGN_ROTA = "DairyCore_UnassignRota",  -- DC-9 rota release (args: barnId)
}

-- Time Guard accrual priorities (lower settles first). Money-moving before reads.
DairyConstants.SETTLE_PRIORITY = {
    CONTRACT = 20,
}

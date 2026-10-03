-- opslabs-animations: opslabs-towers hands its climbing poses to this resource while it runs, and tells it about every
-- rung, step and harness action. Stop this resource and opslabs-towers falls back to its own simpler poses (no sounds).
Config = {}

Config.Sounds = {
    Enabled = true,
    Volume = 0.7,            -- 0..1, your own sounds
    Range = 30.0,            -- metres: other players hear your climbing / harness within this
    Variants = { ladder_rung = 4, ladder_hand = 2, pole_step = 4, pole_grip = 2, harness_jingle = 4, harness_clip = 1, harness_unclip = 1, webbing = 1, buckle = 1 },
    JingleChance = 0.45,     -- on each climbing step with a harness on
    WalkJingle = true,       -- harness gear jingles as you walk / run with it on
}

Config.Climb = {
    MountClip = true,        -- step-on clip when you start climbing from the ground
    HandSwap = true,         -- holding on: the hand that's up follows the last step you took
    IdleShift = 7.0,         -- seconds holding still before you shift your grip / weight
}

Config.Move = {
    HarnessWalk = 'move_m@tool_belt@a',   -- walk style while wearing the harness (false = off); skipped if the game lacks it
    CarryLadder = { dict = 'anim@heists@box_carry@', clip = 'idle' },          -- arms out while carrying a ladder
    PullCable = { dict = 'missfbi4prepp1', clip = '_bag_walk_garbage_man' },   -- cable in hand while pulling it
}

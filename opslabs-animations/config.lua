-- opslabs-animations: opslabs-towers hands its climbing poses to this resource while it runs, and tells it about every
-- step. Stop this resource and opslabs-towers falls back to its own simpler poses. /opsanim checks which animations your game has.
Config = {}

Config.Climb = {
    MountClip = true,        -- step-on clip when you start climbing from the ground
    -- holding on: every IdleShift seconds, play a brief real regrip motion (the climb cycle running forward
    -- for a moment) instead of staying frozen — the base game has no mirrored right-hand hold pose to swap
    -- to, so this plays genuine hand-over-hand movement rather than faking a pose that doesn't exist
    Regrip = true,
    IdleShift = 7.0,         -- seconds holding still before you shift your grip / weight
    -- used when the game build has no ladder climb clips (laddersbase): reaching up, hands on the pole / rails
    Fallback = { dict = 'amb@prop_human_movie_bulb@base', clip = 'base' },
}

Config.Move = {
    HarnessWalk = { male = 'move_m@tool_belt@a', female = 'move_f@tool_belt@a' },   -- walk style while wearing the harness (false = off); skipped if the game lacks it
    CarryLadder = { dict = 'anim@heists@box_carry@', clip = 'idle' },          -- arms out while carrying a ladder
    PullCable = { dict = 'missfbi4prepp1', clip = '_bag_walk_garbage_man' },   -- cable in hand while pulling it
}

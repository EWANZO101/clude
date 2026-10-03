# opslabs-animations

More lifelike movement for the OPS Network (`opslabs-towers`), with sounds.

**Climbing (ladders & poles):** your limbs follow the distance you climb, and you step on with a proper step-on clip when you start
from the ground. Holding on, the hand you last reached up with stays up, and you shift your grip now and then. Working on a pole
(menus, repairs) puts your hands forward with your legs holding on.

**Moving around:** a tool-belt walk while wearing the harness; arms out while carrying a ladder; cable in hand while pulling cable.

**Sounds** (nearby players hear yours, quieter with distance and panned left / right):
- boots on aluminium ladder rungs, hands on the stiles
- boots on steel pole steps and the pole taking your weight, hands on the wood
- harness gear jingling as you climb, walk and run; buckles when you put it on / take it off
- the pole strap going round the pole, the karabiner clipping on and off

How it fits together: `opslabs-towers` calls this resource's exports while you climb (`Begin`, `Drive`, `Pose`, `End`) and raises
`opslabs:harness` / `opslabs:carry` events. Stop this resource and towers goes back to its own simpler poses with no sounds.

Settings in `config.lua` (volume, range, walk style, jingle). The sounds are generated, not sampled:
`python3 source/make_sfx.py html/sfx` rebuilds them (tweak the recipes in that file).

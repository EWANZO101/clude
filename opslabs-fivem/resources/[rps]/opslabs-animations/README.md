# opslabs-animations

More lifelike movement for the OPS Network (`opslabs-towers`).

**Climbing (ladders & poles):** your limbs follow the distance you climb, and you step on with a step-on clip when you start
from the ground. Holding on, the hand you last reached up with stays up, and you shift your grip now and then. Working on a pole
(menus, repairs) puts your hands forward with your legs holding on. If your game build has no ladder climb clips, a reach-up
pose (rocking in time with your steps) is used instead.

**Moving around:** a tool-belt walk while wearing the harness; arms out while carrying a ladder; cable in hand while pulling cable.

**`/opsanim`** lists which of these animations your game has (✔ / ✘, details in F8) and plays the climb on the spot for 4 s.

How it fits together: `opslabs-towers` calls this resource's exports while you climb (`Begin`, `Drive`, `Pose`, `End`) and raises
`opslabs:carry` events. Stop this resource and towers goes back to its own simpler poses. Settings in `config.lua`.

# PocketMap's minimap starts off for everyone, and PocketMap remembers who
# turned it on. This turns it on once, at a player's first join, so it is on
# by default; a player who then runs /pocketmap off keeps it off.
pocketmap_default:
    type: world
    events:
        after player joins:
        - if <player.has_flag[pocketmap_default]>:
            - stop
        - flag <player> pocketmap_default
        # After the resource packs, which hold the player in place while loading.
        - wait 5s
        - if <player.is_online>:
            - execute as_player "pocketmap on"

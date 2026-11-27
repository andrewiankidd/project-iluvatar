# NPCs, declared in git. Each server lists its NPCs under `npcs:` in its
# values.yaml; the npcs init container (common/values.yaml) writes that list
# to plugins/Denizen/data/npcs.yml, and this script makes the world match it:
#
#   - an NPC in the list that is missing is created; one that is no longer
#     listed is removed (hand-made Citizens NPCs are never touched)
#   - each follows its schedule: it walks to where it should be, then
#     stands, sits, sleeps, wanders an area, or keeps shop
#   - clicking one gets a line from it; a shopkeeper at their shop, in shop
#     hours, opens the trading window instead
#
# Schedules run by the in-game clock, or by the real one (`clock: real`) on a
# world whose daylight cycle is off.
#
# An NPC only moves while its chunk is loaded. When the chunk loads again it
# is placed wherever its schedule says it is by then, so to anyone arriving
# it has kept its hours.
#
# /npcspot <name> records where you stand, and which way you face, as a
# place for the list (plugins/Denizen/data/npcspots.yml).

npcs_events:
  type: world
  debug: false
  events:
    after scripts loaded:
    - run npcs_reconcile
    on delta time minutely:
    - run npcs_reconcile
    on delta time secondly every:2:
    - foreach <server.npcs_flagged[npc_id]> as:npc:
      - if <[npc].is_spawned>:
        - run npcs_tick def.npc:<[npc]> def.snap:false
    after npc spawns:
    - if <npc.has_flag[npc_id]>:
      - flag <npc> npc_doing:!
      - run npcs_tick def.npc:<npc> def.snap:true

# Reads data/npcs.yml and creates, updates or removes NPCs to match it.
npcs_reconcile:
  type: task
  debug: false
  script:
  - if <yaml.list.contains[npcs]>:
    - yaml unload id:npcs
  - if !<util.has_file[data/npcs.yml]>:
    - stop
  - ~yaml load:data/npcs.yml id:npcs
  - define places <yaml[npcs].read[places].if_null[<map>]>
  - define areas <yaml[npcs].read[areas].if_null[<map>]>
  - define people <yaml[npcs].read[people].if_null[<map>]>
  - flag server npcs.clock:<yaml[npcs].read[clock].if_null[world]>
  - yaml unload id:npcs
  - flag server npcs.places:<[places]>
  - flag server npcs.areas:<[areas]>
  - foreach <server.npcs_flagged[npc_id]> as:npc:
    - if !<[people].contains[<[npc].flag[npc_id]>]>:
      - remove <[npc]>
  - foreach <[people]> key:id as:p:
    - define plan <proc[npcs_plan].context[<list_single[<[p].get[schedule].if_null[<list>]>]>]>
    - define npc <server.npcs_flagged[npc_id].filter[flag[npc_id].equals[<[id]>]].first.if_null[null]>
    - define name <[p].get[name].if_null[<[id]>]>
    - if <[npc]> == null:
      - define at <world[world].spawn_location>
      - if <[plan].any>:
        - define at <proc[npcs_place].context[<[plan].first.get[target]>]>
      - create player <[name].parse_color> <[at]> save:made
      - define npc <entry[made].created_npc>
      - flag <[npc]> npc_id:<[id]>
      - flag <[npc]> npc_name:<[name]>
      - assignment set script:npcs_person to:<[npc]>
      - lookclose <[npc]> state:true range:6 realistic
    - if <[npc].flag[npc_name].if_null[]> != <[name]>:
      - adjust <[npc]> name:<[name].parse_color>
      - flag <[npc]> npc_name:<[name]>
    - define skin <[p].get[skin].if_null[]>
    - if <[skin]> != <[npc].flag[npc_skin].if_null[]>:
      - flag <[npc]> npc_skin:<[skin]>
      - if <[skin].starts_with[http]>:
        - execute as_server "npc skin --url <[skin]> --id <[npc].id>" silent
      - else if <[skin]> != <empty>:
        - adjust <[npc]> skin:<[skin]>
    - flag <[npc]> npc_plan:<[plan]>
    - flag <[npc]> npc_lines:<[p].get[lines].if_null[<list>]>
    - flag <[npc]> npc_closed:<[p].get[closed].if_null[null]>
    - define trades <list>
    - foreach <[p].get[trades].if_null[<list>]> as:t:
      - define inputs <list>
      - foreach <[t].get[for].if_null[<list>].as[list]> as:i:
        - define inputs <[inputs].include_single[<proc[npcs_item].context[<[i]>]>]>
      - define trade <trade[trade].with[result=<proc[npcs_item].context[<[t].get[sell]>]>].with[max_uses=2147483647].with[has_xp=false]>
      - define trades <[trades].include_single[<[trade].with[inputs=<[inputs]>]>]>
    - flag <[npc]> npc_trades:<[trades]>

# "8 iron_ingot" or "iron_ingot" as an item.
npcs_item:
  type: procedure
  debug: false
  definitions: spec
  script:
  - define parts <[spec].split[ ]>
  - if <[parts].size> == 1:
    - determine <item[<[parts].first>]>
  - determine <item[<[parts].get[2]>].with[quantity=<[parts].first>]>

# A schedule as a list of {hour, kind, target}, earliest first. Each entry is
# `at:` (7, or "7:30") and one of shop/stand/sit/sleep (a place) or wander
# (an area).
npcs_plan:
  type: procedure
  debug: false
  definitions: schedule
  script:
  - define plan <list>
  - foreach <[schedule]> as:e:
    - define at <[e].get[at].if_null[0]>
    - define hour <[at].before[:].if_null[<[at]>]>
    - if <[at].contains[:]>:
      - define hour <[hour].add[<[at].after[:].div[60]>]>
    - foreach shop|stand|sit|sleep|wander as:kind:
      - if <[e].contains[<[kind]>]>:
        - define plan <[plan].include_single[<map[hour=<[hour]>;kind=<[kind]>;target=<[e].get[<[kind]>]>]>]>
        - foreach stop
  - determine <[plan].sort_by_number[get[hour]]>

# A place: its name in `places:`, or "x y z [yaw [pitch [world]]]" as it is.
npcs_place:
  type: procedure
  debug: false
  definitions: spec
  script:
  - define spec <server.flag[npcs.places].get[<[spec]>].if_null[<[spec]>]>
  - define p <[spec].split[ ]>
  - if <[p].size> < 3:
    - debug error "NPCs: no place called '<[spec]>'"
    - determine <world[world].spawn_location>
  - determine <location[<[p].get[1]>,<[p].get[2]>,<[p].get[3]>,<[p].get[5].if_null[0]>,<[p].get[4].if_null[0]>,<[p].get[6].if_null[world]>]>

# An area: its name in `areas:`, or "x1 y1 z1 x2 y2 z2 [world]" as it is.
npcs_area:
  type: procedure
  debug: false
  definitions: spec
  script:
  - define spec <server.flag[npcs.areas].get[<[spec]>].if_null[<[spec]>]>
  - define p <[spec].split[ ]>
  - if <[p].size> < 6:
    - debug error "NPCs: no area called '<[spec]>'"
    - determine null
  - determine <cuboid[<[p].get[7].if_null[world]>,<[p].get[1]>,<[p].get[2]>,<[p].get[3]>,<[p].get[4]>,<[p].get[5]>,<[p].get[6]>]>

# The hour now, 0 to 24, by the clock the list names: `clock: world` (the
# default) is the in-game day, `clock: real` the server's own time of day,
# for a world whose daylight cycle is off.
npcs_hour:
  type: procedure
  debug: false
  definitions: world
  script:
  - if <server.flag[npcs.clock].if_null[world]> == real:
    - determine <util.time_now.hour.add[<util.time_now.minute.div[60]>]>
  - determine <[world].time.div[1000].add[6].mod[24]>

# The schedule entry for now: the latest one at or before the current hour,
# or yesterday's last one before the first of the day.
npcs_now:
  type: procedure
  debug: false
  definitions: npc
  script:
  - define plan <[npc].flag[npc_plan].if_null[<list>]>
  - if <[plan].is_empty>:
    - determine null
  - define now <proc[npcs_hour].context[<[npc].location.world>]>
  - determine <[plan].filter[get[hour].is_less_than_or_equal_to[<[now]>]].last.if_null[<[plan].last>]>

# Moves an NPC along its schedule. `snap` (its chunk just loaded) puts it in
# place at once; otherwise it walks there while anyone is near enough to see,
# and is put there when nobody is or the walk gets stuck.
npcs_tick:
  type: task
  debug: false
  definitions: npc|snap
  script:
  - define a <proc[npcs_now].context[<[npc]>]>
  - if <[a]> == null:
    - stop
  - define key <[a].get[hour]>/<[a].get[kind]>/<[a].get[target]>
  - if <[npc].flag[npc_doing].if_null[]> != <[key]>:
    - if <[npc].has_flag[npc_posed]>:
      - stand npc:<[npc]>
      - flag <[npc]> npc_posed:!
      - lookclose <[npc]> state:true range:6 realistic
    - flag <[npc]> npc_doing:<[key]>
    - flag <[npc]> npc_arrived:!
    - flag <[npc]> npc_since:<util.time_now>
    - if <[a].get[kind]> == wander:
      - flag <[npc]> npc_spots:<proc[npcs_area].context[<[a].get[target]>].spawnable_blocks.if_null[<list>]>
  - define seen <[npc].location.find_players_within[48].is_empty.not>
  - if <[a].get[kind]> == wander:
    - define spots <[npc].flag[npc_spots].if_null[<list>]>
    - if <[spots].is_empty>:
      - stop
    - if !<[npc].has_flag[npc_arrived]> && ( <[snap]> || !<[seen]> ):
      - teleport <[npc]> <[spots].random.center.below[0.5]>
      - flag <[npc]> npc_arrived
      - stop
    - if !<[npc].is_navigating> && <util.random_chance[20]>:
      - walk <[npc]> <[spots].random.center.below[0.5]> auto_range
      - flag <[npc]> npc_arrived
    - stop
  - if <[npc].has_flag[npc_arrived]>:
    - stop
  - define dest <proc[npcs_place].context[<[a].get[target]>]>
  - define far <[npc].location.world.equals[<[dest].world>].not.or[<[npc].location.distance[<[dest]>].is_more_than[1.2]>]>
  - if <[far]>:
    - define stuck <util.time_now.duration_since[<[npc].flag[npc_since]>].in_minutes.is_more_than[3]>
    - if !<[snap]> && <[seen]> && !<[stuck]>:
      - if !<[npc].is_navigating>:
        - walk <[npc]> <[dest]> auto_range
      - stop
  - if <[npc].is_navigating>:
    - walk <[npc]> stop
  - teleport <[npc]> <[dest]>
  - flag <[npc]> npc_arrived
  - choose <[a].get[kind]>:
    - case sit:
      - sit npc:<[npc]> <[dest]>
      - flag <[npc]> npc_posed
    - case sleep:
      - lookclose <[npc]> state:false
      - sleep npc:<[npc]> <[dest]>
      - flag <[npc]> npc_posed

# Every declared NPC's assignment: what a click does.
npcs_person:
  type: assignment
  debug: false
  actions:
    on assignment:
    - trigger name:click state:true
    on click:
    - run npcs_click def.npc:<npc>

npcs_click:
  type: task
  debug: false
  definitions: npc
  script:
  - define reply <proc[npcs_reply].context[<[npc]>]>
  - if <[reply]> == trade:
    - opentrades <[npc].flag[npc_trades]> title:<[npc].name>
  - else if <[reply]> != null:
    - narrate <[reply]>

# What a click gets: `trade` (the trading window), a line to show, or null.
# A shopkeeper trades only at their shop in shop hours; otherwise they say
# when they open (`closed:` replaces that), and anyone else says one of
# their `lines:`.
npcs_reply:
  type: procedure
  debug: false
  definitions: npc
  script:
  - define kind <proc[npcs_now].context[<[npc]>].get[kind].if_null[none]>
  - define trades <[npc].flag[npc_trades].if_null[<list>]>
  - if <[kind]> == sleep && <[npc].has_flag[npc_arrived]>:
    - determine "<[npc].name><&7> is fast asleep."
  - if <[kind]> == shop && <[npc].has_flag[npc_arrived]> && <[trades].any>:
    - determine trade
  - define line <[npc].flag[npc_lines].random.if_null[null]>
  - if <[trades].any>:
    - define line <[npc].flag[npc_closed].if_null[null]>
    - if <[line]> == null:
      - define open <[npc].flag[npc_plan].filter[get[kind].equals[shop]].parse[get[hour]]>
      - define now <proc[npcs_hour].context[<[npc].location.world>]>
      - define next <[open].filter[is_more_than[<[now]>]].first.if_null[<[open].first.if_null[null]>]>
      - define line "We're closed."
      - if <[next]> != null:
        - define line "We're closed. Come back at <[next].round_down>:<[next].mod[1].mul[60].round.pad_left[2].with[0]>."
  - if <[line]> == null:
    - determine null
  - determine "<[npc].name><&f>: <[line].parse_color>"

# /npcspot <name>: records where you stand, and which way you face.
npcs_spot_command:
  type: command
  debug: false
  name: npcspot
  usage: /npcspot <&lt>name<&gt>
  description: Records where you stand as a place for the NPC list.
  permission: npcs.spot
  script:
  - if <context.args.is_empty>:
    - narrate "<&c>Usage: /npcspot <&lt>name<&gt>"
    - stop
  - define name <context.args.first>
  - define l <player.location>
  - define spot "<[l].x.round_to[1]> <[l].y.round_to[1]> <[l].z.round_to[1]> <[l].yaw.round_to[1]> <[l].pitch.round_to[1]>"
  - if <[l].world.name> != world:
    - define spot "<[spot]> <[l].world.name>"
  - if !<yaml.list.contains[npcspots]>:
    - if <util.has_file[data/npcspots.yml]>:
      - ~yaml load:data/npcspots.yml id:npcspots
    - else:
      - yaml create id:npcspots
  - yaml id:npcspots set <[name]>:<[spot]>
  - ~yaml savefile:data/npcspots.yml id:npcspots
  - narrate "<&a>Saved <&f><[name]><&a>: <&7><[spot]>"

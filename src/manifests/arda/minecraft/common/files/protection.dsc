# Who may change each world, from the server's protection: list (in its
# values.yaml; the denizen-data init container in common/values.yaml writes it
# to plugins/Denizen/data/protection.yml). On every start it makes WorldGuard's
# __global__ region in each listed world match: exactly these members, and
# these flags. Regions inside a world keep their own members and flags.
#
# A server with no protection: list is left as it is.

protection_events:
  type: world
  debug: false
  events:
    after scripts loaded:
    - run protection_apply

protection_apply:
  type: task
  debug: false
  script:
  - if <yaml.list.contains[protection]>:
    - yaml unload id:protection
  - if !<util.has_file[data/protection.yml]>:
    - stop
  - ~yaml load:data/protection.yml id:protection
  - define worlds <yaml[protection].read[worlds].if_null[<list>]>
  - define members <yaml[protection].read[members].if_null[<list>]>
  - define flags <yaml[protection].read[flags].if_null[<map>]>
  - yaml unload id:protection
  # Plus the builders from the minecraft-players Secret, written by the same
  # init container to builders.yml.
  - if <util.has_file[data/builders.yml]>:
    - if <yaml.list.contains[builders]>:
      - yaml unload id:builders
    - ~yaml load:data/builders.yml id:builders
    - define members <[members].include[<yaml[builders].read[builders].if_null[<list>]>]>
    - yaml unload id:builders
  - foreach <[worlds]> as:world:
    - execute as_server "rg removemember -w <[world]> -a __global__"
    - if <[members].any>:
      - execute as_server "rg addmember -w <[world]> __global__ <[members].space_separated>"
    # "unset" clears a flag, leaving the region's default.
    - foreach <[flags]> key:flag as:value:
      - if <[value]> == unset:
        - execute as_server "rg flag -w <[world]> __global__ <[flag]>"
      - else:
        - execute as_server "rg flag -w <[world]> __global__ <[flag]> <[value]>"
  - debug log "[protection] __global__ set in <[worlds].comma_separated>"

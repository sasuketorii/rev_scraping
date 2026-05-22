_rev-stealth() {
    local i cur prev opts cmd
    COMPREPLY=()
    if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
        cur="$2"
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
    fi
    prev="$3"
    cmd=""
    opts=""

    for i in "${COMP_WORDS[@]:0:COMP_CWORD}"
    do
        case "${cmd},${i}" in
            ",$1")
                cmd="rev__stealth"
                ;;
            rev__stealth,auth)
                cmd="rev__stealth__subcmd__auth"
                ;;
            rev__stealth,browser)
                cmd="rev__stealth__subcmd__browser"
                ;;
            rev__stealth,captcha)
                cmd="rev__stealth__subcmd__captcha"
                ;;
            rev__stealth,cf-evaluate)
                cmd="rev__stealth__subcmd__cf__subcmd__evaluate"
                ;;
            rev__stealth,config)
                cmd="rev__stealth__subcmd__config"
                ;;
            rev__stealth,doctor)
                cmd="rev__stealth__subcmd__doctor"
                ;;
            rev__stealth,help)
                cmd="rev__stealth__subcmd__help"
                ;;
            rev__stealth,hermes)
                cmd="rev__stealth__subcmd__hermes"
                ;;
            rev__stealth,measure)
                cmd="rev__stealth__subcmd__measure"
                ;;
            rev__stealth,relocate)
                cmd="rev__stealth__subcmd__relocate"
                ;;
            rev__stealth,spider)
                cmd="rev__stealth__subcmd__spider"
                ;;
            rev__stealth,vpn)
                cmd="rev__stealth__subcmd__vpn"
                ;;
            rev__stealth__subcmd__auth,delete)
                cmd="rev__stealth__subcmd__auth__subcmd__delete"
                ;;
            rev__stealth__subcmd__auth,help)
                cmd="rev__stealth__subcmd__auth__subcmd__help"
                ;;
            rev__stealth__subcmd__auth,list)
                cmd="rev__stealth__subcmd__auth__subcmd__list"
                ;;
            rev__stealth__subcmd__auth,login)
                cmd="rev__stealth__subcmd__auth__subcmd__login"
                ;;
            rev__stealth__subcmd__auth,refresh)
                cmd="rev__stealth__subcmd__auth__subcmd__refresh"
                ;;
            rev__stealth__subcmd__auth,show)
                cmd="rev__stealth__subcmd__auth__subcmd__show"
                ;;
            rev__stealth__subcmd__auth,status)
                cmd="rev__stealth__subcmd__auth__subcmd__status"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,delete)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__delete"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,help)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,list)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__list"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,login)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__login"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,refresh)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__refresh"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,show)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__show"
                ;;
            rev__stealth__subcmd__auth__subcmd__help,status)
                cmd="rev__stealth__subcmd__auth__subcmd__help__subcmd__status"
                ;;
            rev__stealth__subcmd__browser,help)
                cmd="rev__stealth__subcmd__browser__subcmd__help"
                ;;
            rev__stealth__subcmd__browser,launch)
                cmd="rev__stealth__subcmd__browser__subcmd__launch"
                ;;
            rev__stealth__subcmd__browser,stealth-test)
                cmd="rev__stealth__subcmd__browser__subcmd__stealth__subcmd__test"
                ;;
            rev__stealth__subcmd__browser__subcmd__help,help)
                cmd="rev__stealth__subcmd__browser__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__browser__subcmd__help,launch)
                cmd="rev__stealth__subcmd__browser__subcmd__help__subcmd__launch"
                ;;
            rev__stealth__subcmd__browser__subcmd__help,stealth-test)
                cmd="rev__stealth__subcmd__browser__subcmd__help__subcmd__stealth__subcmd__test"
                ;;
            rev__stealth__subcmd__captcha,help)
                cmd="rev__stealth__subcmd__captcha__subcmd__help"
                ;;
            rev__stealth__subcmd__captcha,solve)
                cmd="rev__stealth__subcmd__captcha__subcmd__solve"
                ;;
            rev__stealth__subcmd__captcha,verify)
                cmd="rev__stealth__subcmd__captcha__subcmd__verify"
                ;;
            rev__stealth__subcmd__captcha__subcmd__help,help)
                cmd="rev__stealth__subcmd__captcha__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__captcha__subcmd__help,solve)
                cmd="rev__stealth__subcmd__captcha__subcmd__help__subcmd__solve"
                ;;
            rev__stealth__subcmd__captcha__subcmd__help,verify)
                cmd="rev__stealth__subcmd__captcha__subcmd__help__subcmd__verify"
                ;;
            rev__stealth__subcmd__config,diff)
                cmd="rev__stealth__subcmd__config__subcmd__diff"
                ;;
            rev__stealth__subcmd__config,edit)
                cmd="rev__stealth__subcmd__config__subcmd__edit"
                ;;
            rev__stealth__subcmd__config,gc)
                cmd="rev__stealth__subcmd__config__subcmd__gc"
                ;;
            rev__stealth__subcmd__config,get)
                cmd="rev__stealth__subcmd__config__subcmd__get"
                ;;
            rev__stealth__subcmd__config,help)
                cmd="rev__stealth__subcmd__config__subcmd__help"
                ;;
            rev__stealth__subcmd__config,history)
                cmd="rev__stealth__subcmd__config__subcmd__history"
                ;;
            rev__stealth__subcmd__config,init)
                cmd="rev__stealth__subcmd__config__subcmd__init"
                ;;
            rev__stealth__subcmd__config,migrate)
                cmd="rev__stealth__subcmd__config__subcmd__migrate"
                ;;
            rev__stealth__subcmd__config,paths)
                cmd="rev__stealth__subcmd__config__subcmd__paths"
                ;;
            rev__stealth__subcmd__config,profile)
                cmd="rev__stealth__subcmd__config__subcmd__profile"
                ;;
            rev__stealth__subcmd__config,rollback)
                cmd="rev__stealth__subcmd__config__subcmd__rollback"
                ;;
            rev__stealth__subcmd__config,set)
                cmd="rev__stealth__subcmd__config__subcmd__set"
                ;;
            rev__stealth__subcmd__config,show)
                cmd="rev__stealth__subcmd__config__subcmd__show"
                ;;
            rev__stealth__subcmd__config,validate)
                cmd="rev__stealth__subcmd__config__subcmd__validate"
                ;;
            rev__stealth__subcmd__config__subcmd__help,diff)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__diff"
                ;;
            rev__stealth__subcmd__config__subcmd__help,edit)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__edit"
                ;;
            rev__stealth__subcmd__config__subcmd__help,gc)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__gc"
                ;;
            rev__stealth__subcmd__config__subcmd__help,get)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__get"
                ;;
            rev__stealth__subcmd__config__subcmd__help,help)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__config__subcmd__help,history)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__history"
                ;;
            rev__stealth__subcmd__config__subcmd__help,init)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__init"
                ;;
            rev__stealth__subcmd__config__subcmd__help,migrate)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__migrate"
                ;;
            rev__stealth__subcmd__config__subcmd__help,paths)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__paths"
                ;;
            rev__stealth__subcmd__config__subcmd__help,profile)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__profile"
                ;;
            rev__stealth__subcmd__config__subcmd__help,rollback)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__rollback"
                ;;
            rev__stealth__subcmd__config__subcmd__help,set)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__set"
                ;;
            rev__stealth__subcmd__config__subcmd__help,show)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__show"
                ;;
            rev__stealth__subcmd__config__subcmd__help,validate)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__validate"
                ;;
            rev__stealth__subcmd__config__subcmd__help__subcmd__profile,create)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__create"
                ;;
            rev__stealth__subcmd__config__subcmd__help__subcmd__profile,delete)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__delete"
                ;;
            rev__stealth__subcmd__config__subcmd__help__subcmd__profile,list)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__list"
                ;;
            rev__stealth__subcmd__config__subcmd__help__subcmd__profile,switch)
                cmd="rev__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__switch"
                ;;
            rev__stealth__subcmd__config__subcmd__profile,create)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__create"
                ;;
            rev__stealth__subcmd__config__subcmd__profile,delete)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__delete"
                ;;
            rev__stealth__subcmd__config__subcmd__profile,help)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__help"
                ;;
            rev__stealth__subcmd__config__subcmd__profile,list)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__list"
                ;;
            rev__stealth__subcmd__config__subcmd__profile,switch)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__switch"
                ;;
            rev__stealth__subcmd__config__subcmd__profile__subcmd__help,create)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__create"
                ;;
            rev__stealth__subcmd__config__subcmd__profile__subcmd__help,delete)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__delete"
                ;;
            rev__stealth__subcmd__config__subcmd__profile__subcmd__help,help)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__config__subcmd__profile__subcmd__help,list)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__list"
                ;;
            rev__stealth__subcmd__config__subcmd__profile__subcmd__help,switch)
                cmd="rev__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__switch"
                ;;
            rev__stealth__subcmd__help,auth)
                cmd="rev__stealth__subcmd__help__subcmd__auth"
                ;;
            rev__stealth__subcmd__help,browser)
                cmd="rev__stealth__subcmd__help__subcmd__browser"
                ;;
            rev__stealth__subcmd__help,captcha)
                cmd="rev__stealth__subcmd__help__subcmd__captcha"
                ;;
            rev__stealth__subcmd__help,cf-evaluate)
                cmd="rev__stealth__subcmd__help__subcmd__cf__subcmd__evaluate"
                ;;
            rev__stealth__subcmd__help,config)
                cmd="rev__stealth__subcmd__help__subcmd__config"
                ;;
            rev__stealth__subcmd__help,doctor)
                cmd="rev__stealth__subcmd__help__subcmd__doctor"
                ;;
            rev__stealth__subcmd__help,help)
                cmd="rev__stealth__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__help,hermes)
                cmd="rev__stealth__subcmd__help__subcmd__hermes"
                ;;
            rev__stealth__subcmd__help,measure)
                cmd="rev__stealth__subcmd__help__subcmd__measure"
                ;;
            rev__stealth__subcmd__help,relocate)
                cmd="rev__stealth__subcmd__help__subcmd__relocate"
                ;;
            rev__stealth__subcmd__help,spider)
                cmd="rev__stealth__subcmd__help__subcmd__spider"
                ;;
            rev__stealth__subcmd__help,vpn)
                cmd="rev__stealth__subcmd__help__subcmd__vpn"
                ;;
            rev__stealth__subcmd__help__subcmd__auth,delete)
                cmd="rev__stealth__subcmd__help__subcmd__auth__subcmd__delete"
                ;;
            rev__stealth__subcmd__help__subcmd__auth,list)
                cmd="rev__stealth__subcmd__help__subcmd__auth__subcmd__list"
                ;;
            rev__stealth__subcmd__help__subcmd__auth,login)
                cmd="rev__stealth__subcmd__help__subcmd__auth__subcmd__login"
                ;;
            rev__stealth__subcmd__help__subcmd__auth,refresh)
                cmd="rev__stealth__subcmd__help__subcmd__auth__subcmd__refresh"
                ;;
            rev__stealth__subcmd__help__subcmd__auth,show)
                cmd="rev__stealth__subcmd__help__subcmd__auth__subcmd__show"
                ;;
            rev__stealth__subcmd__help__subcmd__auth,status)
                cmd="rev__stealth__subcmd__help__subcmd__auth__subcmd__status"
                ;;
            rev__stealth__subcmd__help__subcmd__browser,launch)
                cmd="rev__stealth__subcmd__help__subcmd__browser__subcmd__launch"
                ;;
            rev__stealth__subcmd__help__subcmd__browser,stealth-test)
                cmd="rev__stealth__subcmd__help__subcmd__browser__subcmd__stealth__subcmd__test"
                ;;
            rev__stealth__subcmd__help__subcmd__captcha,solve)
                cmd="rev__stealth__subcmd__help__subcmd__captcha__subcmd__solve"
                ;;
            rev__stealth__subcmd__help__subcmd__captcha,verify)
                cmd="rev__stealth__subcmd__help__subcmd__captcha__subcmd__verify"
                ;;
            rev__stealth__subcmd__help__subcmd__config,diff)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__diff"
                ;;
            rev__stealth__subcmd__help__subcmd__config,edit)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__edit"
                ;;
            rev__stealth__subcmd__help__subcmd__config,gc)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__gc"
                ;;
            rev__stealth__subcmd__help__subcmd__config,get)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__get"
                ;;
            rev__stealth__subcmd__help__subcmd__config,history)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__history"
                ;;
            rev__stealth__subcmd__help__subcmd__config,init)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__init"
                ;;
            rev__stealth__subcmd__help__subcmd__config,migrate)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__migrate"
                ;;
            rev__stealth__subcmd__help__subcmd__config,paths)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__paths"
                ;;
            rev__stealth__subcmd__help__subcmd__config,profile)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__profile"
                ;;
            rev__stealth__subcmd__help__subcmd__config,rollback)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__rollback"
                ;;
            rev__stealth__subcmd__help__subcmd__config,set)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__set"
                ;;
            rev__stealth__subcmd__help__subcmd__config,show)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__show"
                ;;
            rev__stealth__subcmd__help__subcmd__config,validate)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__validate"
                ;;
            rev__stealth__subcmd__help__subcmd__config__subcmd__profile,create)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__create"
                ;;
            rev__stealth__subcmd__help__subcmd__config__subcmd__profile,delete)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__delete"
                ;;
            rev__stealth__subcmd__help__subcmd__config__subcmd__profile,list)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__list"
                ;;
            rev__stealth__subcmd__help__subcmd__config__subcmd__profile,switch)
                cmd="rev__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__switch"
                ;;
            rev__stealth__subcmd__help__subcmd__hermes,install)
                cmd="rev__stealth__subcmd__help__subcmd__hermes__subcmd__install"
                ;;
            rev__stealth__subcmd__help__subcmd__hermes,uninstall)
                cmd="rev__stealth__subcmd__help__subcmd__hermes__subcmd__uninstall"
                ;;
            rev__stealth__subcmd__help__subcmd__hermes,verify)
                cmd="rev__stealth__subcmd__help__subcmd__hermes__subcmd__verify"
                ;;
            rev__stealth__subcmd__help__subcmd__vpn,rotate)
                cmd="rev__stealth__subcmd__help__subcmd__vpn__subcmd__rotate"
                ;;
            rev__stealth__subcmd__help__subcmd__vpn,status)
                cmd="rev__stealth__subcmd__help__subcmd__vpn__subcmd__status"
                ;;
            rev__stealth__subcmd__hermes,help)
                cmd="rev__stealth__subcmd__hermes__subcmd__help"
                ;;
            rev__stealth__subcmd__hermes,install)
                cmd="rev__stealth__subcmd__hermes__subcmd__install"
                ;;
            rev__stealth__subcmd__hermes,uninstall)
                cmd="rev__stealth__subcmd__hermes__subcmd__uninstall"
                ;;
            rev__stealth__subcmd__hermes,verify)
                cmd="rev__stealth__subcmd__hermes__subcmd__verify"
                ;;
            rev__stealth__subcmd__hermes__subcmd__help,help)
                cmd="rev__stealth__subcmd__hermes__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__hermes__subcmd__help,install)
                cmd="rev__stealth__subcmd__hermes__subcmd__help__subcmd__install"
                ;;
            rev__stealth__subcmd__hermes__subcmd__help,uninstall)
                cmd="rev__stealth__subcmd__hermes__subcmd__help__subcmd__uninstall"
                ;;
            rev__stealth__subcmd__hermes__subcmd__help,verify)
                cmd="rev__stealth__subcmd__hermes__subcmd__help__subcmd__verify"
                ;;
            rev__stealth__subcmd__vpn,help)
                cmd="rev__stealth__subcmd__vpn__subcmd__help"
                ;;
            rev__stealth__subcmd__vpn,rotate)
                cmd="rev__stealth__subcmd__vpn__subcmd__rotate"
                ;;
            rev__stealth__subcmd__vpn,status)
                cmd="rev__stealth__subcmd__vpn__subcmd__status"
                ;;
            rev__stealth__subcmd__vpn__subcmd__help,help)
                cmd="rev__stealth__subcmd__vpn__subcmd__help__subcmd__help"
                ;;
            rev__stealth__subcmd__vpn__subcmd__help,rotate)
                cmd="rev__stealth__subcmd__vpn__subcmd__help__subcmd__rotate"
                ;;
            rev__stealth__subcmd__vpn__subcmd__help,status)
                cmd="rev__stealth__subcmd__vpn__subcmd__help__subcmd__status"
                ;;
            *)
                ;;
        esac
    done

    case "${cmd}" in
        rev__stealth)
            opts="-v -h -V --format --verbose --help --version captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 1 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth)
            opts="-v -h --output-format --format --verbose --help login list show delete status refresh help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__delete)
            opts="-v -h --profile --force --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help)
            opts="login list show delete status refresh help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__delete)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__list)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__login)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__refresh)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__show)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__help__subcmd__status)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__list)
            opts="-v -h --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__login)
            opts="-v -h --profile --url --domain --completion-pattern --obscura-bin --rev-auth-bin --aad-context --require-vpn --allow-no-vpn --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --domain)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --completion-pattern)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --obscura-bin)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --rev-auth-bin)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --aad-context)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__refresh)
            opts="-v -h --profile --url --domain --completion-pattern --obscura-bin --rev-auth-bin --aad-context --require-vpn --allow-no-vpn --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --domain)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --completion-pattern)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --obscura-bin)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --rev-auth-bin)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --aad-context)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__show)
            opts="-v -h --profile --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__auth__subcmd__status)
            opts="-v -h --profile --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser)
            opts="-v -h --output-format --format --verbose --help launch stealth-test help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser__subcmd__help)
            opts="launch stealth-test help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser__subcmd__help__subcmd__launch)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser__subcmd__help__subcmd__stealth__subcmd__test)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser__subcmd__launch)
            opts="-v -h --profile --stealth --url --headed --chrome --dwell --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --stealth)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --chrome)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --dwell)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__browser__subcmd__stealth__subcmd__test)
            opts="-v -h --target --profile --stealth --dwell --headed --chrome --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --target)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --profile)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --stealth)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --dwell)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --chrome)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha)
            opts="-v -h --output-format --format --verbose --help solve verify help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha__subcmd__help)
            opts="solve verify help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha__subcmd__help__subcmd__solve)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha__subcmd__help__subcmd__verify)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha__subcmd__solve)
            opts="-v -h --type --site-url --site-key --action --dry-run --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --type)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --site-url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --site-key)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --action)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__captcha__subcmd__verify)
            opts="-v -h --type --token --secret --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --type)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --token)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --secret)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__cf__subcmd__evaluate)
            opts="-v -h --output-format --url --session-id --i-have-authorization --obscura --require-vpn --allow-no-vpn --vpn-instance --proxy-tier --no-fallback --leak-poll-secs --use-auth --auth-domain --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --session-id)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --obscura)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --vpn-instance)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --proxy-tier)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --leak-poll-secs)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --use-auth)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --auth-domain)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config)
            opts="-v -h --output-format --format --verbose --help show paths validate diff get set edit migrate init history rollback gc profile help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "text json yaml" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__diff)
            opts="-v -h --against --format --verbose --help <PATH>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --against)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__edit)
            opts="-v -h --target --editor --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --target)
                    COMPREPLY=($(compgen -W "policy authorized" -- "${cur}"))
                    return 0
                    ;;
                --editor)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__gc)
            opts="-v -h --keep --target --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --keep)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --target)
                    COMPREPLY=($(compgen -W "policy authorized" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__get)
            opts="-v -h --format --verbose --help <KEY>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help)
            opts="show paths validate diff get set edit migrate init history rollback gc profile help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__diff)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__edit)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__gc)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__get)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__history)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__init)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__migrate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__paths)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__profile)
            opts="list create switch delete"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__create)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__delete)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__list)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__profile__subcmd__switch)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__rollback)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__set)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__show)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__help__subcmd__validate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__history)
            opts="-v -h --target --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --target)
                    COMPREPLY=($(compgen -W "policy authorized" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__init)
            opts="-v -h --target --force --non-interactive --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --target)
                    COMPREPLY=($(compgen -W "all policy authorized sites" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__migrate)
            opts="-v -h --dry-run --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__paths)
            opts="-v -h --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile)
            opts="-v -h --format --verbose --help list create switch delete help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__create)
            opts="-v -h --format --verbose --help <NAME>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__delete)
            opts="-v -h --yes --format --verbose --help <NAME>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__help)
            opts="list create switch delete help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__create)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__delete)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__list)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__help__subcmd__switch)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__list)
            opts="-v -h --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__profile__subcmd__switch)
            opts="-v -h --format --verbose --help <NAME>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__rollback)
            opts="-v -h --target --format --verbose --help <BAK_NAME>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --target)
                    COMPREPLY=($(compgen -W "policy authorized" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__set)
            opts="-v -h --target --format --verbose --help <KEY> <VALUE>"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --target)
                    COMPREPLY=($(compgen -W "policy authorized" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__show)
            opts="-v -h --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__config__subcmd__validate)
            opts="-v -h --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__doctor)
            opts="-v -h --container --expected-country --output-format --skip-exit-ip --deep --vps --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --container)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --expected-country)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --output-format)
                    COMPREPLY=($(compgen -W "json text" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help)
            opts="captcha browser vpn doctor spider relocate cf-evaluate auth measure config hermes help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth)
            opts="login list show delete status refresh"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth__subcmd__delete)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth__subcmd__list)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth__subcmd__login)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth__subcmd__refresh)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth__subcmd__show)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__auth__subcmd__status)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__browser)
            opts="launch stealth-test"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__browser__subcmd__launch)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__browser__subcmd__stealth__subcmd__test)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__captcha)
            opts="solve verify"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__captcha__subcmd__solve)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__captcha__subcmd__verify)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__cf__subcmd__evaluate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config)
            opts="show paths validate diff get set edit migrate init history rollback gc profile"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__diff)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__edit)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__gc)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__get)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__history)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__init)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__migrate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__paths)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__profile)
            opts="list create switch delete"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__create)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__delete)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__list)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__profile__subcmd__switch)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 5 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__rollback)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__set)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__show)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__config__subcmd__validate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__doctor)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__hermes)
            opts="install uninstall verify"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__hermes__subcmd__install)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__hermes__subcmd__uninstall)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__hermes__subcmd__verify)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__measure)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__relocate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__spider)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__vpn)
            opts="rotate status"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__vpn__subcmd__rotate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__help__subcmd__vpn__subcmd__status)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes)
            opts="-v -h --output-format --format --verbose --help install uninstall verify help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__help)
            opts="install uninstall verify help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__help__subcmd__install)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__help__subcmd__uninstall)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__help__subcmd__verify)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__install)
            opts="-v -h --prefix --source --force --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --prefix)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --source)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__uninstall)
            opts="-v -h --prefix --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --prefix)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__hermes__subcmd__verify)
            opts="-v -h --prefix --skip-python-check --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --prefix)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__measure)
            opts="-v -h --output-format --url --enable-external --enable-egress-probe --user-agent --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --user-agent)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__relocate)
            opts="-v -h --output-format --session-id --stable-id --html-file --url --threshold --parse-store --strict --i-have-authorization --require-vpn --allow-no-vpn --vpn-instance --proxy-tier --no-fallback --use-auth --auth-domain --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --session-id)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --stable-id)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --html-file)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --threshold)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --parse-store)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --vpn-instance)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --proxy-tier)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --use-auth)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --auth-domain)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__spider)
            opts="-v -h --output-format --url --session-id --mobile-preset --cf-evaluate --vpn --stable-id --threshold --strict --i-have-authorization --obscura --parse-store --use-auth --auth-domain --http-only --auto-fallback --no-auto-fallback --dump-html --wait-ms --wait-selector --require-vpn --allow-no-vpn --vpn-instance --proxy-tier --no-fallback --leak-poll-secs --no-cache --cache-refresh --cache-only --cache-ttl --recipe-dir --recipe-endpoint --recipe-param --recipe-no-learn --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --url)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --session-id)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --mobile-preset)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --stable-id)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --threshold)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --obscura)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --parse-store)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --use-auth)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --auth-domain)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --dump-html)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --wait-ms)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --wait-selector)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --vpn-instance)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --proxy-tier)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --leak-poll-secs)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --cache-ttl)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --recipe-dir)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --recipe-endpoint)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --recipe-param)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn)
            opts="-v -h --output-format --format --verbose --help rotate status help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 2 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --output-format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn__subcmd__help)
            opts="rotate status help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn__subcmd__help__subcmd__help)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn__subcmd__help__subcmd__rotate)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn__subcmd__help__subcmd__status)
            opts=""
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 4 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn__subcmd__rotate)
            opts="-v -h --provider --strategy --region --reason --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --provider)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --strategy)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --region)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --reason)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
        rev__subcmd__stealth__subcmd__vpn__subcmd__status)
            opts="-v -h --provider --format --verbose --help"
            if [[ ${cur} == -* || ${COMP_CWORD} -eq 3 ]] ; then
                COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
                return 0
            fi
            case "${prev}" in
                --provider)
                    COMPREPLY=($(compgen -f "${cur}"))
                    return 0
                    ;;
                --format)
                    COMPREPLY=($(compgen -W "human json" -- "${cur}"))
                    return 0
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
            return 0
            ;;
    esac
}

if [[ "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 || "${BASH_VERSINFO[0]}" -gt 4 ]]; then
    complete -F _rev-stealth -o nosort -o bashdefault -o default rev-stealth
else
    complete -F _rev-stealth -o bashdefault -o default rev-stealth
fi

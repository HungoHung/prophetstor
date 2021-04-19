#!/usr/bin/env bash
set -o pipefail

#=========================== target config info start =========================
target_config_info='{
  "rest_api_full_path": "https://172.31.2.41:31011",
  "login_account": "",
  "login_password": "",
  "access_token": "",
  "resource_type": "controller", # controller or namespace
  "iac_command": "script", # script or terraform
  "kubeconfig_path": "", # optional # kubeconfig file path
  "planning_target":
    {
      "cluster_name": "hungo-17-135",
      "namespace": "cassandra",
      "time_interval": "daily", # daily, weekly, or monthly
      "resource_name": "cassandra",
      "kind": "StatefulSet", # StatefulSet, Deployment, DeploymentConfig
      "min_cpu": "100", # optional # mCore
      "max_cpu": "5000", # optional # mCore
      "cpu_headroom": "100", # optional # Absolute value (mCore) e.g. 1000 or Percentage e.g. 20% 
      "min_memory": "10000000", # optional # byte
      "max_memory": "18049217913", # optional # byte
      "memory_headroom": "27%" # optional # Absolute value (byte) e.g. 209715200 or Percentage e.g. 20%
    }
}'
#=========================== target config info end ===========================

check_target_config()
{
    if [ -z "$target_config_info" ]; then
        echo -e "\n$(tput setaf 1)Error! target config info is empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    else
        echo "-------------- config info ----------------" >> $debug_log
        # Hide password
        echo "$target_config_info" |sed 's/"login_password.*/"login_password": *****/g'|sed 's/"access_token":.*/"access_token": *****/g' >> $debug_log
        echo "-----------------------------------------------------" >> $debug_log
    fi
}

show_usage()
{
    cat << __EOF__

    Usage:
        $(tput setaf 2)Requirement:$(tput sgr 0)
            Modify "target_config_info" variable at the beginning of this script to specify target's info
        $(tput setaf 2)Run the script:$(tput sgr 0)
            [tt@t ~]$$ bash planning-util.sh
        $(tput setaf 2)Standalone options:$(tput sgr 0)
            --test-connection-only
            --dry-run-only
            --verbose
            --log-name [<path>/]<log filename> [e.g., $(tput setaf 6)--log-name mycluster.log$(tput sgr 0)]
__EOF__
}

show_info()
{
    if [ "$verbose_mode" = "y" ]; then
        tee -a $debug_log  << __EOF__
$*
__EOF__
    else
        echo "$*" >> $debug_log
    fi
    return 0
}

log_prompt()
{
    if [ "$debug_log" != "/dev/null" ]; then
        echo -e "\n$(tput setaf 6)Please refer to the logfile $debug_log for details. $(tput sgr 0)"
    fi
}

check_user_token()
{
    if [ "$access_token" = "null" ] || [ "$access_token" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get login token from REST API.$(tput sgr 0)" | tee -a $debug_log 1>&2
        echo "Please check login account and login password." | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi
}

parse_value_from_target_var()
{
    target_string="$1"
    if [ -z "$target_string" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_target_var() target_string parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi
    echo "$target_config_info"|tr -d '\n'|grep -o "\"$target_string\":[^\"]*\"[^\"]*\""|sed -E 's/".*".*"(.*)"/\1/'
}

check_rest_api_url()
{
    show_info "$(tput setaf 6)Getting REST API URL...$(tput sgr 0)" 
    api_url=$(parse_value_from_target_var "rest_api_full_path")

    if [ "$api_url" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get REST API URL from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi
    show_info "REST API URL = $api_url"
    show_info "Done."
}

rest_api_login()
{
    show_info "$(tput setaf 6)Logging into REST API...$(tput sgr 0)"
    provided_token=$(parse_value_from_target_var "access_token")
    if [ "$provided_token" = "" ]; then
        login_account=$(parse_value_from_target_var "login_account")
        if [ "$login_account" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get login account from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
        login_password=$(parse_value_from_target_var "login_password")
        if [ "$login_password" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get login password from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
        auth_string="${login_account}:${login_password}"
        auth_cipher=$(echo -n "$auth_string"|base64)
        if [ "$auth_cipher" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to generate base64 output of login string.$(tput sgr 0)"  | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
        rest_output=$(curl -sS -k -X POST "$api_url/apis/v1/users/login" -H "accept: application/json" -H "authorization: Basic ${auth_cipher}")
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to connect to REST API service ($api_url/apis/v1/users/login).$(tput sgr 0)" | tee -a $debug_log 1>&2
            echo "Please check REST API IP" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
        access_token="$(echo $rest_output|tr -d '\n'|grep -o "\"accessToken\":[^\"]*\"[^\"]*\""|sed -E 's/".*".*"(.*)"/\1/')"
    else
        access_token="$provided_token"
        # Examine http response code
        token_test_http_response="$(curl -o /dev/null -sS -k -X GET "$api_url/apis/v1/resources/clusters" -w "%{http_code}" -H "accept: application/json" -H "Authorization: Bearer $access_token")"
        if [ "$token_test_http_response" != "200" ]; then
            echo -e "\n$(tput setaf 1)Error! The access_token from target_config_info can't access the REST API service.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
    fi

    check_user_token

    show_info "Done."
}

rest_api_check_cluster_name()
{
    show_info "$(tput setaf 6)Getting the cluster name of the planning target ...$(tput sgr 0)"
    cluster_name=$(parse_value_from_target_var "cluster_name")
    if [ "$cluster_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get cluster name of the planning target from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    rest_cluster_output="$(curl -sS -k -X GET "$api_url/apis/v1/resources/clusters" -H "accept: application/json" -H "Authorization: Bearer $access_token" |tr -d '\n'|grep -o "\"data\":\[{[^}]*}"|grep -o "\"name\":[^\"]*\"[^\"]*\"")"
    echo "$rest_cluster_output"|grep -q "$cluster_name"
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! The cluster name is not found in REST API return.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    show_info "cluster_name = $cluster_name"
    show_info "Done."
}

get_info_from_config()
{
    show_info "$(tput setaf 6)Getting the $resource_type info of the planning target...$(tput sgr 0)"

    resource_name=$(parse_value_from_target_var "resource_name")
    if [ "$resource_name" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get resource name of the planning target from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    if [ "$resource_type" = "controller" ]; then
        owner_reference_kind=$(parse_value_from_target_var "kind")
        if [ "$owner_reference_kind" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get controller kind of the planning target from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi

        owner_reference_kind="$(echo "$owner_reference_kind" | tr '[:upper:]' '[:lower:]')"
        if [ "$owner_reference_kind" = "statefulset" ] && [ "$owner_reference_kind" = "deployment" ] && [ "$owner_reference_kind" = "deploymentconfig" ]; then
            echo -e "\n$(tput setaf 1)Error! Only support controller type equals Statefulset/Deployment/DeploymentConfig.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi

        target_namespace=$(parse_value_from_target_var "namespace")
        if [ "$target_namespace" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get namespace of the planning target from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
    else
        # resource_type = namespace
        # target_namespace is resource_name
        target_namespace=$resource_name
    fi

    readable_granularity=$(parse_value_from_target_var "time_interval")
    if [ "$readable_granularity" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get time interval of the planning target from target_config_info.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    min_cpu=$(parse_value_from_target_var "min_cpu")
    max_cpu=$(parse_value_from_target_var "max_cpu")
    cpu_headroom=$(parse_value_from_target_var "cpu_headroom")
    min_memory=$(parse_value_from_target_var "min_memory")
    max_memory=$(parse_value_from_target_var "max_memory")
    memory_headroom=$(parse_value_from_target_var "memory_headroom")

    if [[ ! $min_cpu =~ ^[0-9]+$ ]]; then min_cpu=""; fi
    if [[ ! $max_cpu =~ ^[0-9]+$ ]]; then max_cpu=""; fi
    if [[ $cpu_headroom =~ ^[0-9]+[%]$ ]]; then
        # Percentage mode
        cpu_headroom_mode="%"
        # Remove last character as value
        cpu_headroom=`echo ${cpu_headroom::-1}`
    elif [[ $cpu_headroom =~ ^[0-9]+$ ]]; then
        # Absolute value (mCore) mode
        cpu_headroom_mode="m"
    else
        # No valid value or mode, set inactive value and mode
        cpu_headroom="0"
        cpu_headroom_mode="m"
    fi
    if [[ ! $min_memory =~ ^[0-9]+$ ]]; then min_memory=""; fi
    if [[ ! $max_memory =~ ^[0-9]+$ ]]; then max_memory=""; fi
    if [[ $memory_headroom =~ ^[0-9]+[%]$ ]]; then
        # Percentage mode
        memory_headroom_mode="%"
        # Remove last character as value
        memory_headroom=`echo ${memory_headroom::-1}`
    elif [[ $memory_headroom =~ ^[0-9]+$ ]]; then
        # Absolute value (byte) mode
        memory_headroom_mode="b"
    else
        # No valid value, set inactive value and mode
        memory_headroom="0"
        memory_headroom_mode="b"
    fi

    if [ "$readable_granularity" = "daily" ]; then
        granularity="3600"
    elif [ "$readable_granularity" = "weekly" ]; then
        granularity="21600"
    elif [ "$readable_granularity" = "monthly" ]; then
        granularity="86400"
    else
        echo -e "\n$(tput setaf 1)Error! Only support planning time interval equals daily/weekly/monthly.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    show_info "Cluster name = $cluster_name"
    show_info "Resource type = $resource_type"
    show_info "Resource name = $resource_name"
    if [ "$resource_type" = "controller" ]; then
        show_info "Kind = $owner_reference_kind"
        show_info "Namespace = $target_namespace"
    fi
    show_info "Time interval = $readable_granularity"
    show_info "min_cpu = $min_cpu"
    show_info "max_cpu = $max_cpu"
    show_info "cpu_headroom = $cpu_headroom"
    show_info "cpu_headroom_mode = $cpu_headroom_mode"
    show_info "min_memory = $min_memory"
    show_info "max_memory = $max_memory"
    show_info "memory_headroom = $memory_headroom"
    show_info "memory_headroom_mode = $memory_headroom_mode"
    show_info "Done."
}

parse_value_from_planning()
{
    target_field="$1"
    target_resource="$2"
    if [ -z "$target_field" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_planning() target_field parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    elif [ -z "$target_resource" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_planning() target_resource parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    if [ "$target_field" != "limitPlannings" ] && [ "$target_field" != "requestPlannings" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_planning() target_field can only be either 'limitPlannings' and 'requestPlannings'.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    if [ "$target_resource" != "CPU_MILLICORES_USAGE" ] && [ "$target_resource" != "MEMORY_BYTES_USAGE" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_planning() target_field can only be either 'CPU_MILLICORES_USAGE' and 'MEMORY_BYTES_USAGE'.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    echo "$planning_all"|grep -o "\"$target_field\":[^{]*{[^}]*}[^}]*}"|grep -o "\"$target_resource\":[^\[]*\[[^]]*"|grep -o '"numValue":[^"]*"[^"]*"'|cut -d '"' -f4
}

get_planning_from_api()
{
    show_info "$(tput setaf 6)Getting planning values for the $resource_type through REST API...$(tput sgr 0)"
    show_info "Cluster name = $cluster_name"
    if [ "$resource_type" = "controller" ]; then
        show_info "Kind = $owner_reference_kind"
        show_info "Namespace = $target_namespace"
    else
        # namespace
        show_info "Namespace = $target_namespace"
    fi
    show_info "Resource name = $resource_name"
    show_info "Time interval = $readable_granularity"

    # Use 0 as 'now'
    interval_start_time="0"
    interval_end_time=$(($interval_start_time + $granularity - 1))

    show_info "Query interval (start) = 0"
    show_info "Query interval (end) = $interval_end_time"

    # Use planning here
    type="planning"
    if [ "$resource_type" = "controller" ]; then
        query_type="${owner_reference_kind}s"
        exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace/$query_type/${resource_name}?granularity=$granularity&type=$type&limit=1&order=asc&startTime=$interval_start_time&endTime=$interval_end_time\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
    else
        # resource_type = namespace
        # Check if namespace is in monitoring state first
        exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/resources/clusters/$cluster_name/namespaces?names=$target_namespace\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
        rest_output=$(eval $exec_cmd)
        if [ "$?" != "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get namespace $target_namespace resource info using REST API (Command: $exec_cmd)$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
        namespace_state="$(echo $rest_output|tr -d '\n'|grep -o "\"name\":.*\"${target_namespace}.*"|grep -o "\"state\":.*\".*\""|cut -d '"' -f4)"
        if [ "$namespace_state" != "monitoring" ]; then
            echo -e "\n$(tput setaf 1)Error! Namespace $target_namespace state is not 'monitoring' (REST API output: $rest_output)$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi
        exec_cmd="curl -sS -k -X GET \"$api_url/apis/v1/plannings/clusters/$cluster_name/namespaces/$target_namespace?granularity=$granularity&type=$type&limit=1&order=asc&startTime=$interval_start_time&endTime=$interval_end_time\" -H \"accept: application/json\" -H \"Authorization: Bearer $access_token\""
    fi

    rest_output=$(eval $exec_cmd)
    if [ "$?" != "0" ]; then
        echo -e "\n$(tput setaf 1)Error! Failed to get planning value of $resource_type using REST API (Command: $exec_cmd)$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi
    planning_all="$(echo $rest_output|tr -d '\n'|grep -o "\"plannings\":.*")"
    if [ "$planning_all" = "" ]; then
        echo -e "\n$(tput setaf 1)REST API output:$(tput sgr 0)" | tee -a $debug_log 1>&2
        echo -e "${rest_output}" | tee -a $debug_log 1>&2
        echo -e "\n$(tput setaf 1)Error! Planning value is empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    limits_pod_cpu=$(parse_value_from_planning "limitPlannings" "CPU_MILLICORES_USAGE")
    requests_pod_cpu=$(parse_value_from_planning "requestPlannings" "CPU_MILLICORES_USAGE")
    limits_pod_memory=$(parse_value_from_planning "limitPlannings" "MEMORY_BYTES_USAGE")
    requests_pod_memory=$(parse_value_from_planning "requestPlannings" "MEMORY_BYTES_USAGE")

    if [ "$resource_type" = "controller" ]; then
        replica_number="$($kube_cmd get $owner_reference_kind $resource_name -n $target_namespace -o json|tr -d '\n'|grep -o "\"spec\":.*"|grep -o "\"replicas\":[^,]*[0-9]*"|head -1|cut -d ':' -f2|xargs)"

        if [ "$replica_number" = "" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get replica number from controller ($resource_name) in ns $target_namespace$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi

        case $replica_number in
            ''|*[!0-9]*) echo -e "\n$(tput setaf 1)Error! replica number needs to be an integer.$(tput sgr 0)" | tee -a $debug_log 1>&2 && exit 3 ;;
            *) ;;
        esac

        show_info "Controller replica number = $replica_number"
        if [ "$replica_number" = "0" ]; then
            echo -e "\n$(tput setaf 1)Error! Replica number is zero.$(tput sgr 0)" | tee -a $debug_log 1>&2
            log_prompt
            exit 8
        fi

        # Round up the result (planning / replica)
        limits_pod_cpu=$(( ($limits_pod_cpu + $replica_number - 1)/$replica_number ))
        requests_pod_cpu=$(( ($requests_pod_cpu + $replica_number - 1)/$replica_number ))
        limits_pod_memory=$(( ($limits_pod_memory + $replica_number - 1)/$replica_number ))
        requests_pod_memory=$(( ($requests_pod_memory + $replica_number - 1)/$replica_number ))
    fi

    show_info "-------------- Planning for $resource_type --------------"
    show_info "$(tput setaf 2)resources.limits.cpu $(tput sgr 0)= $(tput setaf 3)$limits_pod_cpu(m)$(tput sgr 0)"
    show_info "$(tput setaf 2)resources.limits.momory $(tput sgr 0)= $(tput setaf 3)$limits_pod_memory(byte)$(tput sgr 0)"
    show_info "$(tput setaf 2)resources.requests.cpu $(tput sgr 0)= $(tput setaf 3)$requests_pod_cpu(m)$(tput sgr 0)"
    show_info "$(tput setaf 2)resources.requests.memory $(tput sgr 0)= $(tput setaf 3)$requests_pod_memory(byte)$(tput sgr 0)"
    show_info "-----------------------------------------------------"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        if [ "$resource_type" = "controller" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to get controller ($resource_name) planning. Missing value.$(tput sgr 0)" | tee -a $debug_log 1>&2
        else
            # namespace
            echo -e "\n$(tput setaf 1)Error! Failed to get namespace ($target_namespace) planning. Missing value.$(tput sgr 0)" | tee -a $debug_log 1>&2
        fi
        log_prompt
        exit 8
    fi

    show_info "Done."
}

apply_min_max_margin()
{
    planning_name="$1"
    mode_name="$2"
    headroom_name="$3"
    min_name="$4"
    max_name="$5"
    original_value="${!planning_name}"

    if [ "${!mode_name}" = "%" ]; then
        # Percentage mode
        export $planning_name=$(( (${!planning_name}*(100+${!headroom_name})+99)/100 ))
    else
        # Absolute value mode
        export $planning_name=$(( ${!planning_name} + ${!headroom_name} ))
    fi
    if [ "${!min_name}" != "" ] && [ "${!min_name}" -gt "${!planning_name}" ]; then
        # Assign minimum value
        export $planning_name="${!min_name}"
    fi
    if [ "${!max_name}" != "" ] && [ "${!planning_name}" -gt "${!max_name}" ]; then
        # Assign maximum value
        export $planning_name="${!max_name}"
    fi

    show_info "-------------- Caculate min/max/headroom --------------"
    show_info "${mode_name} = ${!mode_name}"
    show_info "${headroom_name} = ${!headroom_name}"
    show_info "${min_name} = ${!min_name}"
    show_info "${max_name} = ${!max_name}"
    show_info "${planning_name} (before)= ${original_value}"
    show_info "${planning_name} (after)= ${!planning_name}"
    show_info "-----------------------------------------------------"

}

check_default_value_satified()
{
    empty_mode="x"
    empty_name="0"
    apply_min_max_margin "requests_pod_cpu" "empty_mode" "empty_name" "default_min_cpu" "notexit"
    apply_min_max_margin "requests_pod_memory" "empty_mode" "empty_name" "default_min_memory" "notexit"
    apply_min_max_margin "limits_pod_cpu" "empty_mode" "empty_name" "default_min_cpu" "notexit"
    apply_min_max_margin "limits_pod_memory" "empty_mode" "empty_name" "default_min_memory" "notexit"
}

update_target_resources()
{
    mode=$1
    if [ "$mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! update_target_resources() mode parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    show_info "$(tput setaf 6)Updateing $resource_type resources...$(tput sgr 0)"

    if [ "$limits_pod_cpu" = "" ] || [ "$requests_pod_cpu" = "" ] || [ "$limits_pod_memory" = "" ] || [ "$requests_pod_memory" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! Missing planning values.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 8
    fi

    apply_min_max_margin "requests_pod_cpu" "cpu_headroom_mode" "cpu_headroom" "min_cpu" "max_cpu"
    apply_min_max_margin "requests_pod_memory" "memory_headroom_mode" "memory_headroom" "min_memory" "max_memory"
    apply_min_max_margin "limits_pod_cpu" "cpu_headroom_mode" "cpu_headroom" "min_cpu" "max_cpu"
    apply_min_max_margin "limits_pod_memory" "memory_headroom_mode" "memory_headroom" "min_memory" "max_memory"

    # Make sure default cpu & memory value above existing one
    check_default_value_satified

    if [ "$resource_type" = "controller" ]; then
        exec_cmd="$kube_cmd -n $target_namespace set resources $owner_reference_kind $resource_name --limits cpu=${limits_pod_cpu}m,memory=${limits_pod_memory} --requests cpu=${requests_pod_cpu}m,memory=${requests_pod_memory}"
    else
        quota_name="${target_namespace}.federator.ai"
        exec_cmd="$kube_cmd -n $target_namespace create quota $quota_name --hard=limits.cpu=${limits_pod_cpu}m,limits.memory=${limits_pod_memory},requests.cpu=${requests_pod_cpu}m,requests.memory=${requests_pod_memory}"
    fi

    show_info "$(tput setaf 3)Issuing cmd:$(tput sgr 0)"
    show_info "$(tput setaf 2)$exec_cmd$(tput sgr 0)"
    if [ "$mode" = "dry_run" ]; then
        execution_time="N/A, skip due to dry run is enabled."
        show_info "$(tput setaf 3)Dry run is enabled, skip execution.$(tput sgr 0)"
        show_info "Done. Dry run is done."
        return
    fi

    execution_time="$(date -u)"
    if [ "$resource_type" = "namespace" ]; then
        # Clean other quotas
        all_quotas=$(kubectl -n $target_namespace get quota -o name|cut -d '/' -f2)
        for quota in $(echo "$all_quotas")
        do
            $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/limits.cpu\"}]" >/dev/null 2>&1
            $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/limits.memory\"}]" >/dev/null 2>&1
            $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/requests.cpu\"}]" >/dev/null 2>&1
            $kube_cmd -n $target_namespace patch quota $quota --type json --patch "[ { \"op\" : \"remove\" , \"path\" : \"/spec/hard/requests.memory\"}]" >/dev/null 2>&1
        done
        # Delete previous federator.ai quotas
        $kube_cmd -n $target_namespace delete quota $quota_name > /dev/null 2>&1
    fi

    eval $exec_cmd 3>&1 1>&2 2>&3 1>>$debug_log | tee -a $debug_log
    if [ "${PIPESTATUS[0]}" != "0" ]; then
        if [ "$resource_type" = "controller" ]; then
            echo -e "\n$(tput setaf 1)Error! Failed to update resources for $owner_reference_kind $resource_name$(tput sgr 0)" | tee -a $debug_log 1>&2
        else
            echo -e "\n$(tput setaf 1)Error! Failed to update quota for namespace $target_namespace$(tput sgr 0)" | tee -a $debug_log 1>&2
        fi
        log_prompt
        exit 8
    fi

    show_info "Done"
}

parse_value_from_resource()
{
    target_field="$1"
    target_resource="$2"
    if [ -z "$target_field" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_resource() target_field parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    elif [ -z "$target_resource" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_resource() target_resource parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    if [ "$target_field" != "limits" ] && [ "$target_field" != "requests" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_resource() target_field can only be either 'limits' and 'requests'.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    if [ "$target_resource" != "cpu" ] && [ "$target_resource" != "memory" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_resource() target_field can only be either 'cpu' and 'memory'.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    echo "$resources"|grep -o "\"$target_field\":[^{]*{[^}]*}"|grep -o "\"$target_resource\":[^\"]*\"[^\"]*\""|cut -d '"' -f4
}

parse_value_from_quota()
{
    target_field="$1"
    target_resource="$2"
    if [ -z "$target_field" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_quota() target_field parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    elif [ -z "$target_resource" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_quota() target_resource parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    if [ "$target_field" != "limits" ] && [ "$target_field" != "requests" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_quota() target_field can only be either 'limits' and 'requests'.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    if [ "$target_resource" != "cpu" ] && [ "$target_resource" != "memory" ]; then
        echo -e "\n$(tput setaf 1)Error! parse_value_from_quota() target_field can only be either 'cpu' and 'memory'.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    echo "$resources"|grep -o "\"$target_field.$target_resource\":[^\"]*\"[^\"]*\""|cut -d '"' -f4
}

get_namespace_quota_from_kubecmd()
{
    mode=$1
    if [ "$mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! get_namespace_quota_from_kubecmd() mode parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    show_info "$(tput setaf 6)Getting current namespace quota...$(tput sgr 0)"
    show_info "Namespace = $target_namespace"

    all_quotas=$(kubectl -n $target_namespace get quota -o name|cut -d '/' -f2)
    limit_cpu_list=()
    limit_memory_list=()
    request_cpu_list=()
    request_memory_list=()
    for quota in $(echo "$all_quotas")
    do
        resources=$($kube_cmd get quota $quota -n $target_namespace -o json 2>/dev/null|tr -d '\n'|grep -o "\"spec\":.*"|grep -o "\"hard\":[^}]*}"|head -1)
        limit_cpu=$(parse_value_from_quota "limits" "cpu")
        [ "$limit_cpu" != "" ] && limit_cpu_list=("${limit_cpu_list[@]}" "$limit_cpu")
        limit_memory=$(parse_value_from_quota "limits" "memory")
        [ "$limit_memory" != "" ] && limit_memory_list=("${limit_memory_list[@]}" "$limit_memory")
        request_cpu=$(parse_value_from_quota "requests" "cpu")
        [ "$request_cpu" != "" ] && request_cpu_list=("${request_cpu_list[@]}" "$request_cpu")
        request_memory=$(parse_value_from_quota "requests" "memory")
        [ "$request_memory" != "" ] && request_memory_list=("${request_memory_list[@]}" "$request_memory")
    done

    if [ "$mode" = "before" ]; then
        for item in "${limit_cpu_list[@]}"
        do
            if [ "$limit_cpu_before" = "" ]; then
                limit_cpu_before=$item
            else
                limit_cpu_before="${limit_cpu_before},$item"
            fi
        done
        for item in "${limit_memory_list[@]}"
        do
            if [ "$limit_memory_before" = "" ]; then
                limit_memory_before=$item
            else
                limit_memory_before="${limit_memory_before},$item"
            fi
        done
        for item in "${request_cpu_list[@]}"
        do
            if [ "$request_cpu_before" = "" ]; then
                request_cpu_before=$item
            else
                request_cpu_before="${request_cpu_before},$item"
            fi
        done
        for item in "${request_memory_list[@]}"
        do
            if [ "$request_memory_before" = "" ]; then
                request_memory_before=$item
            else
                request_memory_before="${request_memory_before},$item"
            fi
        done
        [ "$limit_cpu_before" = "" ] && limit_cpu_before="N/A"
        [ "$limit_memory_before" = "" ] && limit_memory_before="N/A"
        [ "$request_cpu_before" = "" ] && request_cpu_before="N/A"
        [ "$request_memory_before" = "" ] && request_memory_before="N/A"
        show_info "--------- Namespace Quota: Before execution ---------"
        show_info "$(tput setaf 3)limits:"
        show_info "  cpu: $limit_cpu_before"
        show_info "  memory: $limit_memory_before"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before"
        show_info "  memory: $request_memory_before$(tput sgr 0)"
        show_info "-----------------------------------------------------"
    else
        # mode = "after"
        if [ "$do_dry_run" = "y" ]; then
            show_info "--------------------- Dry run -----------------------"
            # dry run - set resource values from planning results to display
            limit_cpu_after="${limits_pod_cpu}m"
            limit_memory_after="$limits_pod_memory"
            request_cpu_after="${requests_pod_cpu}m"
            request_memory_after="$requests_pod_memory"
        else
            # patch is done
            for item in "${limit_cpu_list[@]}"
            do
                if [ "$limit_cpu_after" = "" ]; then
                    limit_cpu_after=$item
                else
                    limit_cpu_after="${limit_cpu_after},$item"
                fi
            done
            for item in "${limit_memory_list[@]}"
            do
                if [ "$limit_memory_after" = "" ]; then
                    limit_memory_after=$item
                else
                    limit_memory_after="${limit_memory_after},$item"
                fi
            done
            for item in "${request_cpu_list[@]}"
            do
                if [ "$request_cpu_after" = "" ]; then
                    request_cpu_after=$item
                else
                    request_cpu_after="${request_cpu_after},$item"
                fi
            done
            for item in "${request_memory_list[@]}"
            do
                if [ "$request_memory_after" = "" ]; then
                    request_memory_after=$item
                else
                    request_memory_after="${request_memory_after},$item"
                fi
            done
            [ "$limit_cpu_after" = "" ] && limit_cpu_after="N/A"
            [ "$limit_memory_after" = "" ] && limit_memory_after="N/A"
            [ "$request_cpu_after" = "" ] && request_cpu_after="N/A"
            [ "$request_memory_after" = "" ] && request_memory_after="N/A"
            show_info "--------- Namespace Quota: After execution ----------"
        fi
        show_info "$(tput setaf 3)limits:"
        show_info "  cpu: $limit_cpu_before -> $limit_cpu_after"
        show_info "  memory: $limit_memory_before -> $limit_memory_after"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before -> $request_cpu_after"
        show_info "  memory: $request_memory_before -> $request_memory_after$(tput sgr 0)"
        show_info "-----------------------------------------------------"
        echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"resource_name\": \"$target_namespace\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"$exec_cmd\",\n     \"execution_time\": \"$execution_time\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"after_execution\": {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_after\",\n       \"memory\": \"$limit_memory_after\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_after\",\n       \"memory\": \"$request_memory_after\"\n     }\n  }\n}"  | tee -a $debug_log
    fi
    show_info "Done."
}

get_controller_resources_from_kubecmd()
{
    mode=$1
    if [ "$mode" = "" ]; then
        echo -e "\n$(tput setaf 1)Error! get_controller_resources_from_kubecmd() mode parameter can't be empty.$(tput sgr 0)" | tee -a $debug_log 1>&2
        log_prompt
        exit 3
    fi

    show_info "$(tput setaf 6)Getting current controller resources...$(tput sgr 0)"
    show_info "Namespace = $target_namespace"
    show_info "Resource name = $resource_name"
    show_info "Kind = $owner_reference_kind"
    
    resources=$($kube_cmd get $owner_reference_kind $resource_name -n $target_namespace -o json |tr -d '\n'|grep -o "\"spec\":.*"|grep -o "\"template\":.*"|grep -o "\"spec\":.*"|grep -o "\"containers\":.*"|grep -o "\"resources\":.*")
    if [ "$mode" = "before" ]; then
        show_info "----------------- Before execution ------------------"
        limit_cpu_before=$(parse_value_from_resource "limits" "cpu")
        [ "$limit_cpu_before" = "" ] && limit_cpu_before="N/A"
        limit_memory_before=$(parse_value_from_resource "limits" "memory")
        [ "$limit_memory_before" = "" ] && limit_memory_before="N/A"
        request_cpu_before=$(parse_value_from_resource "requests" "cpu")
        [ "$request_cpu_before" = "" ] && request_cpu_before="N/A"
        request_memory_before=$(parse_value_from_resource "requests" "memory")
        [ "$request_memory_before" = "" ] && request_memory_before="N/A"
        show_info "$(tput setaf 3)limits:"
        show_info "  cpu: $limit_cpu_before"
        show_info "  memory: $limit_memory_before"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before"
        show_info "  memory: $request_memory_before$(tput sgr 0)"
        show_info "-----------------------------------------------------"
    else
        # mode = "after"
        if [ "$do_dry_run" = "y" ]; then
            show_info "--------------------- Dry run -----------------------"
            # dry run - set resource values from planning results to display
            limit_cpu_after="${limits_pod_cpu}m"
            limit_memory_after="$limits_pod_memory"
            request_cpu_after="${requests_pod_cpu}m"
            request_memory_after="$requests_pod_memory"
        else
            # patch is done
            show_info "------------------ After execution ------------------"
            limit_cpu_after=$(parse_value_from_resource "limits" "cpu")
            [ "$limit_cpu_after" = "" ] && limit_cpu_after="N/A"
            limit_memory_after=$(parse_value_from_resource "limits" "memory")
            [ "$limit_memory_after" = "" ] && limit_memory_after="N/A"
            request_cpu_after=$(parse_value_from_resource "requests" "cpu")
            [ "$request_cpu_after" = "" ] && request_cpu_after="N/A"
            request_memory_after=$(parse_value_from_resource "requests" "memory")
            [ "$request_memory_after" = "" ] && request_memory_after="N/A"
        fi

        show_info "$(tput setaf 3)limits:"
        show_info "  cpu: $limit_cpu_before -> $limit_cpu_after"
        show_info "  memory: $limit_memory_before -> $limit_memory_after"
        show_info "Requests:"
        show_info "  cpu: $request_cpu_before -> $request_cpu_after"
        show_info "  memory: $request_memory_before -> $request_memory_after$(tput sgr 0)"
        show_info "-----------------------------------------------------"

        echo -e "{\n  \"info\": {\n     \"cluster_name\": \"$cluster_name\",\n     \"resource_type\": \"$resource_type\",\n     \"namespace\": \"$target_namespace\",\n     \"resource_name\": \"$resource_name\",\n     \"kind\": \"$owner_reference_kind\",\n     \"time_interval\": \"$readable_granularity\",\n     \"execute_cmd\": \"$exec_cmd\",\n     \"execution_time\": \"$execution_time\"\n  },\n  \"log_file\": \"$debug_log\",\n  \"before_execution\":  {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_before\",\n       \"memory\": \"$limit_memory_before\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_before\",\n       \"memory\": \"$request_memory_before\"\n     }\n  },\n  \"after_execution\": {\n     \"limits\": {\n       \"cpu\": \"$limit_cpu_after\",\n       \"memory\": \"$limit_memory_after\"\n     },\n     \"requests\": {\n       \"cpu\": \"$request_cpu_after\",\n       \"memory\": \"$request_memory_after\"\n     }\n  }\n}"  | tee -a $debug_log
    fi
    
    show_info "Done."
}

connection_test()
{
    check_rest_api_url
    rest_api_login
}

while getopts "h-:" o; do
    case "${o}" in
        -)
            case "${OPTARG}" in
                dry-run-only)
                    do_dry_run="y"
                    ;;
                test-connection-only)
                    do_test_connection="y"
                    ;;
                verbose)
                    verbose_mode="y"
                    ;;
                log-name)
                    log_name="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
                    if [ "$log_name" = "" ]; then
                        echo -e "\n$(tput setaf 1)Error! Missing --${OPTARG} value$(tput sgr 0)"
                        show_usage
                        exit 4
                    fi
                    ;;
                help)
                    show_usage
                    exit 0
                    ;;
                *)
                    echo -e "\n$(tput setaf 1)Error! Unknown option --${OPTARG}$(tput sgr 0)"
                    show_usage
                    exit 4
                    ;;
            esac;;
        h)
            show_usage
            exit 0
            ;;
        *)
            echo -e "\n$(tput setaf 1)Error! wrong parameter.$(tput sgr 0)"
            show_usage
            exit 5
            ;;
    esac
done

if [ "$FEDERATORAI_FILE_PATH" = "" ]; then
    save_path="/opt/federatorai"
else
    save_path="$FEDERATORAI_FILE_PATH"
fi

file_folder="$save_path/auto-provisioning"


if [ "$log_name" = "" ]; then
    log_name="output.log"
    debug_log="${file_folder}/${log_name}"
else
    if [[ "$log_name" = /* ]]; then
        # Absolute path
        file_folder="$(dirname "$log_name")"
        debug_log="$log_name"
    else
        # Relative path
        file_folder="$(readlink -f "${file_folder}/$(dirname "$log_name")")"
        debug_log="${file_folder}/$(basename "$log_name")"
    fi
fi

mkdir -p $file_folder
if [ ! -d "$file_folder" ]; then
    echo -e "\n$(tput setaf 1)Error! Failed to create folder ($file_folder) to save Federator.ai planning-util files.$(tput sgr 0)"
    exit 3
fi

current_location=`pwd`
# mCore
default_min_cpu="50"
# Byte
default_min_memory="10485760"
echo "================================== New Round ======================================" >> $debug_log
echo "Receiving command: '$0 $@'" >> $debug_log
echo "Receiving time: `date -u`" >> $debug_log

type kubectl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error! \"kubectl\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log 1>&2
    log_prompt
    exit 3
fi

# Get kubeconfig path
kubeconfig_path=$(parse_value_from_target_var "kubeconfig_path")

if [ "$kubeconfig_path" = "" ]; then
    kube_cmd="kubectl"
else
    kube_cmd="kubectl --kubeconfig $kubeconfig_path"
fi

$kube_cmd version|grep -q "^Server"
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1) Error! Failed to get Kubernetes server info through kubectl cmd. Please login first or check your kubeconfig_path config value.$(tput sgr 0)" | tee -a $debug_log 1>&2
    log_prompt
    exit 3
fi

type curl > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error! \"curl\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log 1>&2
    log_prompt
    exit 3
fi

type base64 > /dev/null 2>&1
if [ "$?" != "0" ];then
    echo -e "\n$(tput setaf 1)Error! \"base64\" command is needed for this tool.$(tput sgr 0)" | tee -a $debug_log 1>&2
    log_prompt
    exit 3
fi

script_located_path=$(dirname $(readlink -f "$0"))

# Check target_config_info variable
check_target_config

connection_test
if [ "$do_test_connection" = "y" ]; then
    echo -e "\nDone. Connection test is passed." | tee -a $debug_log
    log_prompt
    exit 0
fi

rest_api_check_cluster_name

# Get resource type
resource_type=$(parse_value_from_target_var "resource_type")

if [ "$resource_type" = "controller" ];then
    get_info_from_config
    get_controller_resources_from_kubecmd "before"
    get_planning_from_api
elif [ "$resource_type" = "namespace" ]; then
    get_info_from_config
    get_namespace_quota_from_kubecmd "before"
    get_planning_from_api
else
    echo -e "\n$(tput setaf 1)Error! Only support 'mode' equals controller or namespace.$(tput sgr 0)" | tee -a $debug_log 1>&2
    log_prompt
    exit 8
fi

if [ "$do_dry_run" = "y" ]; then
    update_target_resources "dry_run"
else
    update_target_resources "normal"
fi

if [ "$resource_type" = "controller" ];then
    get_controller_resources_from_kubecmd "after"
else
    # resource_type = namespace
    get_namespace_quota_from_kubecmd "after"
fi
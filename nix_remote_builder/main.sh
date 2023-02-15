#!/usr/bin/env bash

scp_into() {
  if [ $# -lt 3 ]; then
    echo "Usage: scp_into <local_path> <server> <distant_path> <?file_owner>"
    return 1
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "Dry run mode enabled"
    mkdir -p output/$(dirname $3)
    cp $1 output/$3
  else
    # echo "Dry run mode not enabled"
    scp $1 $2:/tmp/script_paste
    rexec $2 "sudo mv /tmp/script_paste $3"
    if [ ! -z ${4} ]; then
      rexec $2 "sudo chown $4 $3"
    fi
  fi
}

load_conf() {
  if [ $# -ne 1 ]; then
    echo "Usage: load_conf <config_file>"
    return 1
  fi
  # load vars from config file
  config_file=$1
  master_ip=$(jq '.master_ip' $config_file | tr -d '"')
  runner_user=$(jq '.runner_user' $config_file | tr -d '"')
  sudoer_user=$(jq '.sudoer_user' $config_file | tr -d '"')
  master_ssh="${sudoer_user}@${master_ip}"
  master_ssh_pk_filepath=$(jq '.master_ssh_PK_filepath' $config_file | tr -d '"')
  builder_count=$(jq '.builder | length' $config_file)
  builder_names=()
  for i in $(seq 0 $(($builder_count - 1))); do
    builder_arch=$(jq -r ".builder[$i].arch" $config_file)
    builder_name=$(jq -r ".builder[$i].name" $config_file)
    builder_user=$(jq -r ".builder[$i].runner_user" $config_file)
    builder_sudoer_user=$(jq -r ".builder[$i].sudoer_user" $config_file)
    builder_ip=$(jq -r ".builder[$i].ip" $config_file)
    builder_ssh="${builder_user}@${builder_ip}"
    builder_sudoer_ssh="${builder_sudoer_user}@${builder_ip}"
    export "${builder_name//-/_}_ip"=${builder_ip}
    export "${builder_name//-/_}_user"=${builder_user}
    export "${builder_name//-/_}_arch"=${builder_arch}
    export "${builder_name//-/_}_ssh"=${builder_ssh}
    export "${builder_name//-/_}_sudoer_ssh"=${builder_sudoer_ssh}
    builder_names+=($builder_name)
  done
}
# remote execution
rexec() {
  if [ $# -ne 2 ]; then
    echo "Usage: rexec <server> \"<command>\""
    return 1
  fi
  ssh $1 $2
}

backup_file() {
  if [ $# -ne 2 ]; then
    echo "Usage: backup_file <server> <filepath>"
    return 1
  fi
  rexec $1 "sudo cp $2 $2.old"
}

merge_params() {
  declare -A params
  for param in "$@"; do
    key=$(echo $param | cut -d "=" -f 1)
    value=$(echo $param | cut -d "=" -f 2)

    if [[ -z ${params[$key]+_} ]]; then
      params[$key]="$value"
    else
      # key already exists, append value to existing array
      params[$key]="${params[$key]} $value"
    fi
  done
  result=""
  for key in "${!params[@]}"; do
    result+=" $key"
  done
  echo $result
}

merge_config_files() {
  # $1 : file conf 1
  # $2 : file conf 2
  # $3 : output file

  declare -A config_lines

  while read line; do
    key=$(echo $line | awk -F '=' '{print $1}')
    value=$(echo $line | awk -F '=' '{print $2}')

    if [[ -z $line ]]; then
      continue
    fi
    if [ -n "${config_lines[$key]}" ]; then
      config_lines[$key]="$(merge_params ${config_lines[$key]} ${value})"
    else
      config_lines[$key]=$value
    fi
  done <$1
  while read line; do
    key=$(echo $line | awk -F '=' '{print $1}')
    value=$(echo $line | awk -F '=' '{print $2}')

    if [ -n "${config_lines[$key]}" ]; then
      config_lines[$key]="$(merge_params ${config_lines[$key]} ${value})"
    else
      config_lines[$key]=$value
    fi
  done <$2

  echo "# Edited by nix remote builder installation script" >$3
  echo "# If you want to use the old version check $1.old" >>$3
  for key in "${!config_lines[@]}"; do
    echo "$key=${config_lines[$key]}" >>$3
  done
}

configure_nix_file() {
  if [ $# -ne 3 ]; then
    echo "Usage: configure_nix_file <server> <filepath> <conf_to_add_filepath>"
    return 1
  fi
  echo "I'll configure the file $2 on $1 with $(cat $3)."
  echo "I'll save your current configuration into $2.old"
  backup_file $1 $2
  echo "I'll create working folder"
  mkdir -p nix_remote_builder_configuration_working_dir
  echo "I'll download the $2 locally"
  scp $1:$2 nix_remote_builder_configuration_working_dir/existing_conf.tmp
  echo "I'll generate the new configuration"
  merge_config_files $2 $3 nix_remote_builder_configuration_working_dir/merged_config.conf
  echo "Configuration generated"
  cat nix_remote_builder_configuration_working_dir/merged_config.conf
  echo "I'll upload new configuration file onto $1 in $2. If you want to rollback please use $2.old"
  scp_into nix_remote_builder_configuration_working_dir/merged_config.conf $1 $2
  echo "I'll remove local working folder"
  rm -rf nix_remote_builder_configuration_working_dir
}

configure_master_ssh_alias() {
  echo "Configure ssh alias"

  rexec $master_ssh "sudo touch /root/.ssh/config"
  rexec $master_ssh "sudo cp /root/.ssh/config /root/.ssh/config.old"
  rexec $master_ssh "sudo cp /root/.ssh/config /tmp/ssh_config_root"
  scp ${master_ssh}:/tmp/ssh_config_root ssh_config.tmp

  for builder_name in "${builder_names[@]}"; do
    if grep -q "Host $builder_name" ssh_config.tmp; then
      echo "$builder_name conf is already in ${master_ssh} /root/.ssh/config"
      continue
    fi
    echo "" >>ssh_config.tmp
    echo "Host $builder_name" >>ssh_config.tmp
    builder_ip_varname=$(echo ${builder_name//-/_}_ip)
    builder_user_varname=$(echo ${builder_name//-/_}_user)
    echo "    HostName ${!builder_ip_varname}" >>ssh_config.tmp
    echo "    User ${!builder_user_varname}" >>ssh_config.tmp
    echo "    Port 22" >>ssh_config.tmp
    echo "    IdentityFile $master_ssh_pk_filepath" >>ssh_config.tmp
  done
  if [ "$DRY_RUN" = true ]; then
    echo "rexec $master_ssh \"sudo mv /tmp/ssh_config_root /root/.ssh/config\""
  else
    scp_into ssh_config.tmp ${master_ssh} /root/.ssh/config root
    scp_into ssh_config.tmp ${master_ssh} /home/$runner_user/.ssh/config $runner_user
  fi
  rm ssh_config.tmp
}

configure_master_machines_configfile() {
  rexec $master_ssh "sudo touch /etc/nix/machines"
  rexec $master_ssh "sudo cp /etc/nix/machines /etc/nix/machines.old"
  scp ${master_ssh}:/etc/nix/machines machines
  for builder_name in "${builder_names[@]}"; do
    builder_arch_varname=$(echo ${builder_name//-/_}_arch)
    if grep -q "ssh://${builder_name} ${!builder_arch_varname}" machines; then
      echo "${builder_name} is already inside configured machines."
      continue
    fi
    echo "ssh://${builder_name} ${!builder_arch_varname}" >>machines
  done
  scp_into machines ${master_ssh} /etc/nix/machines
  rm machines
}

configure_master() {
  # Activate experimental-features
  echo "Activation of experimental-features (nix-command, flakes) into /etc/nix/nix.conf"
  echo "#tmp file used by distributed build nix install script"
  echo "experimental-features = nix-command flakes" >>conf_to_add.nix
  echo "builders = @/etc/nix/machines" >>conf_to_add.nix
  configure_nix_file $master_ssh "/etc/nix/nix.conf" "conf_to_add.nix"
  rm conf_to_add.nix

  # Register builder machines
  echo "Configure aliases for each builder on master machine"
  configure_master_ssh_alias

  # Register builder machines
  echo "Configure machines file"
  configure_master_machines_configfile

}

configure_builder() {
  if [ $# -ne 1 ]; then
    echo "Usage: configure_builder <builder_name>"
    return 1
  fi
  builder_name=$1
  echo "Configuration of $builder_name"

  # Activate experimental-features
  echo "trusted-users = root ${runner_user}" >${builder_name}_conf_to_add.nix
  echo "experimental-features = nix-command flakes" >>${builder_name}_conf_to_add.nix
  builder_ssh_var=${builder_name//-/_}_sudoer_ssh
  echo "call configure_nix_file ${!builder_ssh_var} \"/etc/nix/nix.conf\" \"${builder_name}_conf_to_add.nix\""
  configure_nix_file ${!builder_ssh_var} "/etc/nix/nix.conf" "${builder_name}_conf_to_add.nix"
  rm ${builder_name}_conf_to_add.nix

  # restart
  echo "restart nix daemon through launchctl and systemctl to be sure to hit the correct process manager. Don't care about the command not found issue."
  echo "If your server don't use launchctl or systemctl please edit the script to use your process manager"
  rexec ${!builder_ssh_var} "sudo launchctl stop org.nixos.nix-daemon || true ;sudo launchctl start org.nixos.nix-daemon || true ;sudo systemctl restart nix-daemon || true "
}

configure_builders() {
  for builder_name in "${builder_names[@]}"; do
    configure_builder $builder_name
  done
}

# check arguments
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
  --dry-run)
    DRY_RUN=true
    shift # past argument
    ;;
  *)
    # unknown option
    ;;
  esac
  shift # past argument or value
done

echo "I will use SUDO on machines to configure remote builders (please check the script before your decision) do you agree (yes/no)"
read -r user_input
if [ "$user_input" != "yes" ]; then
  echo "Exiting without configuring nix remote builder."
  exit 1
fi

load_conf conf.json

configure_master "server" exist_conf.nix "test/conf_to_add.nix"

configure_builders

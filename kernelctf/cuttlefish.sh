#!/bin/bash
set -e

RELEASE_PATH=""

cleanup_function() {
    set +e
    echo "Shutting down $RELEASE_PATH/cuttlefish_runtime.$instance_num:$port_number"

    # /cuttlefish_runtime is a symbolic link to a cuttlefish instance folder.
    # It is used as the target of some ./bin/... operations.
    CUTTLEFISH_ACTIVE_INSTANCE=$RELEASE_PATH/cuttlefish_runtime
    CUTTLEFISH_CURRENT_ISNTANCE=$RELEASE_PATH/cuttlefish/instances/cvd-$instance_num
    ln -sf $CUTTLEFISH_ACTIVE_INSTANCE $CUTTLEFISH_CURRENT_INSTANCE

    echo "cleaning at RELEASE_PATH: $RELEASE_PATH"
    rm -rf "$folder"
    rm -rf "$RELEASE_PATH/cuttlefish_runtime.$instance_num"
    rm -rf "$RELEASE_PATH/cuttlefish/instances/cvd-$instance_num"
    rm -rf "$RELEASE_PATH/../locks/lock-inst-$instance_num"
    HOME=$RELEASE_PATH $RELEASE_PATH/bin/stop_cvd
    echo "Cleanup done. Exiting" 1>&2
    exit 0
}

cleanup_wrapper() {
    cleanup_function 1>&2
}

trap 'cleanup_wrapper' EXIT

usage() {
    echo "Usage: $0 --release_path=<release_path> --interactive | --apk_path=<apk_path> --apk_name=<app_name> | --bin_path=<bin_path> [--privileged] --flag_path<flag_fn>"
    exit 1;
}
IS_APK=false
INTERACTIVE=false
PRIVILEGED=false
ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --interactive) INTERACTIVE=true; shift;;
    --privileged) PRIVILEGED=true; shift;;
    --release_path=*) RELEASE_PATH="${1#*=}"; shift;;
    --apk_path=*) APK_PATH="${1#*=}"; IS_APK=true; shift;;
    --apk_name=*) APK_NAME="${1#*=}"; IS_APK=true; shift;;
    --bin_path=*) BIN_PATH="${1#*=}"; shift;;
    --flag_path=*) FLAG_FN="${1#*=}"; shift;;
    --) # stop processing special arguments after "--"
        shift
        while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done
        break
        ;;
    -*|--*) echo "Unknown option $1"; usage;;
    *) ARGS+=("$1"); shift;;
  esac
done
set -- "${ARGS[@]}"

if [ ! -d "$RELEASE_PATH/../locks" ]; then
    mkdir "$RELEASE_PATH/../locks"
fi

# Check for the first free instance (non-existing folder). Immediately occupy it.
# If there are no free spaces, exit.
# We are limited to 32 instances globally as of now.
for i in $(seq 1 32); do
    folder="$RELEASE_PATH/../locks/lock-inst-${i}"
    if mkdir "$folder" 2>/dev/null; then
        instance_num=$i
        break
    fi
done

if [ -z $instance_num ]; then
    echo "all instances are busy, exiting..."
    exit 1
fi

# Create and boot virtual device with android kernel at RELEASE_PATH.
# The path to launch_cvd needs to be 108 charactes or less
echo "Starting instance"
bash -c "HOME=$RELEASE_PATH $RELEASE_PATH/bin/launch_cvd --daemon --console=true --resume=false\
         --system_image_dir=\"$RELEASE_PATH\" --base_instance_num=$instance_num\
         -report_anonymous_usage_stats=n"

# Look for the port number in the config file.
# The port number is needed to talk specifically to this VM.
regex='"adb_ip_and_port" : "0\.0\.0\.0:([0-9]{4})"'
while IFS= read -r line; do
  if [[ $line =~ $regex ]]; then
    port_number="${BASH_REMATCH[1]}"
    break
  fi
done < "$RELEASE_PATH/cuttlefish_runtime.$instance_num/cuttlefish_config.json"

on_guest="$RELEASE_PATH/bin/adb -s 0.0.0.0:$port_number"
as_root="$RELEASE_PATH/bin/adb -s 0.0.0.0:$port_number shell su root"

# Setup flag file
FLAG=$(<$FLAG_FN)
$on_guest push $FLAG_FN /data/local/tmp
$as_root "chmod 0000 /data/local/tmp/flag"
$as_root "chown root:root /data/local/tmp/flag"

PORT_TO_USE=$(expr $instance_num + 7000)

# Create a named pipe
pipe_name=$(mktemp -u)
mkfifo "$pipe_name"

$on_guest install $RELEASE_PATH/../app-debug.apk
$as_root "am start -n com.example.api029_java_port_test/.MainActivity -e server_port $PORT_TO_USE"
$on_guest forward tcp:$PORT_TO_USE tcp:$PORT_TO_USE

# background process to redirect VM's logcat output to a named pipe
(($on_guest logcat -s kernelCTF_READY) 2>/dev/null > "$pipe_name") &
pid=$!

# Wait for android device to be ready
#if timeout 20s grep -q kernelCTF_READY "$pipe_name"; then
# Use grep to wait for the first match and then kill the process
if timeout 5s grep -q kernelCTF_READY $pipe_name; then
    echo "VM ready for connection"
else
    echo "VM setup failed. Exiting"
    kill "$pid"
    exit
fi
kill $pid

# Give researchers an interactive shell
if $INTERACTIVE; then

    echo "Spawning interactive shell"
    nc 127.0.0.1 $PORT_TO_USE -v

else # is binary

    BIN_NAME=$(basename $BIN_PATH)
    $on_guest push $BIN_PATH /data/local/tmp

    $as_root "chmod 777 /data/local/tmp/$BIN_NAME"
    $as_root "chown 10108:10108 /data/local/tmp/$BIN_NAME"
    $as_root "chcon u:object_r:apk_data_file:s0 /data/local/tmp/$BIN_NAME"

    echo "Running bin"
    nc 127.0.0.1 $PORT_TO_USE
fi


#!/bin/bash

set -u
set -o pipefail

#
# Global vars.
#
node_state_dir='/var/run/slurm/'
node_state_file_old="${node_state_dir}/sinfo_report_old"
node_state_file_new="${node_state_dir}/sinfo_report_new-${$}"
send_notification='false'

#
##
### Functions
##
#
function thereShallBeOnlyOne() {
	local _lock_file
	local _lock_dir
	_lock_file="${1}"
	_lock_dir="$(dirname "${_lock_file}")"
	mkdir -p "${_lock_dir}"  || logger --id="${$}" -s "Failed to create dir for lock file @ ${_lock_dir}."
	exec 200>"${_lock_file}" || true # logger --id="${$}" -s "Failed to create FD 200>${_lock_file} for locking."
	while ! flock -n 200; do
		#logger --id="${$}" -s "Lockfile ${_lock_file} already claimed by another instance of $(basename "${0}"); waiting 61 secs ..."
		sleep 61
		exec 200>"${_lock_file}" || true # logger --id="${$}" -s "Failed to create FD 200>${_lock_file} for locking."
	done
	#logger --id="${$}" -s "Created FD 200>${_lock_file} for locking."
}

#
##
### Main
##
#

#
# Make sure only one instance of this script at a time is processing events.
# Otherwise we may overwrite state files while processing
# or sending notifications may fail due to message rate limiting.
#
thereShallBeOnlyOne "${node_state_dir}/nodes.lock"

#
# Get current node state after we got executed by strigger.
# Example output:
#
# PARTITION|AVAIL|NODES|STATE|NODELIST|REASON
# regular*|up|1|drained*|gs-vcompute05|NHC: check_ps_loadavg:  1-minute load average too high:  85 >= 48
# regular*|up|9|mixed|gs-vcompute[01-04,06-10]|none
# user_interface|up|1|idle|gearshift|none
#
sinfo -o "%P|%a|%D|%T|%N|%E" > "${node_state_file_new}"

#
# Compile JSON node state message payload.
#
read -r -d '\0' message <<- EOM
	{
		"type": "mrkdwn",
		"text": "*Node state on _{{ slurm_cluster_name | capitalize }}_ changed*:  
		\`\`\`
		$(tr \" \' < "${node_state_file_new}" | column -t -s '|')
		\`\`\`"
	}\0
EOM

#logger --id="${$}" -s "Got new node state stored in ${node_state_file_new}."

#
# Delete old node state after one day to send a new notification
# if the problem was not yet resolved.
#
if [[ -e "${node_state_file_old}" ]]; then
	find "${node_state_file_old}" -mtime +1 -delete
fi

#
# Compile new notification.
#
if [[ -e "${node_state_file_old}" ]]; then
	if [[ -r "${node_state_file_old}" ]]; then
		#logger --id="${$}" -s "${node_state_file_old} exists and is readable."
		#
		# Drop some resolution from the "REASON" field to prevent sending redundant notifications
		# when the state has not changed significantly.
		# E.g. load was too high and changed slightly, but is still is too high.
		#
		node_state_file_old_short="${node_state_file_old}-${$}.short"
		node_state_file_new_short="${node_state_file_new}.short"
		sed 's/:  [^:]*$//' "${node_state_file_old}" | sort > "${node_state_file_old_short}"
		sed 's/:  [^:]*$//' "${node_state_file_new}" | sort > "${node_state_file_new_short}"
		#logger --id="${$}" -s "Created ${node_state_file_old_short} and ${node_state_file_new_short}."
		if cmp -s "${node_state_file_old_short}" "${node_state_file_new_short}"; then
			: # no-op: The files are identical: nothing changed and there is no need to send a new notification.
			#logger --id="${$}" -s "No differences found in ${node_state_file_old_short} compared to ${node_state_file_new_short}."
		else
			#logger --id="${$}" -s "Differences were found in ${node_state_file_old_short} compared to ${node_state_file_new_short}."
			cp -v "${node_state_file_new}" "${node_state_file_old}"
			send_notification='true'
			#logger --id="${$}" -s "send_notification = ${send_notification}."
		fi
		rm -v -f "${node_state_file_old_short}" "${node_state_file_new_short}"
	else
		#
		# Compile JSON error message payload.
		#
		read -r -d '\0' message <<- EOM
			{
				"type": "mrkdwn",
				"text": "*Failed to report node state for _{{ slurm_cluster_name | capitalize }}_*:  
				${node_state_file_old} exists but is not readable."
			}\0
		EOM
		send_notification='true'
		#logger --id="${$}" -s "send_notification = ${send_notification}."
	fi
else
	#logger --id="${$}" -s "${node_state_file_old} does not exist: send notification."
	cp -v "${node_state_file_new}" "${node_state_file_old}"
	send_notification='true'
	#logger --id="${$}" -s "send_notification = ${send_notification}."
fi

#
# Post message to Slack channel.
#
if [[ "${send_notification}" == 'true' ]]; then
	#logger --id="${$}" -s "Sending message..."
	curl -X POST '{{ slurm_notification_slack_webhook }}' \
		 -H 'Content-Type: application/json' \
		 -d "${message}"
else
	: # no-op
	#logger --id="${$}" -s 'Node state has not changed: not sending message.'
fi

#
# Cleanup
#
rm -v -f "${node_state_file_new}"

exit 0

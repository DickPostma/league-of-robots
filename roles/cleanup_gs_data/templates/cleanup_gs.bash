#!/bin/bash

slurm_notification_slack_webhook='{{ slurm_notification_slack_webhook }}'
{% raw %}
dirToCheck="/groups/umcg-genomescan/"
dateInSecNow=$(date +%s)

#
# Find all GenomeScan batch dirs ignoring files.
#
# If folder is older than 2 weeks -> delete folder.
# If folder is younger
#    If it only contains leftovers from already processed data -> do nothing.
#    If it contains unprocessed data and is older than 1 week -> send warning.
#
# Leftovers from processed data sets:
#   Old style with only raw data:
#     [0-9]{6}-[0-9]{3}/
#     [0-9]{6}-[0-9]{3}/[0-9]{6}-[0-9]{3}.finished
#   E.g.:
#     104832-210/
#     104832-210/104832-210.finished
#   New style Dragen data:
#     [0-9]{6}-[0-9]{3}/
#     [0-9]{6}-[0-9]{3}/[0-9]{6}-[0-9]{3}.finished
#     [0-9]{6}-[0-9]{3}/Analysis/
#     [0-9]{6}-[0-9]{3}/Raw_data/
#     [0-9]{6}-[0-9]{3}/UMCG_CSV_[0-9]{6}-[0-9]{3}.csv
#   E.g.
#     104832-210/
#     104832-210/104832-210.finished
#     104832-210/Analysis/
#     104832-210/Raw_data/
#     104832-210/UMCG_CSV_104832-210.csv
#
for dir in $(find "${dirToCheck}" -mindepth 1 -maxdepth 1 -type d | sort)
do
	echo "Processing ${dir} ..."
	#
	# Check creation time instead of modification time
	# and remove /groups from dir for lookup with debugfs.
	#
	creationTime=$(/sbin/debugfs -R 'stat '${dir#*/*/} /dev/vdb | awk '/crtime/{print $2}' FS='--')
	creationTimeSeconds=$(date -d"${creationTime}" +%s)
	echo "  Checking age ..."
	if [[ $(((${dateInSecNow} - ${creationTimeSeconds}) / 86400)) -gt 14 ]]
	then
		echo "  Deleting folder, because it is older than 14 days ..."
		rm -rf "${dir}"
	else
		echo "  Keeping folder, because it is not yet older than 14 days."
		foundUnprocessedData="$(find "${dir}" -mindepth 1 -maxdepth 2 \
				! -name Raw_data -a \
				! -name Analysis -a \
				! -name '*.finished' -a \
				! -name 'UMCG_CSV_*.csv'
			)"
		if [[ -z "${foundUnprocessedData:-}" ]]
		then
			echo "    Folder empty or contains only leftovers from processed data."
		else 
			echo "    Folder contains unprocessed data: checking age ..."
			if [[ $(((${dateInSecNow} - ${creationTimeSeconds}) / 86400)) -gt 7 ]]
			then
				echo "      Unprocessed folder is older than 7 days: sending warning ..."
				creationDate=$(date -d "${creationTime}")
				deletionDate=$(date -d "${creationDate} +15 days")
				#
				# Compile JSON message payload.
				#
				read -r -d '\0' message <<- EOM
					{
						"type": "mrkdwn",
						"text": "*Cleanup alert for _$(hostname):${dir}_*:
						\`\`\`
						This unprocessed data is older than a week and will be *deleted on ${delete_date}*!
						\`\`\`"
					}\0
				EOM
				#
				# Post message to Slack channel.
				#
				curl -X POST "${slurm_notification_slack_webhook}" \
					 -H 'Content-Type: application/json' \
					 -d "${message}"
			else
				echo "      Unprocessed folder is younger than 7 days: there is no need to send a warning."
			fi
		fi
	fi
done
{% endraw %}

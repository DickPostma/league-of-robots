#!/bin/bash

#
# Code Conventions:
# 	Indentation:           TABs only
# 	Functions:             camelCase
# 	Global Variables:      lower_case_with_underscores
# 	Local Variables:       _lower_case_with_underscores_and_prefixed_with_underscore
# 	Environment Variables: UPPER_CASE_WITH_UNDERSCORES
#

#
##
### Environment and Bash sanity.
##
#
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
	echo "Sorry, you need at least bash 4.x to use ${0}." >&2
	exit 1
fi

set -e # Exit if any subcommand or pipeline returns a non-zero exit status.
set -u # Raise exception if variable is unbound. Combined with set -e will halt execution when an unbound variable is encountered.
set -o pipefail # Fail when any command in series of piped commands failed as opposed to only when the last command failed.

umask 0077

#
# LDAP is case insensitive, but we use lowercase only for field names,
# so we can use simple literal strings in comparisons as opposed to regexes
# to handle differences in UPPERCASE vs. lowercase.
#
# The UPPERCASE "LFS" in ${ldap_group_quota_*_limit_template} variables 
# is a required placeholder that will get replaced with the value of the Logical File System (LFS)
# for which we will try to fetch quota limits from the LDAP.
# E.g. with ldap_group_quota_soft_limit_template='ruggroupumcgquotaLFSsoft',
#      the fieldname/key to lookup the soft quota limit for the LFS prm01 is
#      ruggroupumcgquotaprm01soft
#
declare    ldap_group_object_class='{{ ldap_group_object_class }}'
declare    ldap_group_quota_soft_limit_template='{{ ldap_group_quota_soft_limit_template }}'
declare    ldap_group_quota_hard_limit_template='{{ ldap_group_quota_hard_limit_template }}'
declare -A ldap_quota_limits=()

#
# Lustre quota type for groups:
# We prefer "project quota" for group folders,
# but we'll use "group quota" when project quota are not supported (yet).
#
declare    lustre_quota_type='{{ lustre_quota_type }}'

#
# No more Ansible variables below this point!
#
{% raw %}
#
# Global variables.
#
declare TMPDIR="${TMPDIR:-/tmp}" # Default to /tmp if ${TMPDIR} was not defined.
declare SCRIPT_NAME
SCRIPT_NAME="$(basename "${0}" '.bash')"
export TMPDIR
export SCRIPT_NAME
declare mixed_stdouterr='' # global variable to capture output from commands for reporting in custom log messages.
declare ldif_dir="${TMPDIR}/ldifs"
declare config_file='/etc/ssh/ldap.conf'

#
# Initialise Log4Bash logging with defaults.
#
l4b_log_level="${log_level:-INFO}"
declare -A l4b_log_levels=(
	['TRACE']='0'
	['DEBUG']='1'
	['INFO']='2'
	['WARN']='3'
	['ERROR']='4'
	['FATAL']='5'
)
l4b_log_level_prio="${l4b_log_levels["${l4b_log_level}"]}"

#
# Make sure dots are used as decimal separator.
#
LANG='en_US.UTF-8'
LC_NUMERIC="${LANG}"

#
##
### Functions.
##
#
function showHelp() {
	#
	# Display commandline help on STDOUT.
	#
	cat <<EOH
===============================================================================================================
Script to fetch quota values from an LDAP server and apply them to a shared File System for a cluster.

Usage:

	$(basename "${0}") OPTIONS

OPTIONS:

	-h   Show this help.
	-a   Apply (new) settings to the File System(s).
	     By default this script will only do a "dry run" and fetch + list the settings as stored in the LDAP.
	-l   Log level.
	     Must be one of TRACE, DEBUG, INFO (default), WARN, ERROR or FATAL.

Details:

	Values are always reported with a dot as the decimal seperator (LC_NUMERIC="en_US.UTF-8").
	LDAP connection details are fetched from ${config_file}.
===============================================================================================================

EOH
	#
	# Reset trap and exit.
	#
	trap - EXIT
	exit 0
}

#
# Custom signal trapping functions (one for each signal) required to format log lines depending on signal.
#
function trapSig() {
	for _sig; do
		trap 'trapHandler '"${_sig}"' ${LINENO} ${FUNCNAME[0]:-main} ${?}' "${_sig}"
	done
}

function trapHandler() {
	local _signal="${1}"
	local _line="${2}"
	local _function="${3}"
	local _status="${4}"
	log4Bash 'FATAL' "${_line}" "${_function}" "${_status}" "Trapped ${_signal} signal."
}

#
# Trap all exit signals: HUP(1), INT(2), QUIT(3), TERM(15), ERR.
#
trapSig HUP INT QUIT TERM EXIT ERR

#
# Catch all function for logging using log levels like in Log4j.
# ARGS: LOG_LEVEL, LINENO, FUNCNAME, EXIT_STATUS and LOG_MESSAGE.
#
function log4Bash() {
	#	
	# Validate params.
	#
	if [ ! "${#}" -eq 5 ] ;then
		echo "WARN: should have passed 5 arguments to ${FUNCNAME[0]}: log_level, LINENO, FUNCNAME, (Exit) STATUS and log_message."
	fi
	#
	# Determine prio.
	#
	local _log_level="${1}"
	local _log_level_prio="${l4b_log_levels["$_log_level"]}"
	local _status="${4:-$?}"
	#
	# Log message if prio exceeds threshold.
	#
	if [[ "${_log_level_prio}" -ge "${l4b_log_level_prio}" ]]; then
		local _problematic_line="${2:-'?'}"
		local _problematic_function="${3:-'main'}"
		local _log_message="${5:-'No custom message.'}"
		#
		# Some signals erroneously report $LINENO = 1,
		# but that line contains the shebang and cannot be the one causing problems.
		#
		if [ "${_problematic_line}" -eq 1 ]; then
			_problematic_line='?'
		fi
		#
		# Format message.
		#
		local _log_timestamp
		local _log_line_prefix
		_log_timestamp=$(date "+%Y-%m-%dT%H:%M:%S") # Creates ISO 8601 compatible timestamp.
		_log_line_prefix=$(printf "%-s %-s %-5s @ L%-s(%-s)>" "${SCRIPT_NAME}" "${_log_timestamp}" "${_log_level}" "${_problematic_line}" "${_problematic_function}")
		local _log_line="${_log_line_prefix} ${_log_message}"
		if [[ -n "${mixed_stdouterr:-}" ]]; then
			_log_line="${_log_line} STD[OUT+ERR]: ${mixed_stdouterr}"
		fi
		if [[ "${_status}" -ne 0 ]]; then
			_log_line="${_log_line} (Exit status = ${_status})"
		fi
		#
		# Log to STDOUT (low prio <= 'WARN') or STDERR (high prio >= 'ERROR').
		#
		if [[ "${_log_level_prio}" -ge "${l4b_log_levels['ERROR']}" || "${_status}" -ne 0 ]]; then
			printf '%s\n' "${_log_line}" > '/dev/stderr'
		else
			printf '%s\n' "${_log_line}"
		fi
	fi	
	#
	# Exit if this was a FATAL error.
	#
	if [[ "${_log_level_prio}" -ge "${l4b_log_levels['FATAL']}" ]]; then
		#
		# Reset trap and exit.
		#
		trap - EXIT
		if [[ "${_status}" -ne 0 ]]; then
			exit "${_status}"
		else
			exit 1
		fi
	fi
}

#
# Parse LDIF records and apply quota to Physical File Systems (PFSs).
#
function processFileSystems () {
	local    _lfs_path_regex='/mnt/([^/]+)/groups/([^/]+)/([^/]+)'
	local    _pos_int_regex='^[0-9]+$'
	local    _lfs_path
	local -a _lfs_paths=("${@}")
	#
	# Loop over Logical File System (LFS) paths,
	# find the corresponding quota values,
	# and apply quota settings.
	#
	for _lfs_path in "${_lfs_paths[@]}"; do
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "Processing LFS path ${_lfs_path} ..."
		local _pfs_from_lfs_path
		local _group_from_lfs_path
		local _lfs_from_lfs_path
		local _fs_type
		if [[ "${_lfs_path}" =~ ${_lfs_path_regex} ]]; then
			_pfs_from_lfs_path="${BASH_REMATCH[1]}"
			_group_from_lfs_path="${BASH_REMATCH[2]}"
			_lfs_from_lfs_path="${BASH_REMATCH[3]}"
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "      found _pfs_from_lfs_path:   ${_pfs_from_lfs_path}."
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "      found _group_from_lfs_path: ${_group_from_lfs_path}."
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "      found _lfs_from_lfs_path:   ${_lfs_from_lfs_path}."
			_fs_type="$(awk -v _mount_point="/mnt/${_pfs_from_lfs_path}" '{if ($2 == _mount_point) print $3}' /proc/mounts)"
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "      found _fs_type:             ${_fs_type}."
		else
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping malformed LFS path ${_lfs_path}."
			continue
		fi
		#
		# Reset hash and then query for quota values for this group on this LFS.
		#
		ldap_quota_limits=()
		local _soft_quota_limit
		local _hard_quota_limit
		getQuotaFromLDAP "${_lfs_from_lfs_path}" "${_group_from_lfs_path}"
		if [[ -n "${ldap_quota_limits['soft']+isset}" && \
			  -n "${ldap_quota_limits['hard']+isset}" ]]; then
			_soft_quota_limit="${ldap_quota_limits['soft']}"
			_hard_quota_limit="${ldap_quota_limits['hard']}"
		else
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "   Quota values missing for group ${_group_from_lfs_path} on LFS ${_lfs_from_lfs_path}."
			continue
		fi
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "      _soft_quota_limit contains: ${_soft_quota_limit}."
		log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "      _hard_quota_limit contains: ${_hard_quota_limit}."
		#
		# Check for negative numbers and non-integers.
		#
		if [[ ! "${_soft_quota_limit}" =~ ${_pos_int_regex} || ! "${_hard_quota_limit}" =~ ${_pos_int_regex} ]]; then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "   Quota values malformed for group ${_group_from_lfs_path} on LFS ${_lfs_from_lfs_path}. Must be integers >= 0."
			continue
		fi
		#
		# Check if soft limit is larger than the hard limit as that will quota commands to fail.
		#
		if [[ "${_soft_quota_limit}" -gt "${_hard_quota_limit}" ]]; then
			log4Bash 'ERROR' "${LINENO}" "${FUNCNAME:-main}" '0' "   Quota values malformed for group ${_group_from_lfs_path} on LFS ${_lfs_from_lfs_path}. Soft limit cannot be larger than hard limit."
			continue
		fi
		#
		# Check for 0 (zero).
		# When quota values are set to zero it means unlimited: not what we want.
		# When zero was specified we'll interpret this as "do not allow this group to consume any space".
		# Due to the technical limitations of how quota work we'll configure the lowest possible value instead:
		# This is 2 * the block/stripe size on Lustre File Systems.
		#
		if [[ "${_soft_quota_limit}" -eq 0 ]]; then
			_soft_quota_limit='2M'
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "   Converted soft quota limit of 0 (zero) for group ${_group_from_lfs_path} on LFS ${_lfs_from_lfs_path} to lowest possible value of ${_soft_quota_limit}."
		else
			# Just append unit: all quota values from the IDVault are in GB.
			_soft_quota_limit="${_soft_quota_limit}G"
		fi
		if [[ "${_hard_quota_limit}" -eq 0 ]]; then
			_hard_quota_limit='2M'
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "   Converted hard quota limit of 0 (zero) for group ${_group_from_lfs_path} on LFS ${_lfs_from_lfs_path} to lowest possible value of ${_hard_quota_limit}."
		else
			# Just append unit: all quota values from the IDVault are in GB.
			_hard_quota_limit="${_hard_quota_limit}G"
		fi
		#
		# Get the GID for this group, which will be used as the file set / project ID for quota accounting.
		#
		local _gid
		_gid="$(getent group "${_group_from_lfs_path}" | awk -F ':' '{printf $3}')"
		if [[ "${_fs_type}" == 'lustre' ]]; then
			applyLustreQuota "${_lfs_path}" "${_gid}" "${_soft_quota_limit}" "${_hard_quota_limit}"
		else
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "   Cannot configure quota due to unsuported file system type: ${_fs_type}."
		fi
	done
}

#
# Set Lustre project a.k.a. file set a.k.a folder quota limits:
#  * Set project attribute on LFS path using GID as project ID.
#  * Use lfs setquota to configure quota limit for project.
#
function applyLustreQuota () {
	local    _lfs_path="${1}"
	local    _gid="${2}"
	local    _soft_quota_limit="${3}"
	local    _hard_quota_limit="${4}"
	local    _cmd
	local -a _cmds
	if [[ "${apply_settings}" -eq 1 ]]; then
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "   Executing quota commands ..."
	else
		log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "   Dry run: the following quota commands would have been executed with the '-a' switch ..."
	fi
	if [[ "${lustre_quota_type}" == 'project' ]]; then
		_cmds=(
			"chattr +P ${_lfs_path}"
			"chattr -p ${_gid} ${_lfs_path}"
			"lfs setquota -p ${_gid} --block-softlimit ${_soft_quota_limit} --block-hardlimit ${_hard_quota_limit} ${_lfs_path}"
		)
	elif [[ "${lustre_quota_type}" == 'group' ]]; then
		_cmds=(
			"lfs setquota -g ${_gid} --block-softlimit ${_soft_quota_limit} --block-hardlimit ${_hard_quota_limit} ${_lfs_path}"
		)
	else
		log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "   Unsuported Lustre quota type: ${lustre_quota_type}."
	fi
	for _cmd in "${_cmds[@]}"; do
		log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' "   Applying cmd: ${_cmd}"
		if [[ "${apply_settings}" -eq 1 ]]; then
			mixed_stdouterr="$(${_cmd})" || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to execute: ${_cmd}"
		fi
	done
}

function getQuotaFromLDAP () {
	local    _lfs="${1}"
	local    _group="${2}"
	local    _ldap_attr_regex='([^: ]{1,})(:{1,2}) ([^:]{1,})'
	local    _ldif_file="${ldif_dir}/${_group}.ldif"
	local    _ldif_record
	local -a _ldif_records
	local    _ldap_group_quota_soft_limit_key="${ldap_group_quota_soft_limit_template/LFS/${_lfs}}"
	local    _ldap_group_quota_hard_limit_key="${ldap_group_quota_hard_limit_template/LFS/${_lfs}}"
	#
	# Query LDAP
	#
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Retrieving data from LDAP..."
	mixed_stdouterr=$(ldapsearch -LLL -o ldif-wrap=no \
						-H "${LDAP_HOST}" \
						-D "${LDAP_USER}" \
						-w "${LDAP_PASS}" \
						-b "${LDAP_SEARCH_BASE}" \
						"(&(ObjectClass=${ldap_group_object_class})(cn:dn:=${_group}))" \
						"${_ldap_group_quota_soft_limit_key}" \
						"${_ldap_group_quota_hard_limit_key}" \
						2>&1 >"${_ldif_file}") \
					|| log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "ldapsearch failed."
	#
	# Parse query results.
	#
	while IFS= read -r -d '' _ldif_record; do
		_ldif_records+=("$_ldif_record")
	done < <(sed 's/^$/\x0/' "${_ldif_file}") \
	|| log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Parsing LDIF file (${_ldif_file}) into records failed."
	#
	# Loop over records in the array and create a faked-multi-dimensional hash.
	#
	for _ldif_record in "${_ldif_records[@]}"; do
		#
		# Remove trailing white space like the new line character.
		# And skip blank lines.
		#
		_ldif_record="${_ldif_record%%[[:space:]]}"
		[[ "${_ldif_record}" == '' ]] && continue
		log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "LDIF record contains: ${_ldif_record}"
		#
		# Parse record's key:value pairs.
		#
		local -A _directory_record_attributes=()
		local    _ldif_line
		while IFS=$'\n' read -r _ldif_line; do
			[[ "${_ldif_line}" == '' ]] && continue # Skip blank lines.
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "LDIF key:value pair contains: ${_ldif_line}."
			if [[ "${_ldif_line}" =~ ${_ldap_attr_regex} ]]; then
				local _key="${BASH_REMATCH[1],,}" # Convert key on-the-fly to lowercase.
				local _sep="${BASH_REMATCH[2]}"
				local _value="${BASH_REMATCH[3]}"
				#
				# Check if value was base64 encoded (double colon as separator)
				# or plain text (single colon as separator) and decode if necessary.
				#
				if [[ "${_sep}" == '::' ]]; then
					log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "     decoding base64 encoded value..."
					_value="$(printf '%s' "${_value}" | base64 -di)"
				fi
				#
				# This may be a multi-valued attribute and therefore check if key already exists;
				# When key already exists make sure we append instead of overwriting the existing value(s)!
				#
				if [[ -n "${_directory_record_attributes[${_key}]+isset}" ]]; then
					_directory_record_attributes["${_key}"]="${_directory_record_attributes["${_key}"]} ${_value}"
				else
					_directory_record_attributes["${_key}"]="${_value}"
				fi
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "     key   contains: ${_key}."
				log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "     value contains: ${_value}."
			else
				log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Failed to parse LDIF key:value pair (${_ldif_line})."
			fi
		done < <(printf '%s\n' "${_ldif_record}") || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Parsing LDIF record failed."
		#
		# Get Quota from processed LDIF record if this the right group.
		#
		local _ldap_group
		if [[ -n "${_directory_record_attributes['dn']+isset}" ]]; then
			#
			# Parse cn from dn.
			#
			_ldap_group=$(dn2cn "${_directory_record_attributes['dn']}")
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Found group ${_ldap_group} in dn attribute."
		else
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "dn attribute missing for ${_ldif_record}"
		fi
		if [[ "${_ldap_group}" == "${_group}" ]]; then
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Group from ldap record matches the group we were looking for: ${_ldap_group}."
		else
			log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Skipping LDAP group ${_ldap_group} that does not match the LFS group ${_group} we were looking for."
			continue
		fi
		#
		# Get quota values for this group on this LFS.
		#
		if [[ -n "${_directory_record_attributes["${_ldap_group_quota_soft_limit_key}"]+isset}" && \
			  -n "${_directory_record_attributes["${_ldap_group_quota_hard_limit_key}"]+isset}" ]]; then
			ldap_quota_limits['soft']="${_directory_record_attributes["${_ldap_group_quota_soft_limit_key}"]}"
			ldap_quota_limits['hard']="${_directory_record_attributes["${_ldap_group_quota_hard_limit_key}"]}"
			return
		else
			log4Bash 'WARN' "${LINENO}" "${FUNCNAME:-main}" '0' "   Quota values missing for group ${_ldap_group} on LFS ${_lfs_from_lfs_path}."
			log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "      Search keys were ${_ldap_group_quota_soft_limit_key} and ${_ldap_group_quota_hard_limit_key}."
			continue
		fi
	done
}


#
# Extract a CN from a DN LDAP attribute.
#
function dn2cn () {
	# cn=umcg-someuser,ou=users,ou=umcg,o=rs
	local _dn="$1"
	local _cn='MIA'
	local _regex='cn=([^, ]+)'
	if [[ "${_dn}" =~ ${_regex} ]]; then
		_cn="${BASH_REMATCH[1]}"
	fi
	printf '%s' "${_cn}"
}

#
##
### Main.
##
#

#
# Get commandline arguments.
#
declare apply_settings=0
while getopts ":l:ah" opt; do
	case "${opt}" in
		h)
			showHelp
			;;
		a)
			apply_settings=1
			;;
		l)
			l4b_log_level="${OPTARG^^}"
			l4b_log_level_prio="${l4b_log_levels["${l4b_log_level}"]}"
			;;
		\?)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Invalid option -${OPTARG}. Try $(basename "${0}") -h for help."
			;;
		:)
			log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Option -${OPTARG} requires an argument. Try $(basename "${0}") -h for help."
			;;
		esac
done

#
# Get credentials from config file.
#
#	LDAP_USER='some_account'
#	LDAP_PASS='some_passwd'
#	LDAP_SEARCH_BASE='ou=groups,ou=some_org_unit,o=some_org'
#
if [[ -r "${config_file}" && -f "${config_file}" ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Fetching ldapsearch credentials from config file ${config_file} ..."
	LDAP_HOST="$(awk '$1 == "uri" {print $2}' "${config_file}")"         || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to parse LDAP_HOST from ${config_file}."
	LDAP_USER="$(awk '$1 == "binddn" {print $2}' "${config_file}")"      || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to parse LDAP_USER from ${config_file}."
	LDAP_PASS="$(awk '$1 == "bindpw" {print $2}' "${config_file}")"      || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to parse LDAP_PASS from ${config_file}."
	LDAP_SEARCH_BASE="$(awk '$1 == "base" {print $2}' "${config_file}")" || log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" "${?}" "Failed to parse LDAP_SEARCH_BASE from ${config_file}."
	log4Bash 'TRACE' "${LINENO}" "${FUNCNAME:-main}" '0' "Using LDAP credentials: LDAP_HOST=${LDAP_HOST} | LDAP_USER=${LDAP_USER} | LDAP_PASS=${LDAP_PASS} | LDAP_SEARCH_BASE=${LDAP_SEARCH_BASE}"
else
	log4Bash 'FATAL' "${LINENO}" "${FUNCNAME:-main}" '1' "Config file ${config_file} missing or not accessible."
fi

if [ "${apply_settings}" -eq 1 ]; then
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Found option -a: will fetch, list and apply settings.'
else
	log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" '0' 'Option -a not specified: will only perform a "dry run" to fetch + list settings. Use -a to apply settings.'
fi

#
# Get a list of LFS paths: folders for groups, which we want to apply project quota to.
# On a SAI always in format/location:
#	/mnt/${pfs}/groups/${group}/${lfs}/
# E.g.:
#	/mnt/umcgst02/groups/umcg-atd/prm08/
#
readarray -t lfs_paths < <(find /mnt/*/groups/*/ -maxdepth 1 -mindepth 1 -type d -name "[a-z][a-z]*[0-9][0-9]*")

#
# Create tmp dir for LDIFs with results from LDAP queries.
#
mkdir -p "${ldif_dir}"

#
# Get quota values from LDAP and apply quota limits to file systems.
#
processFileSystems "${lfs_paths[@]:-}"

#
# Cleanup tmp files.
#
if [[ "${l4b_log_level_prio}" -lt "${l4b_log_levels['INFO']}" ]]; then
	log4Bash 'DEBUG' "${LINENO}" "${FUNCNAME:-main}" '0' "Debug mode: temporary dir ${ldif_dir} won't be removed."
else
	rm -Rf "${ldif_dir}"
fi

#
# Reset trap and exit.
#
log4Bash 'INFO' "${LINENO}" "${FUNCNAME:-main}" 0 "Finished!"
trap - EXIT
exit 0

{% endraw %}
#!/bin/sh

prog_name=${0##*/}
version=1.0
version_text="$prog_name - List online twitch channels v$version"
options="c f: l L h q v"
help_text="Usage: $prog_name [-f <file>] [-hlLqv] [<channel>]...

List online twitch channels

	-f <file>  Use <file> as list of channels to check status on
        -l         Long listing format including stream titles
        -L         Login to twitch.tv and acquire an access token
        -h         Display this help text and exit
        -q         Quiet
        -v         Display version information and exit"

main() {
	set_defaults
	parse_options "$@"
	shift $((OPTIND-1))

	# Handle options.
	# Silence warnings about unassigned variables. They are assigned
	# a value dynamically in `parse_options()`.
	# shellcheck disable=2154
	{
		$option_f && {
			if [ "$param_f" = "-" ]; then
				channels_file=/dev/stdin
			else
				channels_file=$param_f
			fi
		}
		$option_h && usage
 		$option_v && version
		$option_q && warning() { :; }
		$option_L && authorize
	}

	# We need an access token. Read it from disk if the environment
	# variable is empty.
	[ -z "${access_token:=$TWITCH_API_TOKEN}" ] && {
		read_token || :
	}

	# If the access token is still empty, we have to get one by
	# authorizing this program via twitch.
	[ -z "$access_token" ] && {
		warning "Starting auth process because" \
			"of missing access token"
		authorize
	}

	# At least one channel name is mandatory, either via file or
	# operand.
	! [ -r "$channels_file" ] && [ $# -eq 0 ] && {
		error 1 "Cannot read channels file '$channels_file'"
	}

	# See above why this warning is disabled.
	# shellcheck disable=2154
	list_channels "$option_l" "$@"
}

##########################################################################

# Disable warnings about unused variables and word splitting.
# shellcheck disable=2034,2046
set_defaults() {
	set -e

	trap 'clean_exit' EXIT TERM
	trap 'clean_exit HUP' HUP
	trap 'clean_exit INT' INT

	IFS=' '
	set -- $(printf '\n \r \t \033')
	nl=$1 cr=$2 tab=$3 esc=$4
	IFS=\ $tab
	oifs=$IFS

	client_id=qabj6ffmjn431ca44gccoas72ywrs38
	api_url=https://api.twitch.tv/helix
	auth_url=https://id.twitch.tv
	redirect_port=65010
	redirect_uri=https://127.0.0.1:$redirect_port
	curl_opts='--fail --globoff --compressed --no-progress-meter'
	cfg_home=${XDG_CONFIG_HOME:-${CONFIG_HOME:-$HOME/.config}}
	prefix=twitch
	channels_file=$cfg_home/$prefix/channels
	token_file=$cfg_home/$prefix/token
	access_token=
}

# For a given optstring, this function sets the variables
# "option_<optchar>" to true/false and "param_<optchar>" to its parameter.
parse_options() {
	for _opt in $options; do
		# The POSIX spec does not say anything about spaces in the
		# optstring, so lets get rid of them.
		_optstring=$_optstring$_opt
		eval "option_${_opt%:}=false"
		unset "param_${_opt%:}"
	done

	while getopts ":$_optstring" _opt; do
		case $_opt in
			:) usage "option '$OPTARG' requires a parameter" ;;
			\?) usage "unrecognized option '$OPTARG'" ;;
			*)
				eval "option_$_opt=true"
				[ -n "$OPTARG" ] &&
					eval "param_$_opt=\$OPTARG"
			;;
		esac
	done
	unset _opt _optstring OPTARG
}

verbose() { printf %s\\n "$*" >&2; }
version() { printf %s\\n "$version_text"; exit; }
warning() { printf '%s: %s\n' "$prog_name" "$*" >&2; }

error() {
	_error=${1:-1}
	shift
	printf '%s: Error: %s\n' "$prog_name" "$*" >&2
	exit "$_error"
}

usage() {
	[ $# -ne 0 ] && {
		exec >&2
		printf '%s: %s\n\n' "$prog_name" "$*"
	}
	printf %s\\n "$help_text"
	exit ${1:+1}
}

clean_exit() {
	_exit_status=$?
	trap - EXIT

	[ $# -ne 0 ] && {
		trap - "$1"
		kill -s "$1" -$$
	}
	exit "$_exit_status"
}

##########################################################################

check_deps() {
	for _arg do
		command -v -- "$_arg" >/dev/null 2>&1 ||
			error 1 "Missing dependency: $_arg"
	done
}

authorize() {
	_auth_state=$(LC_CTYPE=C tr -dc "[:alnum:]" </dev/urandom |
		dd bs=1 count=32 2>/dev/null)
	x=$auth_url/oauth2/authorize
	x=$x\?client_id=$client_id
	x=$x\&response_type=token
	x=$x\&state=$xauth_state
	x=$x\&redirect_uri=$redirect_uri
	x=$x\&scope=
	x=$x\&force_verify=true
	_auth_url=$x

	x="Visit the following link and press 'Authorize'. After"
	x="$x authorizing, you${nl}will be redirected to a non-existing"
	x="$x website.$nl$nl${esc}[4m$xauth_url${esc}[0m$nl${nl}From the"
	x="$x current URL (in your web-browsers address bar), make sure"
	x="$x the$nl'state' parameter matches:$nl$nl$xauth_state$nl$nl"
	x="${x}Then copy the 'access_token' parameter from the URL and"
	x="$x enter it here.$nl${nl}Enter token: "

	printf '%s' "$x" >&2
	read -r access_token </dev/tty

	write_token "$access_token"

	printf '\n' >&2
}

write_token() {
	[ -z "$1" ] &&
		error 1 "Token is empty"

	_dir=${token_file%/*}

	! [ -d "$_dir" ] &&
		mkdir -p "$_dir"

	printf '%s\n' "$1" >"$token_file"
}

read_token() {
	! [ -r "$token_file" ] &&
		return 1

	read -r access_token _ <"$token_file" || :
}

list_channels() {
	check_deps curl jq

	_long_listing=$1
	shift

	[ -r "$channels_file" ] && {
		while read -r _user; do
			_users="${_users}user_login=$_user&"
		done <"$channels_file"
	}

	for _user do
		_users="${_users}user_login=$_user&"
	done

	_url="$api_url/streams?$_users"

	# Word splitting `$curl_opts` is intended here.
	# shellcheck disable=2086
	_response=$(curl $curl_opts \
		-H "Authorization: Bearer $access_token" \
		-H "Client-ID: $client_id" \
		-X GET \
		"$_url")

	# We don't pipe `curl` directly to `jq`, so the script can exit
	# in case `curl` has an error. Only the exit status of the
	# pipelines last command is considered otherwise.
	printf '%s\n' "$_response" \
	| jq -jr --arg long "$_long_listing" '.data[] |
		if $long == "true" then
			"\u001b[1m\(.user_name)\u001b[m ("
		else
			"\(.user_name) "
		end,

		.viewer_count // 0,

		if (.viewer_count // 0) == 1 then
			" viewer"
		else
			" viewers"
		end,

		if $long == "true" then
			") http://twitch.tv/\(.user_name)\n",
			"\(.title // "no title")\n\n"
		else
			" http://twitch.tv/\(.user_name)\n"
		end
	'
}

main "$@"

#!/bin/bash
# Copyright 1999-2010 Gentoo Foundation

# revdep-rebuild: Reverse dependency rebuilder.
# Original Author: Stanislav Brabec
# Rewrite Author: Michael A. Smith
# Current Maintainer: Paul Varner <fuzzyray@gentoo.org>

# TODO:
# - Use more /etc/init.d/functions.sh
# - Try to reduce the number of global vars

##
# Global Variables:

# Must-be-blank:
unset GREP_OPTIONS

# Readonly variables:
declare -r APP_NAME="revdep-rebuild" # # The name of this application
declare -r VERSION="git"
declare -r OIFS="$IFS"         # Save the IFS
declare -r     ENV_FILE=0_env.rr     # Contains environment variables
declare -r   FILES_FILE=1_files.rr   # Contains a list of files to search
declare -r  LDPATH_FILE=2_ldpath.rr  # Contains the LDPATH
declare -r  BROKEN_FILE=3_broken.rr  # Contains the list of broken files
declare -r  ERRORS_FILE=3_errors.rr  # Contains the ldd error output
declare -r     RAW_FILE=4_raw.rr     # Contains the raw list of packages
declare -r  OWNERS_FILE=4_owners.rr  # Contains the file owners
declare -r    PKGS_FILE=4_pkgs.rr    # Contains the unsorted bare package names
declare -r EBUILDS_FILE=4_ebuilds.rr # Contains the unsorted atoms
                                     # (Appropriately slotted or versioned)
declare -r   ORDER_FILE=5_order.rr   # Contains the sorted atoms
declare -r  STATUS_FILE=6_status.rr  # Contains the ldd error output
declare -ra FILES=(
	"$ENV_FILE"
	"$FILES_FILE"
	"$LDPATH_FILE"
	"$BROKEN_FILE"
	"$ERRORS_FILE"
	"$RAW_FILE"
	"$OWNERS_FILE"
	"$PKGS_FILE"
	"$EBUILDS_FILE"
	"$ORDER_FILE"
	"$STATUS_FILE"
)

# "Boolean" variables: Considered "true" if it has any value at all
# "True" indicates we should...
declare FULL_LD_PATH           # ...search across the COMPLETE_LD_LIBRARY_PATH
declare KEEP_TEMP              # ...not delete tempfiles from the current run
declare ORDER_PKGS             # ...sort the atoms in deep dependency order
declare PACKAGE_NAMES          # ...emerge by slot, not by versionated atom
declare RM_OLD_TEMPFILES       # ...remove tempfiles from prior runs
declare SEARCH_BROKEN          # ...search for broken libraries and binaries
declare SEARCH_SYMBOLS         # ...search for broken binaries with undefined symbols
declare VERBOSE                # ...give verbose output

# Globals that impact portage directly:
declare EMERGE_DEFAULT_OPTS    # String of options portage assumes to be set
declare EMERGE_OPTIONS         # Array of options to pass to portage
declare PORTAGE_NICENESS       # Renice to this value
declare PORTAGE_ROOT           # The root path for portage
declare REVDEP_REBUILD_DEFAULT_OPTS # String of default emerge options for revdep-rebuild

# Customizable incremental variables:
# These variables can be prepended to either by setting the variable in
# your environment prior to execution, or by placing an entry in
# /etc/make.conf.
#
# An entry of "-*" means to clear the variable from that point forward.
# Example: env SEARCH_DIRS="/usr/bin -*" revdep-rebuild will set SEARCH_DIRS
# to contain only /usr/bin
declare LD_LIBRARY_MASK  # Mask of specially evaluated libraries
declare SEARCH_DIRS      # List of dirs to search for executables and libraries
declare SEARCH_DIRS_MASK # List of dirs not to search

# Other globals:
declare OLDPROG                # Previous pass through the progress meter
declare EXACT_PKG              # Versionated atom to emerge
declare HEAD_TEXT              # Feedback string about the search
declare NOCOLOR                # Set to "true" not to output term colors
declare OK_TEXT                # Feedback about a search which found no errors
declare RC_NOCOLOR             # Hack to insure we respect NOCOLOR
declare REBUILD_LIST           # Array of atoms to emerge
declare SKIP_LIST              # Array of atoms that cannot be emerged (masked?)
declare SONAME                 # Soname/soname path pattern given on commandline
declare SONAME_SEARCH          # Value of SONAME modified to match ldd's output
declare WORKING_TEXT           # Feedback about the search
declare WORKING_DIR            # Working directory where cache files are kept

main() {
	# preliminary setup
	portage_settings
	get_opts "$@"
	setup_portage
	setup_search_paths_and_masks
	get_search_env
	[[ $QUIET -ne 1 ]] && echo

	# Search for broken binaries
	get_files
	get_ldpath
	main_checks

	# Associate broken binaries with packages to rebuild
	if [[ $PACKAGE_NAMES ]]; then
		get_packages
		clean_packages
		assign_packages_to_ebuilds
	else
		get_exact_ebuilds
	fi

	# Rebuild packages owning broken binaries
	get_build_order
	rebuild

	# All done
	cleanup
}
##
# Refuse to delete anything before we cd to our tmpdir
# (See mkdir_and_cd_to_tmpdir()
rm() {
	eerror "I was instructed to rm '$@'"
	die 1 "Refusing to delete anything before changing to temporary directory."
}
: <<'EW'
##
# GNU find has -executable, but if our users' finds do not have that flag
# we emulate it with this function. Also emulates -writable and -readable.
# Usage: find PATH ARGS -- use find like normal, except use -executable instead
# of various versions of -perm /+ blah blah and hacks
find() {
	hash find || { die 1 'find not found!'; }
	# We can be pretty sure find itself should be executable.
	local testsubject="$(type -P find)"
	if [[ $(command find "$testsubject" -executable 2> /dev/null) ]]; then
		unset -f find # We can just use the command find
	elif [[ $(command find "$testsubject" -perm /u+x 2> /dev/null) ]]; then
		find() {
			a=(${@//-executable/-perm \/u+x})
			a=(${a[@]//-writable/-perm \/u+w})
			a=(${a[@]//-readable/-perm \/r+w})
			command find "${a[@]}"
		}
	elif [[ $(command find "$testsubject" -perm +u+x 2> /dev/null) ]]; then
		find() {
			a=(${@//-executable/-perm +u+x})
			a=(${a[@]//-writable/-perm +u+w})
			a=(${a[@]//-readable/-perm +r+w})
			command find "${a[@]}"
		}
	else # Last resort
		find() {
			a=(${@//-executable/-exec test -x '{}' \; -print})
			a=(${a[@]//-writable/-exec test -w '{}' \; -print})
			a=(${a[@]//-readable/-exec test -r '{}' \; -print})
			command find "${a[@]}"
		}
	fi
	find "$@"
}
EW

print_usage() {
cat << EOF
${APP_NAME}: (${VERSION})

Copyright (C) 2003-2010 Gentoo Foundation, Inc.
This is free software; see the source for copying conditions.

Usage: $APP_NAME [OPTIONS] [--] [EMERGE_OPTIONS]

Broken reverse dependency rebuilder.

  -C, --nocolor        Turn off colored output
  -d, --debug          Print way too much information (uses bash's set -xv)
  -e, --exact          Emerge based on exact package version
  -h, --help           Print this usage
  -i, --ignore         Ignore temporary files from previous runs
  -k, --keep-temp      Do not delete temporary files on exit
  -L, --library NAME   Unconditionally emerge existing packages that use the
      --library=NAME   library with NAME. NAME can be a full path to the
                       library or a basic regular expression (man grep)
  -l, --no-ld-path     Do not set LD_LIBRARY_PATH
  -o, --no-order       Do not check the build order
                       (Saves time, but may cause breakage.)
  -p, --pretend        Do a trial run without actually emerging anything
                       (also passed to emerge command)
  -P, --no-progress    Turn off the progress meter
  -q, --quiet          Be less verbose (also passed to emerge command)
  -u, --search-symbols Search for undefined symbols (may have false positives)
  -v, --verbose        Be more verbose (also passed to emerge command)

Calls emerge, options after -- are ignored by $APP_NAME
and passed directly to emerge.

Report bugs to <http://bugs.gentoo.org>

EOF
}
##
# Usage: progress i n
#        i: current item
#        n: total number of items to process
progress() {
	if [[ -t 1 ]]; then
		progress() {
			local curProg=$(( $1 * 100 / $2 ))
			(( curProg == OLDPROG )) && return # no change, output nothing
			OLDPROG="$curProg" # must be a global variable
			(( $1 == $2 )) && local lb=$'\n'
			echo -ne '\r                         \r'"[ $curProg% ] $lb"
		}
		progress $@
	else # STDOUT is not a tty. Disable progress meter.
		progress() { :; }
	fi
}
##
# Usage: countdown n
#        n: number of seconds to count
countdown() {
	local i
	for ((i=1; i<$1; i++)); do
		echo -ne '\a.'
		((i<$1)) && sleep 1
	done
	echo -e '\a.'
}
##
# Replace whitespace with linebreaks, normalize repeated '/' chars, and sort -u
# (If any libs have whitespace in their filenames, someone needs punishment.)
clean_var() {
	awk '
		BEGIN {FS = "[[:space:]]"}

		{
			for(i = 1; i <= NF; ++i) {
				if($i ~ /-\*/)
					exit
				else if($i){
					gsub(/\/\/+/, "/", $i)
					print $i
				}
			}
		}' | sort -u
}
##
# Exit and optionally output to sterr
die() {
	local status=$1
	shift

	# Check if eerror has been loaded.
	# Its loaded _after_ opt parsing but not before due to RC_NOCOLOR.
	type eerror &> /dev/null

	if [[ $? -eq 0 ]];
	then
		eerror "$@"
	else
		echo " * ${@}" >> /dev/stderr
	fi
	exit $status
}
##
# What to do when dynamic linking is consistent
clean_exit() {
	if [[ ! $KEEP_TEMP ]]; then
		rm -f "${FILES[@]}"
		if [[ "$WORKING_DIR" != "/var/cache/${APP_NAME}" ]]; then
			# Remove the working directory
			builtin cd; rmdir "$WORKING_DIR"
		fi
	fi
	if [[ $QUIET -ne 1 ]];
	then
		echo
		einfo "$OK_TEXT... All done. "
	fi
	exit 0
}
##
# Get the name of the package that owns a file or list of files given as args.
# NOTE: depends on app-misc/realpath!
get_file_owner() {
	local IFS=$'\n'

	rpath=$(realpath "${*}" 2>/dev/null)
	# To ensure we always have something in rpath...
	[[ -z $rpath ]] && rpath=${*}

	# Workaround for bug 280341
	mlib=$(echo ${*}|sed 's:/lib/:/lib64/:')
	[[ "${*}" == "${mlib}" ]] && mlib=$(echo ${*}|sed 's:/lib64/:/lib/:')

	# Add a space to the end of each object name to prevent false
	# matches, for example /usr/bin/dia matching /usr/bin/dialog (bug #196460).
	# The same for "${rpath} ".
	# Don't match an entry with a '-' at the start of the package name. This
	# prevents us from matching invalid -MERGING entries. (bug #338031)
	find -L /var/db/pkg -type f -name CONTENTS -print0 |
		xargs -0 grep -m 1 -Fl -e "${*} " -e "${rpath} " -e "${mlib} " |
		sed 's:/var/db/pkg/\(.*\)/\([^-].*\)/CONTENTS:\1/\2:'
}
##
# Normalize some EMERGE_OPTIONS
normalize_emerge_opts() {
	# Normalize some EMERGE_OPTIONS
	EMERGE_OPTIONS=(${EMERGE_OPTIONS[@]/%-p/--pretend})
	EMERGE_OPTIONS=(${EMERGE_OPTIONS[@]/%-f/--fetchonly})
	EMERGE_OPTIONS=(${EMERGE_OPTIONS[@]/%-v/--verbose})
}
##
# Use the color preference from portage
setup_color() {
	# This should still work if NOCOLOR is set by the -C flag or in the user's
	# environment.
	[[ $NOCOLOR = yes || $NOCOLOR = true ]] && export RC_NOCOLOR=yes # HACK! (grr)
	# TODO: Change location according to Bug 373219
	# Remove /etc/init.d/functions.sh once everything is migrated
	if [ -e /lib/gentoo/functions.sh ]; then
		. /lib/gentoo/functions.sh
	elif [ -e /etc/init.d/functions.sh ]; then
		. /etc/init.d/functions.sh
	else
		echo "Unable to find functions.sh"
		exit 1
	fi
}
##
# Die if an argument is missing.
die_if_missing_arg() {
	[[ ! $2 || $2 = -* ]] && die 1 "Missing expected argument to $1"
}
##
# Die because an option is not recognized.
die_invalid_option() {
	# Can't use eerror and einfo because this gets called before function.sh
	# is sourced
	echo
	echo  "Encountered unrecognized option $1." >&2
	echo
	echo  "$APP_NAME no longer automatically passes unrecognized options to portage."
	echo  "Separate emerge-only options from revdep-rebuild options with the -- flag."
	echo
	echo  "For example, $APP_NAME -v -- --ask"
	echo
	echo  "See the man page or $APP_NAME -h for more detail."
	echo
	exit 1
}
##
# Warn about deprecated options.
warn_deprecated_opt() {
	# Can't use eerror and einfo because this gets called before function.sh
	# is sourced
	echo
	echo "Encountered deprecated option $1." >&2
	[[ $2 ]] && echo "Please use $2 instead." >&2
}
##
# Get whole-word commandline options preceded by two dashes.
get_longopts() {
	case $1 in
		                               --nocolor) export NOCOLOR="yes";;
		                              --no-color) warn_deprecated_opt "$1" "--nocolor"
		                                          export NOCOLOR="yes";;
		                                 --debug) set -xv;;
		                                 --exact) unset PACKAGE_NAMES;;
		                                  --help) print_usage
		                                          exit 0;;
		                                --ignore) RM_OLD_TEMPFILES=1;;
		                             --keep-temp) KEEP_TEMP=1;;
		                             --library=*) # TODO: check for invalid values
		                                          SONAME="${1#*=}"
		                                          unset SEARCH_BROKEN;;
		            --soname=*|--soname-regexp=*) # TODO: check for invalid values
		                                          warn_deprecated_opt "${1%=*}" "--library"
		                                          SONAME="${1#*=}"
		                                          unset SEARCH_BROKEN;;
		                               --library) # TODO: check for invalid values
		                                          die_if_missing_arg $1 $2
		                                          shift
		                                          SONAME="$1"
		                                          unset SEARCH_BROKEN;;
		                --soname|--soname-regexp) # TODO: check for invalid values
		                                          warn_deprecated_opt "$1" "--library"
		                                          die_if_missing_arg $1 $2
		                                          shift
		                                          SONAME="$1"
		                                          unset SEARCH_BROKEN;;
		                            --no-ld-path) unset FULL_LD_PATH;;
		                              --no-order) unset ORDER_PKGS;;
		                           --no-progress) progress() { :; };;
		                               --pretend) EMERGE_OPTIONS+=("--pretend")
		                                          PRETEND=1;;
		                                 --quiet) progress() { :; }
		                                          QUIET=1
		                                          EMERGE_OPTIONS+=($1);;
		                        --search-symbols) SEARCH_SYMBOLS=1;;
		                               --verbose) VERBOSE=1
		                                          EMERGE_OPTIONS+=("--verbose");;
		                         --extra-verbose) warn_deprecated_opt "$1" "--verbose"
		                                          VERBOSE=1
		                                          EMERGE_OPTIONS+=("--verbose");;
		                         --package-names) # No longer used, since it is the
		                                          # default. We accept it for
		                                          # backwards compatibility.
		                                          warn_deprecated_opt "$1"
		                                          PACKAGE_NAMES=1;;
		                                       *) die_invalid_option $1;;
	esac
}

##
# Get single-letter commandline options preceded by a single dash.
get_shortopts() {
	local OPT OPTSTRING OPTARG OPTIND
	while getopts ":CdehikL:loPpquvX" OPT; do
		case "$OPT" in
			C) # TODO: Match syntax with the rest of gentoolkit
			   export NOCOLOR="yes";;
			d) set -xv;;
			e) unset PACKAGE_NAMES;;
			h) print_usage
			   exit 0;;
			i) RM_OLD_TEMPFILES=1;;
			k) KEEP_TEMP=1;;
			L) # TODO: Check for invalid values
			   SONAME="${OPTARG#*=}"
			   unset SEARCH_BROKEN;;
			l) unset FULL_LD_PATH;;
			o) unset ORDER_PKGS;;
			P) progress() { :; };;
			p) EMERGE_OPTIONS+=("--pretend")
			   PRETEND=1;;
			q) progress() { :; }
			   QUIET=1
			   EMERGE_OPTIONS+=("--quiet");;
			u) SEARCH_SYMBOLS=1;;
			v) VERBOSE=1
			   EMERGE_OPTIONS+=("--verbose");;
			X) # No longer used, since it is the default.
			   # We accept it for backwards compatibility.
			   warn_deprecated_opt "-X"
			   PACKAGE_NAMES=1;;
			*) die_invalid_option "-$OPTARG";;
		esac
	done
}
##
# Get command-line options.
get_opts() {
	local avoid_utils
	local -a args
	echo_v() { ewarn "$@"; }
	unset VERBOSE KEEP_TEMP EMERGE_OPTIONS RM_OLD_TEMPFILES
	ORDER_PKGS=1
	PACKAGE_NAMES=1
	SONAME="not found"
	SEARCH_BROKEN=1
	FULL_LD_PATH=1

	while [[ $1 ]]; do
		case $1 in
			--) shift
			    EMERGE_OPTIONS+=("$@")
			    break;;
			-*) while true; do
			      args+=("$1")
			      shift
			      [[ ${1:--} = -* ]] && break
			    done
			    if [[ ${args[0]} = --* ]]; then
			      get_longopts  "${args[@]}"
			    else
			      get_shortopts "${args[@]}"
			    fi;;
			 *) die_invalid_option "$1";;
		esac
		unset args
	done

	setup_color
	normalize_emerge_opts

	# If the user is not super, add --pretend to EMERGE_OPTIONS
	if [[ ${EMERGE_OPTIONS[@]} != *--pretend* && $UID -ne 0 ]]; then
		ewarn "You are not superuser. Adding --pretend to emerge options."
		EMERGE_OPTIONS+=(--pretend)
	fi
}
##
# Is there a --pretend or --fetchonly flag in the EMERGE_OPTIONS array?
is_real_merge() {
	[[ ${EMERGE_OPTIONS[@]} != *--pretend* &&
	   ${EMERGE_OPTIONS[@]} != *--fetchonly* ]]
}
##
# Clean up temporary files and exit
cleanup_and_die() {
	rm -f "$@"
	die 1 "  ...terminated. Removing incomplete $@."
}
##
# Clean trap
clean_trap() {
	trap "cleanup_and_die $*" SIGHUP SIGINT SIGQUIT SIGABRT SIGTERM
	rm -f "$@"
}
##
# Returns 0 if the first arg is found in the remaining args, 1 otherwise
# (Returns 2 if given fewer than 2 arguments)
has() {
	(( $# > 1 )) || return 2
	local IFS=$'\a' target="$1"
	shift
	[[ $'\a'"$*"$'\a' = *$'\a'$target$'\a'* ]]
}
##
# Dies when it can't change directories
cd() {
	if builtin cd -P "$@"; then
		if [[ $1 != $PWD ]]; then
			# Some symlink malfeasance is going on
			die 1 "Working directory expected to be $1, but it is $PWD"
		fi
	else
		die 1 "Unable to change working directory to '$@'"
	fi
}
##
# Tries not to delete any files or directories it shouldn't
setup_rm() {
	##
	# Anything in the FILES array in tmpdir is fair game for removal
	rm() {
		local i	IFS=$'\a'
		[[ $APP_NAME ]] || die 1 '$APP_NAME is not defined! (This is a bug.)'
		case $@ in
			*/*|*-r*|*-R*) die 1 "Oops, I'm not allowed to delete that. ($@)";;
		esac
		for i; do
			# Don't delete files that are not listed in the array
			# Allow no slashes or recursive deletes at all.
			case $i in
				*/*|-*r*|-*R*) :;;        # Not OK
				           -*) continue;; # OK
			esac
			has "$i" "${FILES[@]}" && continue
			die 1 "Oops, I'm not allowed to delete that. ($@)"
		done
		command rm "$@"
	}
	# delete this setup function so it's harmless to re-run
	setup_rm() { :; }
}
##
# Make our temporary files directory
# $1 - directory name
# $2 - user name
verify_tmpdir() {
	if [[ ! $1 ]]; then
		die 1 'Temporary file path is unset! (This is a bug.)'
	elif [[ -d $1 ]]; then
		cd "$1"
	else
		die 1 "Unable to find a satisfactory location for temporary files ($1)"
	fi
	[[ $VERBOSE ]] && einfo "Temporary cache files are located in $PWD"
	setup_rm
}
get_search_env() {
	local new_env
	local old_env
	local uid=$(python -c 'import os; import pwd; print(pwd.getpwuid(os.getuid())[0])')
	# Find a place to put temporary files
	if [[ "$uid" == "root" ]]; then
		local tmp_target="/var/cache/${APP_NAME}"
	else
		local tmp_target="$(mktemp -d -t revdep-rebuild.XXXXXXXXXX)"
	fi

	# From here on all work is done inside the temporary directory
	verify_tmpdir "$tmp_target"
	WORKING_DIR="$tmp_target"

	if [[ $SEARCH_BROKEN ]]; then
		SONAME_SEARCH="$SONAME"
		HEAD_TEXT="broken by a package update"
		OK_TEXT="Dynamic linking on your system is consistent"
		WORKING_TEXT="consistency"
	else
		# first case is needed to test against /path/to/foo.so
		if [[ $SONAME = /* ]]; then
			# Set to "<space>$SONAME<space>"
			SONAME_SEARCH=" $SONAME "
			# Escape the "/" characters
			SONAME_SEARCH="${SONAME_SEARCH//\//\\/}"
		else
			# Set to "<tab>$SONAME<space>"
			SONAME_SEARCH=$'\t'"$SONAME "
		fi
		HEAD_TEXT="using $SONAME"
		OK_TEXT="There are no dynamic links to $SONAME"
		unset WORKING_TEXT
	fi

	# If any of our temporary files are older than 1 day, remove them all
	if [[ ! $KEEP_TEMP ]]; then
		while read; do
			RM_OLD_TEMPFILES=1
			break
		done < <(find -L . -maxdepth 1 -type f -name '*.rr' -mmin +1440 -print 2>/dev/null)
	fi

	# Compare old and new environments
	# Don't use our previous files if environment doesn't match
	new_env=$(
		# We do not care if these emerge options change
		EMERGE_OPTIONS=(${EMERGE_OPTIONS[@]//--pretend/})
		EMERGE_OPTIONS=(${EMERGE_OPTIONS[@]//--fetchonly/})
		EMERGE_OPTIONS=(${EMERGE_OPTIONS[@]//--verbose/})
		cat <<- EOF
			SEARCH_DIRS="$SEARCH_DIRS"
			SEARCH_DIRS_MASK="$SEARCH_DIRS_MASK"
			LD_LIBRARY_MASK="$LD_LIBRARY_MASK"
			PORTAGE_ROOT="$PORTAGE_ROOT"
			EMERGE_OPTIONS="${EMERGE_OPTIONS[@]}"
			ORDER_PKGS="$ORDER_PKGS"
			FULL_LD_PATH="$FULL_LD_PATH"
		EOF
	)
	if [[ -r "$ENV_FILE" && -s "$ENV_FILE" ]]; then
		old_env=$(<"$ENV_FILE")
		if [[ $old_env != $new_env ]]; then
			ewarn 'Environment mismatch from previous run, deleting temporary files...'
			RM_OLD_TEMPFILES=1
		fi
	else
		# No env file found, silently delete any other tempfiles that may exist
		RM_OLD_TEMPFILES=1
	fi

	# If we should remove old tempfiles, do so
	if [[ $RM_OLD_TEMPFILES ]]; then
		rm -f "${FILES[@]}"
	else
		for file in "${FILES[@]}"; do
			if [ -e "$file" ]; then
				chown ${uid}:portage "$file"
				chmod 600 "$file"
			fi
		done
	fi

	# Save the environment in a file for next time
	echo "$new_env" > "$ENV_FILE"

	[[ $VERBOSE ]] && echo $'\n'"$APP_NAME environment:"$'\n'"$new_env"

	if [[ $QUIET -ne 1 ]];
	then
		echo
		einfo "Checking reverse dependencies"
		einfo "Packages containing binaries and libraries $HEAD_TEXT"
		einfo "will be emerged."
	fi
}

get_files() {
	[[ $QUIET -ne 1 ]] && einfo "Collecting system binaries and libraries"
	if [[ -r "$FILES_FILE" && -s "$FILES_FILE" ]]; then
		[[ $QUIET -ne 1 ]] && einfo "Found existing $FILES_FILE"
	else
		# Be safe and remove any extraneous temporary files
		# Don't remove 0_env.rr - The first file in the array
		rm -f "${FILES[@]:1}"

		clean_trap "$FILES_FILE"

		if [[ $SEARCH_DIRS_MASK ]]; then
			findMask=($SEARCH_DIRS_MASK)
			findMask="${findMask[@]/#/-o -path }"
			findMask="( ${findMask#-o } ) -prune -o"
		fi
		# TODO: Check this -- afaict SEARCH_DIRS isn't an array, so this should just be $SEARCH_DIRS?
		find ${SEARCH_DIRS[@]} $findMask -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x -o \
			-name '*.so' -o -name '*.so.*' -o -name '*.la' \) -print 2> /dev/null |
			sort -u > "$FILES_FILE" ||
			die $? "find failed to list binary files (This is a bug.)"
		[[ $QUIET -ne 1 ]] && einfo "Generated new $FILES_FILE"
	fi
}
parse_ld_so_conf() {
	# FIXME: not safe for paths with spaces
	local include
	for path in $(sed '/^#/d;s/#.*$//' < /etc/ld.so.conf); do
		if [[ $include = true ]]; then
			for include_path in $(sed '/^#/d;s/#.*$//' /etc/${path} 2>/dev/null); do
				echo $include_path
			done
			include=""
			continue
		fi
		if [[ $path != include ]]; then
			echo $path
		else
			include="true"
			continue
		fi
	done
}
get_ldpath() {
	local COMPLETE_LD_LIBRARY_PATH
	[[ $SEARCH_BROKEN && $FULL_LD_PATH ]] || return
	[[ $QUIET -ne 1 ]] && einfo 'Collecting complete LD_LIBRARY_PATH'
	if [[ -r "$LDPATH_FILE" && -s "$LDPATH_FILE" ]]; then
		[[ $QUIET -ne 1 ]] && einfo "Found existing $LDPATH_FILE."
	else
		clean_trap "$LDPATH_FILE"
		# Ensure that the "trusted" lib directories are at the start of the path
		COMPLETE_LD_LIBRARY_PATH=(
			/lib*
			/usr/lib*
			$(parse_ld_so_conf)
			$(sed 's:/[^/]*$::' < "$FILES_FILE" | sort -ru)
		)
		IFS=':'
		COMPLETE_LD_LIBRARY_PATH="${COMPLETE_LD_LIBRARY_PATH[*]}"
		IFS="$OIFS"
		echo "$COMPLETE_LD_LIBRARY_PATH" > "$LDPATH_FILE"
		[[ $QUIET -ne 1 ]] && einfo "Generated new $LDPATH_FILE"
	fi
}
main_checks() {
	local target_file
	local -a files
	local i=0
	local ldd_output
	local ldd_status
	local numFiles
	local COMPLETE_LD_LIBRARY_PATH
	local message
	local broken_lib
	if [[ $SEARCH_BROKEN && $FULL_LD_PATH ]]; then
		[[ -r "$LDPATH_FILE" && -s "$LDPATH_FILE" ]] ||
			die 1 "Unable to find $LDPATH_FILE"
		COMPLETE_LD_LIBRARY_PATH=$(<"$LDPATH_FILE")
	fi
	[[ $QUIET -ne 1 ]] && einfo "Checking dynamic linking $WORKING_TEXT"
	if [[ -r "$BROKEN_FILE" && -s "$BROKEN_FILE" ]]; then
		[[ $QUIET -ne 1 ]] && einfo "Found existing $BROKEN_FILE."
	else
		clean_trap "$BROKEN_FILE" "$ERRORS_FILE"
		files=($(<"$FILES_FILE"))
		numFiles="${#files[@]}"
		for target_file in "${files[@]}"; do
			if [[ $target_file != *.la ]]; then
				# Note: double checking seems to be faster than single with complete path
				# (special add ons are rare).
				ldd_output=$(ldd -d -r "$target_file" 2>> "$ERRORS_FILE" | sort -u)
				ldd_status=$? # TODO: Check this for problems with sort
				# HACK: if LD_LIBRARY_MASK is null or undefined grep -vF doesn't work
				if grep -vF "${LD_LIBRARY_MASK:=$'\a'}" <<< "$ldd_output" |
					grep -q -E "$SONAME_SEARCH"; then
					if [[ $SEARCH_BROKEN && $FULL_LD_PATH ]]; then
						if LD_LIBRARY_PATH="$COMPLETE_LD_LIBRARY_PATH" ldd "$target_file" 2>/dev/null |
							grep -vF "$LD_LIBRARY_MASK" | grep -q -E "$SONAME_SEARCH"; then
							# FIXME: I hate duplicating code
							# Only build missing direct dependencies
							MISSING_LIBS=$(
								expr='s/[[:space:]]*\([^[:space:]]*\) => not found/\1/p'
								sed -n "$expr" <<< "$ldd_output"
							)
							REQUIRED_LIBS=$(
								expr='s/^[[:space:]]*NEEDED[[:space:]]*\([^[:space:]]*\).*/\1/p';
								objdump -x "$target_file" | grep NEEDED | sed "$expr" | sort -u
							)
							MISSING_LIBS=$(grep -F "$REQUIRED_LIBS" <<< "$MISSING_LIBS")
							if [[ $MISSING_LIBS ]]; then
								echo "obj $target_file" >> "$BROKEN_FILE"
								echo_v "  broken $target_file (requires $MISSING_LIBS)"
							fi
						fi
					else
						# FIXME: I hate duplicating code
						# Only rebuild for direct dependencies
						MISSING_LIBS=$(
							expr="s/^[[:space:]]*\([^[:space:]]*\).*$/\1/p"
							sort -u <<< "$ldd_output" | grep -E "$SONAME" | sed -n "$expr"
						)
						REQUIRED_LIBS=$(
							expr='s/^[[:space:]]*NEEDED[[:space:]]*\([^[:space:]]*\).*/\1/p';
							objdump -x "$target_file" | grep NEEDED | sed "$expr" | sort -u
						)
						MISSING_LIBS=$(grep -F "$REQUIRED_LIBS" <<< "$MISSING_LIBS")
						if [[ $MISSING_LIBS ]]; then
							echo "obj $target_file" >> "$BROKEN_FILE"
							if [[ $SEARCH_BROKEN ]]; then
								echo_v "  broken $target_file (requires $MISSING_LIBS)"
							else
								echo_v "  found $target_file"
							fi
						fi
					fi
				fi
				# Search for symbols not defined
				if [[ $SEARCH_BROKEN ]]; then
					# Look for symbol not defined errors
					if grep -vF "${LD_LIBRARY_MASK:=$'\a'}" <<< "$ldd_output" |
						grep -q -E 'symbol .* not defined'; then
						message=$(awk '/symbol .* not defined/ {ORS = FS; for(i = 1; i < NF; ++i) print $i; printf "\n"}' <<< "$ldd_output")
						broken_lib=$(awk '/symbol .* not defined/ {print $NF}' <<< "$ldd_output" | \
							sed 's/[()]//g')
						echo "obj $broken_lib" >> "$BROKEN_FILE"
						echo_v "  broken $broken_lib ($message)"
					fi
				fi
				# Look for undefined symbol error if not a .so file
				if [[ $SEARCH_BROKEN && $SEARCH_SYMBOLS ]]; then
					case $target_file in
					*.so|*.so.*)
						;;
					*)
						if grep -vF "${LD_LIBRARY_MASK:=$'\a'}" <<< "$ldd_output" |
							grep -q -F 'undefined symbol:'; then
							message=$(awk '/undefined symbol:/ {print $3}' <<< "$ldd_output")
							message="${message//$'\n'/ }"
							echo "obj $target_file" >> "$BROKEN_FILE"
							echo_v "  broken $target_file (undefined symbols(s): $message)"
						fi
						;;
					esac
				fi
			elif [[ $SEARCH_BROKEN ]]; then
				# Look for broken .la files
				la_SEARCH_DIRS="$(parse_ld_so_conf)"
				la_search_dir=""
				la_broken=""
				la_lib=""
				for depend in $(
					awk -F"[=']" '/^dependency_libs/{
						print $3
					}' "$target_file"
				); do
					if [[ $depend = /* && ! -e $depend ]]; then
						echo "obj $target_file" >> "$BROKEN_FILE"
						echo_v "  broken $target_file (requires $depend)"
					elif [[ $depend = -[LR]/* ]]; then
						if ! [[ $'\n'${la_SEARCH_DIRS}$'\n' == *$'\n'${depend#-?}$'\n'* ]]; then
							la_SEARCH_DIRS+=$'\n'"${depend#-?}"
						fi
					elif [[ $depend = "-l"* ]]; then
						la_lib="lib${depend#-l}"
						la_broken="yes"
						IFS=$'\n'
						for la_search_dir in $la_SEARCH_DIRS; do
							if [[ -e ${la_search_dir}/${la_lib}.so || -e ${la_search_dir}/${la_lib}.a ]]; then
								la_broken="no"
							fi
						done
						IFS="$OIFS"
						if [[ $la_broken = yes ]]; then
							echo "obj $target_file" >> "$BROKEN_FILE"
							echo_v "  broken $target_file (requires $depend)"
						fi
					fi
				done
				unset la_SEARCH_DIRS la_search_dir la_broken la_lib
			fi
			[[ $VERBOSE ]] &&
				progress $((++i)) $numFiles $target_file ||
				progress $((++i)) $numFiles
		done
		if [[ $SEARCH_BROKEN && -f $ERRORS_FILE ]]; then
			# Look for missing version
			while read target_file; do
				echo "obj $target_file" >> "$BROKEN_FILE"
				echo_v "  broken $target_file (no version information available)"
			done < <(
				# Regexify LD_LIBRARY_MASK. Exclude it from the search.
				LD_LIBRARY_MASK="${LD_LIBRARY_MASK//$'\n'/|}"
				awk -v ldmask="(${LD_LIBRARY_MASK//./\\\\.})" '
					/no version information available/ && $0 !~ ldmask {
						gsub(/[()]/, "", $NF)
						if (seen[$NF]++)  next
						print $NF
					}' "$ERRORS_FILE"
			)
		fi
		[[ -r "$BROKEN_FILE" && -s "$BROKEN_FILE" ]] || clean_exit
		sort -u "$BROKEN_FILE" -o "$BROKEN_FILE"
		[[ $QUIET -ne 1 ]] && einfo "Generated new $BROKEN_FILE"
	fi
}
get_packages() {
	local target_file
	local EXACT_PKG
	local PKG
	local obj
	einfo 'Assigning files to packages'
	if [[ -r "$RAW_FILE" && -s "$RAW_FILE" ]]; then
		einfo "Found existing $RAW_FILE"
	else
		clean_trap "$RAW_FILE" "$OWNERS_FILE"
		while read obj target_file; do
			EXACT_PKG=$(get_file_owner $target_file)
			if [[ $EXACT_PKG ]]; then
				# Strip version information
				PKG="${EXACT_PKG%%-r[[:digit:]]*}"
				PKG="${PKG%-*}"
				echo "$EXACT_PKG" >> "$RAW_FILE"
				echo "$target_file -> $EXACT_PKG" >> "$OWNERS_FILE"
				echo_v "  $target_file -> $PKG"
			else
				ewarn " !!! $target_file not owned by any package is broken !!!"
				echo "$target_file -> (none)" >> "$OWNERS_FILE"
				echo_v "  $target_file -> (none)"
			fi
		done < "$BROKEN_FILE"
		[[ $QUIET -ne 1 ]] && einfo "Generated new $RAW_FILE and $OWNERS_FILE"
	fi
	# if we find '(none)' on every line, exit out
	if ! grep -qvF '(none)' "$OWNERS_FILE"; then
		ewarn "Found some broken files, but none of them were associated with known packages"
		ewarn "Unable to proceed with automatic repairs."
		ewarn "The broken files are listed in $OWNERS_FILE"
		if [[ $VERBOSE ]]; then
			ewarn "The broken files are:"
			while read filename junk; do
				ewarn "  $filename"
			done < "$OWNERS_FILE"
		fi
		exit 0 # FIXME: Should we exit 1 here?
	fi
}
clean_packages() {
	[[ $QUIET -ne 1 ]] && einfo 'Cleaning list of packages to rebuild'
	if [[ -r "$PKGS_FILE" && -s "$PKGS_FILE" ]]; then
		[[ $QUIET -ne 1 ]] && einfo "Found existing $PKGS_FILE"
	else
		sort -u "$RAW_FILE" > "$PKGS_FILE"
		[[ $QUIET -ne 1 ]] && einfo "Generated new $PKGS_FILE"
	fi
}
assign_packages_to_ebuilds() {
	local EXACT_PKG
	local PKG
	local SLOT
	einfo 'Assigning packages to ebuilds'
	if [[ -r "$EBUILDS_FILE" && -s "$EBUILDS_FILE" ]]; then
		einfo "Found existing $EBUILDS_FILE"
	elif [[ -r "$PKGS_FILE" && -s "$PKGS_FILE" ]]; then
			clean_trap "$EBUILDS_FILE"
			while read EXACT_PKG; do
				# Get the slot
				PKG="${EXACT_PKG%%-r[[:digit:]]*}"
				PKG="${PKG%-*}"
				SLOT=$(</var/db/pkg/$EXACT_PKG/SLOT)
				echo "$PKG:$SLOT"
			done < "$PKGS_FILE" > "$EBUILDS_FILE"
			[[ $QUIET -ne 1 ]] && einfo "Generated new $EBUILDS_FILE"
	else
		einfo 'Nothing to rebuild.'
		die 1 '(The program should have already quit, so this is a minor bug.)'
	fi
}
get_exact_ebuilds() {
	einfo 'Assigning files to ebuilds'
	if [[ -r $EBUILDS_FILE && -s $EBUILDS_FILE ]]; then
		einfo "Found existing $EBUILDS_FILE"
	elif [[ -r $BROKEN_FILE && -s $BROKEN_FILE ]]; then
		rebuildList=" $(<"$BROKEN_FILE") "
		rebuildList=(${rebuildList//[[:space:]]obj[[:space:]]/ })
		get_file_owner "${rebuildList[@]}" | sed 's/^/=/' > "$EBUILDS_FILE"
		[[ $QUIET -ne 1 ]] && einfo "Generated new $EBUILDS_FILE"
	else
		einfo 'Nothing to rebuild.'
		die 1 '(The program should have already quit, so this is a minor bug.)'
	fi
}
list_skipped_packages() {
	ewarn
	ewarn 'Portage could not find any version of the following packages it could build:'
	ewarn "${SKIP_LIST[@]}"
	ewarn
	ewarn '(Perhaps they are masked, blocked, or removed from portage.)'
	ewarn 'Try to emerge them manually.'
	ewarn
}
get_build_order() {
	local -a OLD_EMERGE_DEFAULT_OPTS=("${EMERGE_DEFAULT_OPTS[@]}")
	local RAW_REBUILD_LIST
	local REBUILD_GREP
	local i
	if [[ ! $ORDER_PKGS ]]; then
		einfo 'Skipping package ordering'
		return
	fi
	[[ $QUIET -ne 1 ]] && einfo 'Evaluating package order'
	if [[ -r "$ORDER_FILE" && -s "$ORDER_FILE" ]]; then
		einfo "Found existing $ORDER_FILE"
	else
		clean_trap "$ORDER_FILE"
		RAW_REBUILD_LIST=$(<"$EBUILDS_FILE")
		if [[ $RAW_REBUILD_LIST ]]; then
			EMERGE_DEFAULT_OPTS=(--nospinner --pretend --oneshot --quiet)
			RAW_REBUILD_LIST=($RAW_REBUILD_LIST) # convert into array
			# If PACKAGE_NAMES is defined we're using slots, not versions
			if [[ $PACKAGE_NAMES ]]; then
				# Eliminate atoms that can't be built
				for i in "${!RAW_REBUILD_LIST[@]}"; do
					if [[ "${RAW_REBUILD_LIST[i]}" = *[A-Za-z]* ]]; then
						portageq best_visible "$PORTAGE_ROOT" "${RAW_REBUILD_LIST[i]}" >/dev/null && continue
						SKIP_LIST+=("${RAW_REBUILD_LIST[i]}")
					fi
					unset RAW_REBUILD_LIST[i]
				done
				# If RAW_REBUILD_LIST is empty, then we have nothing to build.
				if (( ${#RAW_REBUILD_LIST[@]} == 0 )); then
					if (( ${#SKIP_LIST[@]} == 0 )); then
						ewarn "The list of packages to skip is empty, but there are no"
						ewarn "packages listed to rebuild either. (This is a bug.)"
					else
						list_skipped_packages
					fi
					die 1 'Warning: Portage cannot rebuild any of the necessary packages.'
				fi
			fi
			RAW_REBUILD_LIST="${RAW_REBUILD_LIST[@]}"

			# We no longer determine the package order ourselves.  Instead we call emerge
			# with --complete-graph=y in the rebuild function.
			if false ; then
				REBUILD_GREP=$(emerge --nodeps $RAW_REBUILD_LIST | sed 's/\[[^]]*\]//g')
				if (( ${PIPESTATUS[0]} == 0 )); then
					emerge --deep $RAW_REBUILD_LIST |
						sed 's/\[[^]]*\]//g' |
						grep -F "$REBUILD_GREP" > "$ORDER_FILE"
				fi

				# Here we use the PIPESTATUS from the second emerge, the --deep one.
				if (( ${PIPESTATUS[0]} != 0 )); then
					eerror
					eerror 'Warning: Failed to resolve package order.'
					eerror 'Will merge in arbitrary order'
					eerror
					cat <<- EOF
						Possible reasons:
						- An ebuild is no longer in the portage tree.
						- An ebuild is masked, use /etc/portage/packages.keyword
							and/or /etc/portage/package.unmask to unmask it
					EOF
					countdown 5
					rm -f "$ORDER_FILE"
				fi
			else
				echo "$RAW_REBUILD_LIST" > "$ORDER_FILE"
			fi
			EMERGE_DEFAULT_OPTS=("${OLD_EMERGE_DEFAULT_OPTS[@]}")
		else
			einfo 'Nothing to rebuild.'
			die 1 '(The program should have already quit, so this is a minor bug.)'
		fi
	fi
	[[ -r "$ORDER_FILE" && -s "$ORDER_FILE" && $QUIET -ne 1 ]] && einfo "Generated new $ORDER_FILE"
}

show_unowned_files() {
	if grep -qF '(none)' "$OWNERS_FILE"; then
		ewarn "Found some broken files that weren't associated with known packages"
		ewarn "The broken files are:"
		while read filename junk; do
			[[ $junk = *none* ]] && ewarn "  $filename"
		done < "$OWNERS_FILE" | awk '!s[$0]++' # (omit dupes)
	fi
}

# Get multiple portage variables at once to speedup revdep-rebuild.
portage_settings() {
	local ORIG_SEARCH_DIRS="$SEARCH_DIRS"
	local ORIG_SEARCH_DIRS_MASK="$SEARCH_DIRS_MASK"
	local ORIG_LD_LIBRARY_MASK="$LD_LIBRARY_MASK"
	unset SEARCH_DIRS
	unset SEARCH_DIRS_MASK
	unset LD_LIBRARY_MASK

	eval $(portageq envvar -v PORTAGE_ROOT PORTAGE_NICENESS EMERGE_DEFAULT_OPTS NOCOLOR SEARCH_DIRS SEARCH_DIRS_MASK LD_LIBRARY_MASK REVDEP_REBUILD_DEFAULT_OPTS)
	export NOCOLOR

	# Convert quoted paths to array.
	eval "EMERGE_DEFAULT_OPTS=(${EMERGE_DEFAULT_OPTS})"
	eval "REVDEP_REBUILD_DEFAULT_OPTS=(${REVDEP_REBUILD_DEFAULT_OPTS})"
	SEARCH_DIRS="$ORIG_SEARCH_DIRS $SEARCH_DIRS"
	SEARCH_DIRS_MASK="$ORIG_SEARCH_DIRS_MASK $SEARCH_DIRS_MASK"
	LD_LIBRARY_MASK="$ORIG_LD_LIBRARY_MASK $LD_LIBRARY_MASK"

	# Replace EMERGE_DEFAULT_OPTS with REVDEP_REBUILD_DEFAULT_OPTS (if it exists)
	if [[ -n ${REVDEP_REBUILD_DEFAULT_OPTS} ]]; then
		EMERGE_DEFAULT_OPTS=("${REVDEP_REBUILD_DEFAULT_OPTS[@]}")
	fi

}

##
# Setup portage and the search paths
setup_portage() {
	# Obey PORTAGE_NICENESS (which is incremental to the current nice value)
	if [[ $PORTAGE_NICENESS ]]; then
		current_niceness=$(nice)
		let PORTAGE_NICENESS=${current_niceness}+${PORTAGE_NICENESS}
		renice $PORTAGE_NICENESS $$ > /dev/null
		# Since we have already set our nice value for our processes,
		# reset PORTAGE_NICENESS to zero to avoid having emerge renice again.
		export PORTAGE_NICENESS="0"
	fi

	PORTAGE_ROOT="${PORTAGE_ROOT:-/}"
}

##
# Setup the paths to search (and filter the ones to avoid)
setup_search_paths_and_masks() {
	local configfile sdir mdir skip_me filter_SEARCH_DIRS

	[[ $QUIET -ne 1 ]] && einfo "Configuring search environment for $APP_NAME"

	# Update the incremental variables using /etc/profile.env, /etc/ld.so.conf,
	# portage, and the environment

	# Read the incremental variables from environment and portage
	# Until such time as portage supports these variables as incrementals
	# The value will be what is in /etc/make.conf
#	SEARCH_DIRS+=" "$(unset SEARCH_DIRS; portageq envvar SEARCH_DIRS)
#	SEARCH_DIRS_MASK+=" "$(unset SEARCH_DIRS_MASK; portageq envvar SEARCH_DIRS_MASK)
#	LD_LIBRARY_MASK+=" "$(unset LD_LIBRARY_MASK; portageq envvar LD_LIBRARY_MASK)

	# Add the defaults
	if [[ -d /etc/revdep-rebuild ]]; then
		for configfile in /etc/revdep-rebuild/*; do
			SEARCH_DIRS+=" "$(. $configfile; echo $SEARCH_DIRS)
			SEARCH_DIRS_MASK+=" "$(. $configfile; echo $SEARCH_DIRS_MASK)
			LD_LIBRARY_MASK+=" "$(. $configfile; echo $LD_LIBRARY_MASK)
		done
	else
		SEARCH_DIRS+=" /bin /sbin /usr/bin /usr/sbin /lib* /usr/lib*"
		SEARCH_DIRS_MASK+=" /opt/OpenOffice /usr/lib/openoffice"
		LD_LIBRARY_MASK+=" libodbcinst.so libodbc.so libjava.so libjvm.so"
	fi

	# Get the ROOTPATH and PATH from /etc/profile.env
	if [[ -r "/etc/profile.env" && -s "/etc/profile.env" ]]; then
		SEARCH_DIRS+=" "$(. /etc/profile.env; /usr/bin/tr ':' ' ' <<< "$ROOTPATH $PATH")
	fi

	# Get the directories from /etc/ld.so.conf
	if [[ -r /etc/ld.so.conf && -s /etc/ld.so.conf ]]; then
		SEARCH_DIRS+=" "$(parse_ld_so_conf)
	fi

	# Set the final variables
	SEARCH_DIRS=$(clean_var <<< "$SEARCH_DIRS")
	SEARCH_DIRS_MASK=$(clean_var <<< "$SEARCH_DIRS_MASK")
	LD_LIBRARY_MASK=$(clean_var <<< "$LD_LIBRARY_MASK")
	# Filter masked paths from SEARCH_DIRS
	for sdir in ${SEARCH_DIRS} ; do
		skip_me=
		for mdir in ${SEARCH_DIRS_MASK}; do
			[[ ${sdir} == ${mdir}/* ]] && skip_me=1 && break
		done
		[[ -n ${skip_me} ]] || filter_SEARCH_DIRS+=" ${sdir}"
	done
	SEARCH_DIRS=$(clean_var <<< "${filter_SEARCH_DIRS}")
	[[ $SEARCH_DIRS ]] || die 1 "No search defined -- this is a bug."
}
##
# Rebuild packages owning broken binaries
rebuild() {
	if [[ -r $ORDER_FILE && -s $ORDER_FILE ]]; then
		# The rebuild list contains category/package:slot atoms.
		# Do not prepend with an '=' sign.
		# REBUILD_LIST=( $(<"$ORDER_FILE") )
		# REBUILD_LIST="${REBUILD_LIST[@]/#/=}"
		REBUILD_LIST=$(<"$ORDER_FILE")
	else
		REBUILD_LIST=$(sort -u "$EBUILDS_FILE")
	fi

	trap "kill 0" SIGHUP SIGINT SIGQUIT SIGABRT SIGTERM

	[[ $QUIET -ne 1 ]] && einfo 'All prepared. Starting rebuild'
	echo "emerge --complete-graph=y --oneshot ${EMERGE_DEFAULT_OPTS[@]} ${EMERGE_OPTIONS[@]} $REBUILD_LIST"

	is_real_merge && countdown 10

	# Link file descriptor #6 with stdin so --ask will work
	exec 6<&0

	# Run in background to correctly handle Ctrl-C
	{
		emerge --complete-graph=y --oneshot "${EMERGE_DEFAULT_OPTS[@]}" ${EMERGE_OPTIONS[@]} $REBUILD_LIST <&6
		echo $? > "$STATUS_FILE"
	} &
	wait

	# Now restore stdin from fd #6, where it had been saved, and close fd #6 ( 6<&- ) to free it for other processes to use.
	exec 0<&6 6<&-
}
##
# Finish up
cleanup() {
	EMERGE_STATUS=$(<"$STATUS_FILE")
	if is_real_merge; then
		if [[ (( $EMERGE_STATUS != 0 )) ]]; then
			ewarn
			ewarn "$APP_NAME failed to emerge all packages."
			ewarn 'you have the following choices:'
			einfo "- If emerge failed during the build, fix the problems and re-run $APP_NAME."
			einfo '- Use /etc/portage/package.keywords to unmask a newer version of the package.'
			einfo "  (and remove $ORDER_FILE to be evaluated again)"
			einfo '- Modify the above emerge command and run it manually.'
			einfo '- Compile or unmerge unsatisfied packages manually,'
			einfo '  remove temporary files, and try again.'
			einfo '  (you can edit package/ebuild list first)'
			einfo
			einfo 'To remove temporary files, please run:'
			einfo "rm ${WORKING_DIR}/*.rr"
			show_unowned_files
			exit $EMERGE_STATUS
		else
			trap_cmd() {
				eerror "terminated. Please remove the temporary files manually:"
				eerror "rm ${WORKING_DIR}/*.rr"
				exit 1
			}
			[[ "${SKIP_LIST[@]}" != "" ]] && list_skipped_packages
			trap trap_cmd SIGHUP SIGINT SIGQUIT SIGABRT SIGTERM
			einfo 'Build finished correctly. Removing temporary files...'
			einfo
			einfo 'You can re-run revdep-rebuild to verify that all libraries and binaries'
			einfo 'are fixed. Possible reasons for remaining inconsistencies include:'
			einfo '  orphaned files'
			einfo '  deep dependencies'
			einfo "  packages installed outside of portage's control"
			einfo '  specially-evaluated libraries'
			if [[ -r "$OWNERS_FILE" && -s "$OWNERS_FILE" ]]; then
				show_unowned_files
			fi
			[[ $KEEP_TEMP ]] || rm -f "${FILES[@]}"
		fi
	else
		einfo 'Now you can remove -p (or --pretend) from arguments and re-run revdep-rebuild.'
	fi
}

main "$@"

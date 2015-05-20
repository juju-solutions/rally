#!/usr/bin/env bash
#
# This script installs Rally.
# Specifically, it is able to install and configure
# Rally either globally (system-wide), or isolated in
# a virtual environment using the virtualenv tool.
#
# NOTE: The script assumes that you have the following
# programs already installed:
# -> Python 2.6, Python 2.7 or Python 3.4

set -e

PROG=$(basename "${0}")

running_as_root() {
  test "$(/usr/bin/id -u)" -eq 0
}

VERBOSE=""
ASKCONFIRMATION=1
OVERWRITEDIR="ask"
USEVIRTUALENV="no"

PYTHON2="$(which python || true)"
PYTHON3="$(which python3 || true)"
PYTHON=${PYTHON2:-$PYTHON3}
BASE_PIP_URL="http://10.245.162.102:3141/root/pypi/+simple/"
VIRTUALENV_191_URL="https://raw.github.com/pypa/virtualenv/1.9.1/virtualenv.py"
VIRTUALENV_CMD="virtualenv"

RALLY_GIT_URL=https://github.com/openstack/rally
RALLY_CONFIGURATION_DIR=/etc/rally
RALLY_DATABASE_DIR=/var/lib/rally/database
DBTYPE=sqlite
DBNAME=rally.sqlite

# Variable used by script_interrupted to know what to cleanup
CURRENT_ACTION="none"

## Exit status codes (mostly following <sysexits.h>)
# successful exit
EX_OK=0

# wrong command-line invocation
EX_USAGE=64

# missing dependencies (e.g., no C compiler)
EX_UNAVAILABLE=69

# wrong python version
EX_SOFTWARE=70

# cannot create directory or file
EX_CANTCREAT=73

# user aborted operations
EX_TEMPFAIL=75

# misused as: unexpected error in some script we call
EX_PROTOCOL=76

err () {
  echo "$PROG: $@" >&2
}

say () {
    echo "$PROG: $@";
}

# abort RC [MSG]
#
# Print error message MSG and abort shell execution with exit code RC.
# If MSG is not given, read it from STDIN.
#
abort () {
  local rc="$1"
  shift
  (echo -n "$PROG: ERROR: ";
      if [ $# -gt 0 ]; then echo "$@"; else cat; fi) 1>&2
  exit "$rc"
}

# die RC HEADER <<...
#
# Print an error message with the given header, then abort shell
# execution with exit code RC.  Additional text for the error message
# *must* be passed on STDIN.
#
die () {
  local rc="$1"
  header="$2"
  shift 2
  cat 1>&2 <<__EOF__
==========================================================
$PROG: ERROR: $header
==========================================================

__EOF__
  if [ $# -gt 0 ]; then
      # print remaining arguments one per line
      for line in "$@"; do
          echo "$line" 1>&2;
      done
  else
      # additional message text provided on STDIN
      cat 1>&2;
  fi
  cat 1>&2 <<__EOF__

If the above does not help you resolve the issue, please contact the
Rally team by sending an email to the OpenStack mailing list
openstack-dev@lists.openstack.org. Include the full output of this
script to help us identifying the problem.

Aborting installation!
__EOF__
  exit "$rc"
}

script_interrupted () {
    say "Interrupted by the user. Cleaning up..."
    [ -n "${VIRTUAL_ENV}" -a "${VIRTUAL_ENV}" == "$VENVDIR" ] && deactivate

    case $CURRENT_ACTION in
        creating_venv|venv-created)
            if [ -d "$VENVDIR" ]
            then
                if ask_yn "Do you want to delete the virtual environment in '$VENVDIR'?"
                then
                    rm -rf "$VENVDIR"
                fi
            fi
            ;;
        downloading-src|src-downloaded)
            # This is only relevant when installing with --system,
            # otherwise the git repository is cloned into the
            # virtualenv directory
            if [ -d "$SOURCEDIR" ]
            then
                if ask_yn "Do you want to delete the downloaded source in '$SOURCEDIR'?"
                then
                    rm -rf "$SOURCEDIR"
                fi
            fi
            ;;
    esac

    die $EX_TEMPFAIL "Script interrupted by the user" <<__EOF__

__EOF__
}

trap script_interrupted SIGINT

print_usage () {
    cat <<__EOF__
Usage: $PROG [options]

This script will install Rally in your system.

Options:
  -h, --help             Print this help text
  -v, --verbose          Verbose mode
  -s, --system           Install system-wide.
  -d, --target DIRECTORY Install Rally virtual environment into DIRECTORY.
                         (Default: $HOME/rally if not root).
  -f, --overwrite        Remove target directory if it already exists.
  -y, --yes              Do not ask for confirmation: assume a 'yes' reply
                         to every question.
  -D, --dbtype TYPE      Select the database type. TYPE can be one of
                         'sqlite', 'mysql', 'postgres'.
                         Default: sqlite
  --db-user USER         Database user to use. Only used when --dbtype
                         is either 'mysql' or 'postgres'.
  --db-password PASSWORD Password of the database user. Only used when
                         --dbtype is either 'mysql' or 'postgres'.
  --db-host HOST         Database host. Only used when --dbtype is
                         either 'mysql' or 'postgres'
  --db-name NAME         Name of the database. Only used when --dbtype is
                         either 'mysql' or 'postgres'
  -p, --python EXE       The python interpreter to use. Default: $(which python).

__EOF__
}

# ask_yn PROMPT
#
# Ask a Yes/no question preceded by PROMPT.
# Set the env. variable REPLY to 'yes' or 'no'
# and return 0 or 1 depending on the users'
# answer.
#
ask_yn () {
    if [ $ASKCONFIRMATION -eq 0 ]; then
        # assume 'yes'
        REPLY='yes'
        return 0
    fi
    while true; do
        read -p "$1 [yN] " REPLY
        case "$REPLY" in
            [Yy]*)    REPLY='yes'; return 0 ;;
            [Nn]*|'') REPLY='no';  return 1 ;;
            *)        say "Please type 'y' (yes) or 'n' (no)." ;;
        esac
    done
}

have_command () {
  type "$1" >/dev/null 2>/dev/null
}

require_command () {
  if ! have_command "$1"; then
    abort 1 "Could not find required command '$1' in system PATH. Aborting."
  fi
}

require_python () {
    require_command "$PYTHON"
    if $PYTHON -c 'import sys; sys.exit(sys.version_info[:2] >= (2, 6))'; then
        die $EX_UNAVAILABLE "Wrong version of python is installed" <<__EOF__

Rally requires Python version 2.6+. Unfortunately, we do not support
your version of python: $($PYTHON -V 2>&1|sed 's/python//gi').

If a version of Python suitable for using Rally is present in some
non-standard location, you can specify it from the command line by
running this script again with option '--python' followed by the path of
the correct 'python' binary.
__EOF__
    fi
}

have_sw_package () {
    # instead of guessing which distribution this is, we check for the
    # package manager name as it basically identifies the distro
    if have_command dpkg; then
        (dpkg -l "$1" | egrep -q ^i ) >/dev/null 2>/dev/null
    elif have_command rpm; then
        rpm -q "$1" >/dev/null 2>/dev/null
    fi
}

which_missing_packages () {
    local missing=''
    for pkgname in "$@"; do
        if have_sw_package "$pkgname"; then
            continue;
        else
            missing="$missing $pkgname"
        fi
    done
    echo "$missing"
}

# Download command
# TODO: move this logic into install_required_sw
if ! have_command wget && ! have_command curl; then
    if ask_yn "You need ether wget or curl to be installed. Install wget?"; then
        apt-get install --yes wget || yum install -y wget
    fi
fi

if have_command wget
then
    download () { wget -nv $VERBOSE --no-check-certificate -O "$@"; }
elif have_command curl
then
    download () { curl $VERBOSE --insecure -L -s -o "$@"; }
else
    die $EX_UNAVAILABLE "Neither 'curl' nor 'wget' command found." <<__EOF__
The script needs either one of the 'curl' or 'wget' commands to run.
Please, install at least one of them using the software manager of
your distribution, or downloading it from internet:

- wget: http://www.gnu.org/software/wget/
- curl: http://curl.haxx.se/
__EOF__
fi

download_from_pypi () {
    local pkg=$1
    local url=$(download - "$BASE_PIP_URL"/"$pkg"/ | sed -n '/source\/.\/'"$pkg"'.*gz/ { s:.*href="\([^#"]*\)["#].*:\1:g; p; }' | sort | tail -1)
    if [ -n "$url" ]; then
        download "$(basename "$url")" "$BASE_PIP_URL"/"$pkg"/"$url"
    else
        die $EX_PROTOCOL "Package '$pkg' not found on PyPI!" <<__EOF__
Unable to download package '$pkg' from PyPI.
__EOF__
    fi
}

install_required_sw () {
    # instead of guessing which distribution this is, we check for the
    # package manager name as it basically identifies the distro
    local missing pkg_manager
    if have_command apt-get; then
        # Debian/Ubuntu
        missing=$(which_missing_packages build-essential libssl-dev libffi-dev python-dev libxml2-dev libxslt1-dev libpq-dev git)

        if [ "$ASKCONFIRMATION" -eq 0 ]; then
            pkg_manager="apt-get install --yes"
        else
            pkg_manager="apt-get install"
        fi

    elif have_command yum; then
        # RHEL/CentOS
        missing=$(which_missing_packages gcc libffi-devel python-devel openssl-devel gmp-devel libxml2-devel libxslt-devel postgresql-devel git)

        if [ "$ASKCONFIRMATION" -eq 0 ]; then
            pkg_manager="yum install -y"
        else
            pkg_manager="yum install"
        fi
    elif have_command zypper; then
        # SuSE
        warn "Cannot check if requisite software is installed: SuSE and compatible Linux distributions are not yet supported. I'm proceeding anyway, but you may run into errors later."
    else
        # MacOSX maybe?
        warn "Cannot determine what package manager this Linux distribution has, so I cannot check if requisite software is installed. I'm proceeding anyway, but you may run into errors later."
    fi

    if ! have_command pip; then
        missing="$missing python-pip"
    fi

    if [ -n "$missing" ]; then
        cat <<__EOF__
The following software packages need to be installed
in order for Rally to work: $missing

__EOF__

        # If we are root
        if running_as_root; then
            cat <<__EOF__
In order to install the required software you would need to run as
'root' the following command:

    $pkg_manager $missing

__EOF__
            # ask if we have to install it
            if ask_yn "Do you want me to install these packages for you?"; then
                # install
                if [[ "$missing" == *python-pip* ]]; then
                    missing=$(echo "$missing" | sed 's/python-pip//')
                    if ! $pkg_manager python-pip; then
                        if ask_yn "Error installing python-pip. Install from external source?"; then
                            local pdir=$(mktemp -d)
                            local getpip="$pdir/get-pip.py"
                            download "$getpip" https://raw.github.com/pypa/pip/master/contrib/get-pip.py
                            if ! $PYTHON "$getpip"; then
                                die $EX_PROTOCOL "Error while installing python-pip from external source."
                            fi
                        else
                            die $EX_TEMPFAIL "Please install python-pip manually."
                        fi
                    fi
                fi
                if ! $pkg_manager $missing; then
                    die $EX_UNAVAILABLE "Error while installing $missing"
                fi
                # installation successful
            else # don't want to install the packages
                die $EX_UNAVAILABLE "missing software prerequisites" <<__EOF__
Please, install the required software before installing Rally

__EOF__
            fi
        else # Not running as root
            cat <<__EOF__
There is a small chance that the required software
is actually installed though we failed to detect it,
so you may choose to proceed with Rally installation
anyway.  Be warned however, that continuing is very
likely to fail!

__EOF__
            if ask_yn "Proceed with installation anyway?"
            then
                warn "Proceeding with installation at your request... keep fingers crossed!"
            else
                die $EX_UNAVAILABLE "missing software prerequisites" <<__EOF__
Please ask your system administrator to install the missing packages,
or, if you have root access, you can do that by running the following
command from the 'root' account:

    $pkg_manager $missing

__EOF__
            fi
        fi
    fi

}

install_db_connector () {
    case $DBTYPE in
        mysql)
            pip install pymysql
            ;;
        postgres)
            pip install psycopg2
            ;;
    esac
}

install_virtualenv () {
    DESTDIR=$1

    if [ -n "$VIRTUAL_ENV" ]; then
        cat <<__EOF__

ERROR
=====

A virtual environment seems to be already *active*. This will cause
this script to FAIL.

Run 'deactivate', then run this script again.

__EOF__
        exit $EX_SOFTWARE
    fi

    # Use the latest virtualenv that can use `.tar.gz` files
    VIRTUALENV_URL=$VIRTUALENV_191_URL
    VIRTUALENV_DST="$DESTDIR/virtualenv-191.py"
    mkdir -p $DESTDIR
    download $VIRTUALENV_DST $VIRTUALENV_URL
    VIRTUALENV_CMD="$PYTHON $VIRTUALENV_DST"

    # python virtualenv.py --[no,system]-site-packages $DESTDIR
    $VIRTUALENV_CMD $VERBOSE -p $PYTHON "$DESTDIR"

    . "$DESTDIR"/bin/activate

    # Recent versions of `pip` insist that setuptools>=0.8 is installed,
    # because they try to use the "wheel" format for any kind of package.
    # So we need to update setuptools, or `pip` will error out::
    #
    #     Wheel installs require setuptools >= 0.8 for dist-info support.
    #
    if pip wheel --help 1>/dev/null 2>/dev/null; then
        (cd "$DESTDIR" && download_from_pypi setuptools)
        if ! (cd "$DESTDIR" && tar -xzf setuptools-*.tar.gz && cd setuptools-* && python setup.py install);
        then
            die $EX_SOFTWARE \
                "Failed to install the latest version of Python 'setuptools'" <<__EOF__

The required Python package setuptools could not be installed.

__EOF__
        fi
    fi
}

setup_rally_configuration () {
    SRCDIR=$1
    ETCDIR=$RALLY_CONFIGURATION_DIR
    DBDIR=$RALLY_DATABASE_DIR

    [ -d "$ETCDIR" ] || mkdir -p "$ETCDIR"
    cp "$SRCDIR"/etc/rally/rally.conf.sample "$ETCDIR"/rally.conf

    [ -d "$DBDIR" ] || mkdir -p "$DBDIR"
    sed -i "s|#connection *=.*|connection = \"$DBCONNSTRING\"|" "$ETCDIR"/rally.conf
    rally-manage db recreate
}


### Main program ###
short_opts='d:vfsyhD:p:'
long_opts='target:,verbose,overwrite,system,yes,dbtype:,python:,db-user:,db-password:,db-host:,db-name:,help'

if [ "x$(getopt -T)" = 'x' ]; then
    # GNU getopt
    args=$(getopt --name "$PROG" --shell sh -l "$long_opts" -o "$short_opts" -- "$@")
    if [ $? -ne 0 ]; then
        abort 1 "Type '$PROG --help' to get usage information."
    fi
    # use 'eval' to remove getopt quoting
    eval set -- "$args"
else
    # old-style getopt, use compatibility syntax
    args=$(getopt "$short_opts" "$@")
    if [ $? -ne 0 ]; then
        abort 1 "Type '$PROG --help' to get usage information."
    fi
    eval set -- "$args"
fi

# Command line parsing
while true
do
    case "$1" in
        -d|--target)
            shift
            VENVDIR=$1
            ;;
        -h|--help)
            print_usage
            exit $EX_OK
            ;;
        -v|--verbose)
            VERBOSE="-v"
            ;;
        -s|--system)
            USEVIRTUALENV="no"
            ;;
        -f|--overwrite)
            OVERWRITEDIR=yes
            ;;
        -y|--yes)
            ASKCONFIRMATION=0
            OVERWRITEDIR=yes
            ;;
        -D|--dbtype)
            shift
            DBTYPE=$1
            case $DBTYPE in
                sqlite|mysql|postgres) break ;;
                *)
                    err "Invalid database type $DBTYPE."
                    print_usage
                    exit $EX_USAGE
                    ;;
            esac
            ;;
        --db-user)
            shift
            DBUSER=$1
            ;;
        --db-password)
            shift
            DBPASSWORD=$1
            ;;
        --db-host)
            shift
            DBHOST=$1
            ;;
        --db-name)
            shift
            DBNAME=$1
            ;;
        -p|--python)
            shift
            PYTHON=$1
            ;;
        --)
            shift
            break
            ;;
        *)
            err "An invalid option has been detected."
            print_usage
            exit $EX_USAGE
    esac
    shift
done

### Post-processing ###

if [ "$USEVIRTUALENV" == "no" ] && [ -n "$VENVDIR" ]; then
    die $EX_USAGE "Ambiguous arguments" <<__EOF__
Option -d/--target can not be used with --system.
__EOF__
fi

if running_as_root; then
    if [ -z "$VENVDIR" ]; then
        USEVIRTUALENV='no'
    fi
else
    if [ "$USEVIRTUALENV" == 'no' ]; then
        die $EX_USAGE "Insufficient privileges" <<__EOF__
Root permissions required in order to install system-wide.
As non-root user you may only install in virtualenv.
__EOF__
    fi
    if [ -z "$VENVDIR" ]; then
        VENVDIR="$HOME"/rally
    fi
fi

# Fix RALLY_DATABASE_DIR if virtualenv is used
if [ "$USEVIRTUALENV" = 'yes' ]
then
    RALLY_CONFIGURATION_DIR=~/.rally
    RALLY_DATABASE_DIR="$VENVDIR"/database
fi

if [ "$DBTYPE" != 'sqlite' ]
then
    if [ -z "$DBUSER" -o -z "$DBPASSWORD" -o -z "$DBHOST" -o -z "$DBNAME" ]
    then
        die $EX_USAGE "Missing mandatory options" <<__EOF__
When specifying a database type different than 'sqlite', you also have
to specify the database name, host, and username and password of a
valid user with write access to the database.

Please, re-run the script with valid values for the options:

    --db-host
    --db-name
    --db-user
    --db-password
__EOF__
    fi
    DBAUTH="$DBUSER:$DBPASSWORD@$DBHOST"
    DBCONNSTRING="$DBTYPE://$DBAUTH/$DBNAME"
else
    DBCONNSTRING="$DBTYPE:///${RALLY_DATABASE_DIR}/${DBNAME}"
fi

# check and install prerequisites
install_required_sw
require_python

# Install virtualenv, if required
if [ "$USEVIRTUALENV" = 'yes' ]; then
    if [ -d "$VENVDIR" ]
    then
        if [ $OVERWRITEDIR = 'ask' ]; then
            echo "Destination directory '$VENVDIR' already exists."
            echo "I can wipe it out in order to make a new installation,"
            echo "but this means any files in that directory, and the ones"
            echo "underneath it will be deleted."
            echo

            if ! ask_yn "Do you want to wipe the installation directory '$VENVDIR'?"
            then
                say "*Not* overwriting destination directory '$VENVDIR'."
                OVERWRITEDIR=no
            fi
        elif [ $OVERWRITEDIR = 'no' ]
        then
            die $EX_CANTCREAT "Unable to create virtualenv in '$VENVDIR': directory already exists." <<__EOF__
    The script was unable to create a virtual environment in "$VENVDIR"
    because the directory already exists.

    In order to proceed, you must take one of the following action:

    * delete the directory, or

    * run this script again adding '--overwrite' option, which will
      overwrite the $VENVDIR directory, or

    * specify a different path by running this script again adding the
      option "--target" followed by a non-existent directory.
__EOF__
        elif [ $OVERWRITEDIR = 'yes' ]; then
            echo "Removing directory $VENVDIR as requested."
            rm $VERBOSE -rf "$VENVDIR"
        else
            abort 66 "Internal error: unexpected value '$OVERWRITEDIR' for OVERWRITEDIR."
        fi
    fi

    echo "Installing Rally virtualenv in directory '$VENVDIR' ..."
    CURRENT_ACTION="creating-venv"
    if ! install_virtualenv "$VENVDIR"; then
        die $EX_PROTOCOL "Unable to create a new virtualenv in '$VENVDIR': 'virtualenv.py' script exited with code $rc." <<__EOF__
The script was unable to create a valid virtual environment.
__EOF__
    fi
    CURRENT_ACTION="venv-created"
    rc=0
fi

# Install rally
ORIG_WD=$(pwd)

BASEDIR=$(dirname "$(readlink -e "$0")")

# If we are inside the git repo, don't download it again.
if [ -d "$BASEDIR"/.git ]
then
    SOURCEDIR=$BASEDIR
else
    if [ "$USEVIRTUALENV" = 'yes' ]
    then
        SOURCEDIR="$VENVDIR"/src
    else
        SOURCEDIR="$ORIG_WD"/rally.git
    fi

    # Check if source directory is present
    if [ -d "$SOURCEDIR" ]
    then
        if [ $OVERWRITEDIR != 'yes' ]
        then
            echo "Source directory '$SOURCEDIR' already exists."
            echo "I can wipe it out in order to make a new installation,"
            echo "but this means any files in that directory, and the ones"
            echo "underneath it will be deleted."
            echo
            if ! ask_yn "Do you want to wipe the source directory '$SOURCEDIR'?"
            then
                say "*Not* overwriting destination directory '$SOURCEDIR'."
            fi
        fi
        if [ -d "$SOURCEDIR"/.git ]
        then
            echo "Assuming $SOURCEDIR already contains the Rally git repository."
        else
            die $EX_CANTCREAT "Unable to download git repository" <<__EOF__
Unable to download git repository.

__EOF__
        fi
    fi

    if ! [ -d "$SOURCEDIR"/.git ]
    then
        echo "Downloading Rally from subversion repository $RALLY_GIT_URL ..."
        CURRENT_ACTION="downloading-src"
        git clone "$RALLY_GIT_URL" "$SOURCEDIR"
        CURRENT_ACTION="src-downloaded"
    fi
fi

install_db_connector

# Install rally
cd "$SOURCEDIR"
# Install dependencies
pip install -i $BASE_PIP_URL $pbr
pip install -i $BASE_PIP_URL 'tox<=1.6.1'
# Install rally
# python setup.py install
pip install -i $BASE_PIP_URL .
cd "$ORIG_WD"

# Post-installation
if [ "$USEVIRTUALENV" = 'yes' ]
then
    # Fix bash_completion
    cat >> "$VENVDIR"/bin/activate <<__EOF__

. "$VENVDIR/etc/bash_completion.d/rally.bash_completion"
__EOF__

    cat <<__EOF__
==============================
Installation of Rally is done!
==============================

In order to work with Rally you have to enable the virtual environment
with the command:

    . $VENVDIR/bin/activate

You need to run the above command on every new shell you open before
using Rally, but just once per session.

Information about your Rally installation:

  * Method: virtualenv
  * Virtual Environment at: $VENVDIR
  * Database at: $RALLY_DATABASE_DIR
  * Configuration file at: $RALLY_CONFIGURATION_DIR

__EOF__
    setup_rally_configuration "$SOURCEDIR"
else
    setup_rally_configuration "$SOURCEDIR"

    cat <<__EOF__
==============================
Installation of Rally is done!
==============================

Rally is now installed in your system. Information about your Rally
installation:

  * Method: system
  * Database at: $RALLY_DATABASE_DIR
  * Configuration file at: $RALLY_CONFIGURATION_DIR

__EOF__
fi

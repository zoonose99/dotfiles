#!/usr/bin/env bash

function mainScript() {

  function _findBaseDir_() {
    # fincBaseDir locates the real directory of the script. similar to GNU readlink -n
    local SOURCE
    local DIR
    SOURCE="${BASH_SOURCE[0]}"
    while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
      DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
      SOURCE="$(readlink "$SOURCE")"
      [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
    done
    baseDir="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  }
  _findBaseDir_

  # Set Variables
  utilsFile="${baseDir}/lib/utils.sh"
  configFile="${baseDir}/lib/config-install.yaml"
  privateInstallScript="${baseDir}/private/privateInstall.sh"

  function sourceFiles() {
    if [ -f "$utilsFile" ]; then
      source "$utilsFile"
    else
      die "Can't find $utilsFile"
    fi
    if [ -f "$configFile" ]; then
      yamlConfigVariables="$tmpDir/yamlConfigVariables.txt"
      _parse_yaml_ "$configFile" > "$yamlConfigVariables"
      source "$yamlConfigVariables"
      # In verbose mode, echo the variables for debugging purposes
      if $verbose; then verbose "-- Config Variables --"; _readFile_ "$yamlConfigVariables"; fi
    else
      die "Can't find $configFile"
    fi
  }
  sourceFiles

  # Sets the flags passed to the script as an array to pass
  # on to child scripts
  scriptFlags=()
    ( $dryrun ) && scriptFlags+=(--dryrun)
    ( $quiet ) && scriptFlags+=(--quiet)
    ( $printLog ) && scriptFlags+=(--log)
    ( $verbose ) && scriptFlags+=(--verbose)
    ( $debug ) && scriptFlags+=(--debug)
    ( $strict ) && scriptFlags+=(--strict)

  #### Run Script Segments ###

  _runBootstrapScripts_() {
    local script
    local bootstrapScripts

    notice "Confirming we have prerequisites..."

    bootstrapScripts="${baseDir}/lib/bootstrap"
    if [ ! -d "$bootstrapScripts" ]; then die "Can't find install scripts."; fi

    # Run the bootstrap scripts in numerical order

    #Show detailed command information
    saveVerbose=$verbose
    verbose=true

    set +e # Don't quit install.sh when a sub-script fails
    for script in ${bootstrapScripts}/[0-9]*.sh; do
      . $script
    done
    set -e
    verbose=$saveVerbose
  }
  _runBootstrapScripts_

  _doSymlinks_() {
      filesToLink=("${symlinks[@]}") # array is populated from YAML
      _createSymlinks_ "Symlinks"
      unset filesToLink
  }
  _executeFunction_ "_doSymlinks_" "Create symlinks?"

  _privateRepo_() {

    if [ -f "$privateInstallScript" ]; then
      if seek_confirmation "Run Private install script"; then
        "$privateInstallScript" "${scriptFlags[*]}"
      fi
    else
      warning "Could not find private install script"
    fi
  }
  _privateRepo_

  _installHomebrewPackages_() {
    local tap
    local package
    local cask
    local testInstalled

    header "Installing Homebrew Packages"

    #confirm homebrew is installed
    if test ! "$(which brew)"; then
      die "Can not continue without homebrew."
      #notice "Installing Homebrew..."
      # ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
    fi

    #Show Brew Update can take forever if we're not bootstrapping. show the output
    saveVerbose=$verbose
    verbose=true

    # Make sure we’re using the latest Homebrew
    execute "brew update"

    # Reset verbose settings
    verbose=$saveVerbose

    # Upgrade any already-installed formulae
    execute "caffeinate -ism brew upgrade" "Upgrade existing formulae"

    # Install taps
    # shellcheck disable=2154
    for tap in "${homebrewTaps[@]}"; do
      tap=$(echo "$tap" | cut -d'#' -f1 | _trim_) # remove comments if exist
      execute "brew tap $tap"
    done

    # Install packages
    # shellcheck disable=2154
    for package in "${homebrewPackages[@]}"; do

      package=$(echo "$package" | cut -d'#' -f1 | _trim_) # remove comments if exist

      # strip flags from package names
      testInstalled=$(echo "$package" | cut -d' ' -f1 | _trim_)

      if brew ls --versions "$testInstalled" > /dev/null; then
        info "$testInstalled already installed"
      else
        execute "brew install $package" "Install $testInstalled"
      fi
    done

    # Install mac apps via homebrew cask
    # shellcheck disable=2154
    for cask in "${homebrewCasks[@]}"; do

      cask=$(echo "$cask" | cut -d'#' -f1 | _trim_) # remove comments if exist

      # strip flags from package names
      testInstalled=$(echo "$cask" | cut -d' ' -f1 | _trim_)

      if brew cask ls "$testInstalled" &> /dev/null; then
        info "$testInstalled already installed"
      else
        execute "brew cask install $cask" "Install $testInstalled"
      fi

    done

    # cleanup after ourselves
    execute "brew cleanup"
    execute "brew doctor"
  }
  _executeFunction_ "_installHomebrewPackages_" "Install Homebrew Packages"

  _installNodePackages_() {
    local package
    local npmPackages
    local modules

    header "Installing global node packages"

    #confirm node is installed
    if test ! "$(which node)"; then
      warning "Can not install npm packages without node"
      info "Run 'brew install node'"
      return
    fi

    # Grab packages already installed
    { pushd "$(npm config get prefix)/lib/node_modules"; installed=(*); popd; } >/dev/null

    #Show nodes's detailed install information
    saveVerbose=$verbose
    verbose=true

    # If comments exist in the list of npm packaged to be installed remove them
    # shellcheck disable=2154
    for package in "${nodePackages[@]}"; do
      npmPackages+=($(echo "$package" | cut -d'#' -f1 | _trim_) )
    done

    # Install packages that do not already exist
    modules=($(_setdiff_ "${npmPackages[*]}" "${installed[*]}"))
    if (( ${#modules[@]} > 0 )); then
      pushd $HOME > /dev/null; execute "npm install -g ${modules[*]}"; popd > /dev/null;
    else
      info "All node packages already installed"
    fi

    # Reset verbose settings
    verbose=$saveVerbose
  }
  _executeFunction_ "_installNodePackages_" "Install Node Packages"

  _installRubyPackages_() {

    header "Installing global ruby gems"

    # shellcheck disable=2154
    for gem in "${rubyGems[@]}"; do

      # Strip comments
      gem=$(echo "$gem" | cut -d'#' -f1 | _trim_)

      # strip flags from package names
      testInstalled=$(echo "$gem" | cut -d' ' -f1 | _trim_)

      if ! gem list $testInstalled -i >/dev/null; then
        pushd $HOME > /dev/null; execute "gem install $gem" "install $gem"; popd > /dev/null;
      else
        info "$testInstalled already installed"
      fi

    done
  }
  _executeFunction_ "_installRubyPackages_" "Install Ruby Packages"

  _runConfigureScripts_() {
    local script
    local configureScripts

    header "Running configure scripts"

    configureScripts="${baseDir}/lib/configure"
    if [ ! -d "$configureScripts" ]; then die "Can't find install scripts."; fi

    # Run the bootstrap scripts in numerical order

    set +e # Don't quit install.sh when a sub-script fails
    # Always show command responses
    for script in ${configureScripts}/[0-9]*.sh; do
      . $script
    done
    set -e
  }
  _runConfigureScripts_

  success "install.sh has completed"

} ## End mainscript

function _trapCleanup_() {
  echo ""
  # Delete temp files, if any
  [ -d "${tmpDir}" ] && rm -r "${tmpDir}"
  die "Exit trapped. In function: '${FUNCNAME[*]:1}'"
}

function safeExit() {
  # Delete temp files, if any
  if [ -d "${tmpDir}" ] ; then
    rm -r "${tmpDir}"
  fi
  trap - INT TERM EXIT
  exit
}

# Set Base Variables
# ----------------------
scriptName=$(basename "$0")

# Set Flags
quiet=false
printLog=false
verbose=false
force=false
strict=false
debug=false
dryrun=false
symlinksOK=false
args=()

# Set Colors
bold=$(tput bold)
reset=$(tput sgr0)
purple=$(tput setaf 171)
red=$(tput setaf 1)
green=$(tput setaf 76)
tan=$(tput setaf 3)
blue=$(tput setaf 38)
underline=$(tput sgr 0 1)

# Set Temp Directory
tmpDir="/tmp/${scriptName}.$RANDOM.$RANDOM.$RANDOM.$$"
(umask 077 && mkdir "${tmpDir}") || {
  die "Could not create temporary directory! Exiting."
}

# Logging
logFile="${HOME}/Library/Logs/${scriptName%.sh}.log"

# Logging & Feedback
# -----------------------------------------------------
function _alert() {
  if [ "${1}" = "error" ]; then local color="${bold}${red}"; fi
  if [ "${1}" = "warning" ]; then local color="${red}"; fi
  if [ "${1}" = "success" ]; then local color="${green}"; fi
  if [ "${1}" = "debug" ]; then local color="${purple}"; fi
  if [ "${1}" = "header" ]; then local color="${bold}${tan}"; fi
  if [ "${1}" = "input" ]; then local color="${bold}"; fi
  if [ "${1}" = "dryrun" ]; then local color="${blue}"; fi
  if [ "${1}" = "info" ] || [ "${1}" = "notice" ]; then local color=""; fi
  # Don't use colors on pipes or non-recognized terminals
  if [[ "${TERM}" != "xterm"* ]] || [ -t 1 ]; then color=""; reset=""; fi

  # Print to console when script is not 'quiet'
  if ${quiet}; then return; else
   echo -e "$(date +"%r") ${color}$(printf "[%7s]" "${1}") ${_message}${reset}";
  fi

  # Print to Logfile
  if ${printLog} && [ "${1}" != "input" ]; then
    color=""; reset="" # Don't use colors in logs
    echo -e "$(date +"%m-%d-%Y %r") $(printf "[%7s]" "${1}") ${_message}" >> "${logFile}";
  fi
}

function die ()       { local _message="${*} Exiting."; echo -e "$(_alert error)"; safeExit;}
function error ()     { local _message="${*}"; echo -e "$(_alert error)"; }
function warning ()   { local _message="${*}"; echo -e "$(_alert warning)"; }
function notice ()    { local _message="${*}"; echo -e "$(_alert notice)"; }
function info ()      { local _message="${*}"; echo -e "$(_alert info)"; }
function debug ()     { local _message="${*}"; echo -e "$(_alert debug)"; }
function success ()   { local _message="${*}"; echo -e "$(_alert success)"; }
function input()      { local _message="${*}"; echo -n "$(_alert input)"; }
function dryrun()      { local _message="${*}"; echo -e "$(_alert dryrun)"; }
function header()     { local _message="== ${*} ==  "; echo -e "$(_alert header)"; }
function verbose()    { if ${verbose}; then debug "$@"; fi }

# Options and Usage
# -----------------------------------
usage() {
  echo -n "${scriptName} [OPTION]... [FILE]...

This is a script template.  Edit this description to print help to users.

 ${bold}Options:${reset}
  --force           Skip all user interaction.  Implied 'Yes' to all actions.

  -n, --dryrun      Non-destructive. Makes no permanent changes.
  -q, --quiet       Quiet (no output)
  -l, --log         Print log to file
  -s, --strict      Exit script with null variables.  i.e 'set -o nounset'
  -v, --verbose     Output more information. (Items echoed to 'verbose')
  -d, --debug       Runs script in BASH debug mode (set -x)
  -h, --help        Display this help and exit
"
}

# Iterate over options breaking -ab into -a -b when needed and --foo=bar into
# --foo bar
optstring=h
unset options
while (($#)); do
  case $1 in
    # If option is of type -ab
    -[!-]?*)
      # Loop over each character starting with the second
      for ((i=1; i < ${#1}; i++)); do
        c=${1:i:1}

        # Add current char to options
        options+=("-$c")

        # If option takes a required argument, and it's not the last char make
        # the rest of the string its argument
        if [[ $optstring = *"$c:"* && ${1:i+1} ]]; then
          options+=("${1:i+1}")
          break
        fi
      done
      ;;

    # If option is of type --foo=bar
    --?*=*) options+=("${1%%=*}" "${1#*=}") ;;
    # add --endopts for --
    --) options+=(--endopts) ;;
    # Otherwise, nothing special
    *) options+=("$1") ;;
  esac
  shift
done
set -- "${options[@]}"
unset options

# Print help if no arguments were passed.
# Uncomment to force arguments when invoking the script
# -------------------------------------
#[[ $# -eq 0 ]] && set -- "--help"

# Read the options and set stuff
while [[ $1 = -?* ]]; do
  case $1 in
    -n|--dryrun) dryrun=true ;;
    -h|--help) usage >&2; safeExit ;;
    -v|--verbose) verbose=true ;;
    -l|--log) printLog=true ;;
    -q|--quiet) quiet=true ;;
    -s|--strict) strict=true;;
    -d|--debug) debug=true;;
    --force) force=true ;;
    --endopts) shift; break ;;
    *) die "invalid option: '$1'." ;;
  esac
  shift
done

# Store the remaining part as arguments.
args+=("$@")

function seek_confirmation() {
  # Seeks a Yes or No answer to a question.  Usage:
  #   if seek_confirmation "Answer this question"; then
  #     something
  #   fi
  input "$@"
  if "${force}"; then
    echo ""
    verbose "Forcing confirmation with '--force' flag set"
    return 0
  else
    while true; do
      read -rp " (y/n) " yn
      case $yn in
        [Yy]* ) return 0 ;;
        [Nn]* ) return 1 ;;
        * ) input "Please answer yes or no." ;;
      esac
    done
  fi
}

# shellcheck disable=2181
function execute() {
  # execute - wrap an external command in 'execute' to push native output to /dev/null
  #           and have control over the display of the results.  In "dryrun" mode these
  #           commands are not executed at all. In Verbose mode, the commands are executed
  #           with results printed to stderr and stdin
  #
  # usage:
  #   execute "cp -R somefile.txt someNewFile.txt" "Optional message to print to user"
  if ${dryrun}; then
    dryrun "${2:-$1}"
  else
    set +e # don't exit on error
    info "${2:-$1} ..."
    if $verbose; then
      eval "$1"
    else
      eval "$1" &> /dev/null
    fi
    if [ $? -eq 0 ]; then
      success "${2:-$1}"
    else
      warning "${2:-$1}"
    fi
    set -e
  fi
}
# Trap bad exits with your cleanup function
trap _trapCleanup_ EXIT INT TERM

# Set IFS to preferred implementation
IFS=$' \n\t'

# Exit on error. Append '||true' when you run the script if you expect an error.
set -o errexit

# Run in debug mode, if set
if ${debug}; then set -x ; fi

# Exit on empty variable
if ${strict}; then set -o nounset ; fi

# Exit on error
set -e

# Run your script
mainScript

# Exit cleanly
safeExit
#!/bin/bash

# Magento 2 Bash Install Script
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# @copyright Copyright (c) 2015-2017 by Yaroslav Voronoy (y.voronoy@gmail.com)
# @license   http://www.gnu.org/licenses/

if [[ -f ~/.profile ]] ; then shopt -s expand_aliases ; source ~/.profile ; fi

VERBOSE=1
WORKING_DIRECTORY_PATH="$(pwd)"
CURRENT_DIR_NAME=$(basename "$WORKING_DIRECTORY_PATH")
STEPS=()

HTTP_HOST=http://web2.sparta.corp.magento.com/dev/${USER}/
BASE_PATH=${CURRENT_DIR_NAME}
DB_HOST='sparta-db'
DB_USER="$USER"
DB_PASSWORD=
DEV_DB_PREFIX="${USER}_"

MAGENTO_VERSION=2.1
NEW_BRANCH=

DB_NAME=
USE_SAMPLE_DATA=
EE_PATH=magento2ee
INSTALL_EE=
CONFIG_NAME=.m2install.conf
USE_WIZARD=0

USE_GIT_WORKTREE=0
# Use path to local directory in the following local variables for using git-worktree.
GIT_CE_REPO="git@github.com:magento/magento2.git"
GIT_EE_REPO=

SOURCE=
FORCE=
MAGE_MODE=dev

BIN_MAGE="php -d memory_limit=2G bin/magento"
BIN_COMPOSER="composer"
BIN_MYSQL="mysql"
BIN_GIT="git"

SQL_ERROR_FILE="/dev/null"

BACKEND_FRONTNAME="admin"
ADMIN_NAME="admin"
ADMIN_PASSWORD="123123q"
ADMIN_PASSWD_HASH='30ff7ab33a8458dbd2763b9bda8afc412809df09e908e4466be8781b1fdeb4c5:55TTlQMLK7eOOiOjXjyysJT2RlQacx4O:1'
ADMIN_FIRSTNAME="Store"
ADMIN_LASTNAME="Owner"
ADMIN_EMAIL="${USER}@magento.com"
TIMEZONE=$TZ
LANGUAGE=${LANG:0:5}
CURRENCY="USD"

P_DB_PASS=

function printVersion()
{
    printString "1.1"
}

function checkForTools()
{
    TOOLS=(
        php
        composer
        mysql
        mysqladmin
        git
        cat
        basename
        tar
        gunzip
        sed
        grep
        mkdir
        cp
        mv
        rm
        find
        chmod
        date
    )

    local MISSED_REQUIRED_TOOLS=

    for TOOL in "${TOOLS[@]}"
    do
        which $TOOL >/dev/null 2>/dev/null
        if [[ $? != 0 ]]
        then
            MISSED_REQUIRED_TOOLS="$MISSED_REQUIRED_TOOLS $TOOL"
        fi
    done

    if [[ -n "$MISSED_REQUIRED_TOOLS" ]]
    then
        printf 'Unable to restore instance due to missing required tools:\n%s\n' "$MISSED_REQUIRED_TOOLS"
        exit 1
    fi
}

function askValue()
{
    MESSAGE="$1"
    READ_DEFAULT_VALUE="$2"
    READVALUE=
    if [ "${READ_DEFAULT_VALUE}" ]
    then
        MESSAGE="${MESSAGE} (default: ${READ_DEFAULT_VALUE})"
    fi
    MESSAGE="${MESSAGE}: "
    read -r -p "$MESSAGE" READVALUE
    if [[ $READVALUE = [Nn] ]]
    then
        READVALUE=''
        return
    fi
    if [ -z "${READVALUE}" ] && [ "${READ_DEFAULT_VALUE}" ]
    then
        READVALUE=${READ_DEFAULT_VALUE}
    fi
}

function askConfirmation() {
    if [ "$FORCE" ]
    then
        return 0
    fi
    read -r -p "${1:-Are you sure? [y/N]} " response
    case $response in
        [yY][eE][sS]|[yY])
            retval=0
            ;;
        *)
            retval=1
            ;;
    esac
    return $retval
}

function printString()
{
    if [[ "$VERBOSE" -eq 1 ]]
    then
        printf '%s\n' "$@"
    fi
}

function printError()
{
    >&2 printf '%s\n' "$@"
    return 1
}

function printLine()
{
    if [[ "$VERBOSE" -eq 1 ]]
    then
        printf '%s\n' '--------------------------------------------------'
    fi
}

function setRequest()
{
    local _key=$1
    local _value=$2

    local expression="REQUEST_${_key}=${_value}"
    eval "${expression}"
}

function getRequest()
{
    local _key=$1
    local _variableName="REQUEST_${_key}"
    if [[ "${!_variableName:-}" ]]
    then
        printf '%s\n' "${!_variableName}"
        return 0
    fi
    printf '\n'
    return 1
}

function runCommand()
{
    if [[ "$VERBOSE" -eq 1 ]]
    then
        printf '%s\n' "$1"
    fi

    # shellcheck disable=SC2086
    eval "$1"
}

function extract()
{
    if [ -f "$EXTRACT_FILENAME" ]
    then
        case $EXTRACT_FILENAME in
            *.tar.*|*.t*z*)
                runCommand "tar $(getStripComponentsValue ${EXTRACT_FILENAME}) -xf ${EXTRACT_FILENAME}"
            ;;
            *.gz)
                runCommand "gunzip $EXTRACT_FILENAME"
            ;;
            *.zip)
                runCommand "unzip -qu -x $EXTRACT_FILENAME"
            ;;
            *)
                printError "'$EXTRACT_FILENAME' cannot be extracted"
            ;;
        esac
    else
        printError "'$EXTRACT_FILENAME' is not a valid file"
    fi
}

function getStripComponentsValue()
{
    local stripComponents=
    local slashCount=
    slashCount=$(tar -tf "$1" | grep -v vendor | fgrep pub/index.php | sed 's/pub[/]index[.]php//' | sort | head -1 | tr -cd '/' | wc -c)

    if [[ "$slashCount" -gt 0 ]]
    then
        stripComponents="--strip-components=$slashCount"
    fi

    echo "$stripComponents"
}

function mysqlQuery()
{
    if [[ "$VERBOSE" -eq 1 ]]
    then
        printf "${1}\n"
    fi

    SQLQUERY_RESULT=$($BIN_MYSQL -h$DB_HOST -u$DB_USER $P_DB_PASS -D $DB_NAME -e "$1" 2>$SQL_ERROR_FILE)
}

function generateDBName()
{
    if [ -z "$DB_NAME" ]
    then
        prepareBasePath
        if [ "$BASE_PATH" ]
        then
            DB_NAME=${DEV_DB_PREFIX}$(echo "$BASE_PATH" | sed "s/\//_/g" | sed "s/[^a-zA-Z0-9_]//g" | tr '[:upper:]' '[:lower:]')
        else
            DB_NAME=${DEV_DB_PREFIX}$(echo "$CURRENT_DIR_NAME" | sed "s/\//_/g" | sed "s/[^a-zA-Z0-9_]//g" | tr '[:upper:]' '[:lower:]')
        fi
    fi

    DB_NAME=$(sed -e "s/\//_/g; s/[^a-zA-Z0-9_]//g" <(php -r "print strtolower('$DB_NAME');"));
}

function prepareBasePath()
{
    BASE_PATH=$(echo "${BASE_PATH}" | sed "s/^\///g" | sed "s/\/$//g" )
}

function prepareBaseURL()
{
    prepareBasePath
    HTTP_HOST=$(echo ${HTTP_HOST}/ | sed "s/\/\/$/\//g" )
    BASE_URL=${HTTP_HOST}${BASE_PATH}/
    BASE_URL=$(echo "$BASE_URL" | sed "s/\/\/$/\//g" )
}

function initQuietMode()
{
    if [[ "$VERBOSE" -eq 1 ]]
    then
        return
    fi

    BIN_MAGE="${BIN_MAGE} --quiet"
    BIN_COMPOSER="${BIN_COMPOSER} --quiet"
    BIN_GIT="$BIN_GIT --quiet"

    FORCE=1
}

function getCodeDumpFilename()
{
    FILENAME_CODE_DUMP=$(find . -maxdepth 1 -name '*.tbz2' -o -name '*.tar.bz2' | head -n1)
    if [ "${FILENAME_CODE_DUMP}" == "" ]
    then
        FILENAME_CODE_DUMP=$(find . -maxdepth 1 -name '*.tar.gz' | grep -v 'logs.tar.gz' | head -n1)
    fi
    if [ ! "$FILENAME_CODE_DUMP" ]
    then
        FILENAME_CODE_DUMP=$(find . -maxdepth 1 -name '*.tgz' | head -n1)
    fi
    if [ ! "$FILENAME_CODE_DUMP" ]
    then
        FILENAME_CODE_DUMP=$(find . -maxdepth 1 -name '*.zip' | head -n1)
    fi
}

function getDbDumpFilename()
{
    FILENAME_DB_DUMP=$(find . -maxdepth 1 -name '*.sql.gz' | head -n1)
    if [ ! "$FILENAME_DB_DUMP" ]
    then
        FILENAME_DB_DUMP=$(find . -maxdepth 1 -name '*_db.gz' | head -n1)
    fi
    if [ ! "$FILENAME_DB_DUMP" ]
    then
        FILENAME_DB_DUMP=$(find . -maxdepth 1 -name '*.sql' | head -n1)
    fi
}

function foundSupportBackupFiles()
{
    if [[ ! "$FILENAME_CODE_DUMP" ]]
    then
        getCodeDumpFilename
    fi
    if [ ! -f "$FILENAME_CODE_DUMP" ]
    then
        return 1
    fi

    if [[ ! "$FILENAME_DB_DUMP" ]]
    then
        getDbDumpFilename
    fi
    if [ ! -f "$FILENAME_DB_DUMP" ]
    then
        return 1
    fi

    return 0
}

function wizard()
{
    askValue "Enter Server Name of Document Root" "${HTTP_HOST}"
    HTTP_HOST=${READVALUE}
    askValue "Enter Base Path" "${BASE_PATH}"
    BASE_PATH=${READVALUE}
    askValue "Enter DB Host" "${DB_HOST}"
    DB_HOST=${READVALUE}
    askValue "Enter DB User" "${DB_USER}"
    DB_USER=${READVALUE}
    askValue "Enter DB Password" "${DB_PASSWORD}"
    DB_PASSWORD=${READVALUE}
    generateDBName
    askValue "Enter DB Name" "${DB_NAME}"
    DB_NAME=${READVALUE}

    if foundSupportBackupFiles
    then
        return
    fi
    if askConfirmation "Do you want to install Sample Data (y/N)"
    then
        USE_SAMPLE_DATA=1
    fi
}

function noSourceWizard()
{
    if [[ "$SOURCE" ]]
    then
        return
    fi
    if [[ ! "$SOURCE" ]] && askConfirmation "Do you want install Enterprise Edition (y/N)"
    then
        INSTALL_EE=1
    fi
}

function printConfirmation()
{
    printComposerConfirmation
    printGitConfirmation
    prepareBaseURL

    printString "BASE URL: ${BASE_URL}"
    printString "BASE PATH: ${BASE_PATH}"
    printString "DB HOST: ${DB_HOST}"
    printString "DB NAME: ${DB_NAME}"
    printString "DB USER: ${DB_USER}"
    printString "DB PASSWORD: ${DB_PASSWORD}"
    printString "MAGE MODE: ${MAGE_MODE}"
    printString "BACKEND FRONTNAME: ${BACKEND_FRONTNAME}"
    printString "ADMIN NAME: ${ADMIN_NAME}"
    printString "ADMIN PASSWORD: ${ADMIN_PASSWORD}"
    printString "ADMIN FIRSTNAME: ${ADMIN_FIRSTNAME}"
    printString "ADMIN LASTNAME: ${ADMIN_LASTNAME}"
    printString "ADMIN EMAIL: ${ADMIN_EMAIL}"
    printString "TIMEZONE: ${TIMEZONE}"
    printString "LANGUAGE: ${LANGUAGE}"
    printString "CURRENCY: ${CURRENCY}"
    if [[ -n "${NEW_BRANCH}" ]]
    then
        printString "NEW BRANCH: ${NEW_BRANCH}"
    fi

    if foundSupportBackupFiles
    then
        return
    fi

    if [ "${USE_SAMPLE_DATA}" ]
    then
        printString "Sample Data will be installed."
    else
        printString "Sample Data will NOT be installed."
    fi

    if [ "${INSTALL_EE}" ]
    then
        printString "Magento EE will be installed"
    else
        printString "Magento EE will NOT be installed."
    fi
}

function showWizard()
{
    I=1
    while [ "$I" -eq 1 ]
    do
        if [ "$USE_WIZARD" -eq 1 ]
        then
            showComposerWizzard
            showWizzardGit
            noSourceWizard
            wizard
        fi
        printLine
        printConfirmation
        if askConfirmation "Confirm That the Entered Data Is Correct? (y/N)"
        then
            I=0
        else
            USE_WIZARD=1
        fi
    done
}

function getConfigFiles()
{
    local configPaths[0]="$HOME/$CONFIG_NAME"
    configPaths[1]="$HOME/${CONFIG_NAME}.override"
    local recursiveconfigs=$( (find "$(pwd)" -maxdepth 1 -name "${CONFIG_NAME}" ;\
        x=$(pwd);\
        while [ "$x" != "/" ] ;\
        do x=$(dirname "$x");\
            find "$x" -maxdepth 1 -name "${CONFIG_NAME}";\
        done) | sed '1!G;h;$!d')
    configPaths=("${configPaths[@]}" "${recursiveconfigs[@]}" "./$(basename ${CONFIG_NAME})")
    echo "${configPaths[@]}"
    return 0
}

function loadConfigFile()
{
    local filePath=
    local configPaths=("$@")

    for filePath in "${configPaths[@]}"
    do
        if [ -f "${filePath}" ]
        then
            source "$filePath"
            USE_WIZARD=0
        fi
    done
    generateDBName
}

function promptSaveConfig()
{
    if [ "$FORCE" ]
    then
        return
    fi
    _local=$(dirname "$BASE_PATH")
    if [ "$_local" == "." ]
    then
        _local=
    else
        _local=$_local/
    fi
    if [ "$_local" != '/' ]
    then
        _local=${_local}\$CURRENT_DIR_NAME
    fi

    _configContent=$(cat << EOF
HTTP_HOST=$HTTP_HOST
BASE_PATH=$_local
DB_HOST=$DB_HOST
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
MAGENTO_VERSION=$MAGENTO_VERSION
INSTALL_EE=$INSTALL_EE
GIT_CE_REPO=$GIT_CE_REPO
GIT_EE_REPO=$GIT_EE_REPO
MAGE_MODE=$MAGE_MODE
BACKEND_FRONTNAME=$BACKEND_FRONTNAME
ADMIN_NAME=$ADMIN_NAME
ADMIN_PASSWORD=$ADMIN_PASSWORD
ADMIN_FIRSTNAME=$ADMIN_FIRSTNAME
ADMIN_LASTNAME=$ADMIN_LASTNAME
ADMIN_EMAIL=$ADMIN_EMAIL
TIMEZONE=$TIMEZONE
LANGUAGE=$LANGUAGE
CURRENCY=$CURRENCY
EOF
)

    if [ "$(getConfigFiles)" ]
    then
        _currentConfigContent=$(cat "$HOME/$CONFIG_NAME")

        if [ "$_configContent" == "$_currentConfigContent" ]
        then
            return
        fi
    fi

    configSavePath="$HOME/$CONFIG_NAME"
    if [ -f "${configSavePath}" ]
    then
        configSavePath="./$CONFIG_NAME"
    fi

    if askConfirmation "Do you want save config to ${configSavePath} (y/N)"
    then
        cat << EOF > ${configSavePath}
$_configContent
EOF

        printString "Config file has been created in ${configSavePath}"
    fi

    _local=
    configSavePath=
}

function dropDB()
{
    mysqladmin --force -h$DB_HOST -u"$DB_USER" $P_DB_PASS drop $DB_NAME &>$SQL_ERROR_FILE
}

function createNewDB()
{
    mysqladmin --force -h$DB_HOST -u"$DB_USER" $P_DB_PASS create $DB_NAME 2>$SQL_ERROR_FILE
}

function tuneAdminSessionLifetime()
{
    mysqlQuery "INSERT IGNORE INTO ${TBL_PREFIX}core_config_data (scope, scope_id, path, value) VALUES ('default', 0, 'admin/security/session_lifetime', '31536000') ON DUPLICATE KEY UPDATE value=VALUES(value)"
}

function restore_db()
{
    dropDB
    createNewDB

    getDbDumpFilename

    if which pv > /dev/null
    then
        CMD="pv \"$FILENAME_DB_DUMP\" | gunzip -cf"
    else
        CMD="gunzip -cf \"$FILENAME_DB_DUMP\""
    fi

    # Don't be confused by double gunzip in following command. Some poorly
    # configured web servers can gzip everything including gzip files
    $(eval $CMD | gunzip -cf | sed -e 's/DEFINER[ ]*=[ ]*[^*]*\*/\*/' \
        | sed -e 's/TRIGGER[ ][\`][A-Za-z0-9_]*[\`][.]/TRIGGER /' \
        | sed -e 's/AFTER[ ]\(INSERT\)\{0,1\}\(UPDATE\)\{0,1\}\(DELETE\)\{0,1\}[ ]ON[ ][\`][A-Za-z0-9_]*[\`][.]/AFTER \1\2\3 ON /' \
        | grep -v 'mysqldump: Couldn.t find table' | grep -v 'Warning: Using a password' \
        | $BIN_MYSQL -h$DB_HOST -u$DB_USER $P_DB_PASS --force $DB_NAME 2>$SQL_ERROR_FILE)
}

function restore_code()
{
    EXTRACT_FILENAME=$FILENAME_CODE_DUMP
    extract

    runCommand "mkdir -p var pub/media pub/static"
}

function configure_files()
{
    runCommand "find -L ./pub -type l -delete"
    updateMagentoEnvFile
    overwriteOriginalFiles
    runCommand "find . -type d -print0 | xargs -0 chmod 775 && find . -type f -print0 | xargs -0 chmod 664"
}

function configure_db()
{
    copyCoreConfig
    updateBaseUrl
    clearBaseLinks
    clearCookieDomain
    clearSslFlag
    clearCustomAdmin
    resetAdminPassword
}

function validateDeploymentFromDumps()
{
    local files=(
      'composer.json'
      'composer.lock'
      'index.php'
      'pub/index.php'
      'pub/static.php'
    )
    local directories=("app" "bin" "dev" "lib" "pub/errors" "setup" "vendor")
    missingDirectories=()
    for dir in "${directories[@]}"
    do
        if [ ! -d "$dir" ]
        then
            missingDirectories+=("$dir")
        fi
    done
    if [[ "${missingDirectories[@]-}" ]]
    then
        echo "The following directories are missing: ${missingDirectories[@]}"
    fi

    missingFiles=()
    for file in "${files[@]}"
    do
        if [ ! -f "$file" ]
        then
            missingFiles+=("$file")
        fi
    done
    if [[ "${missingFiles[@]-}" ]]
    then
        echo "The following files are missing: ${missingFiles[@]}"
    fi
    if [[ "${missingDirectories[@]-}" || "${missingFiles[@]-}" ]]
    then
        printError "Download missing files and directories from vanilla magento"
    fi
}

function copyCoreConfig()
{
    mysqlQuery "CREATE TABLE IF NOT EXISTS ${TBL_PREFIX}core_config_data_merchant AS SELECT * FROM ${TBL_PREFIX}core_config_data"
}

function updateBaseUrl()
{
    mysqlQuery "UPDATE ${TBL_PREFIX}core_config_data SET value = '${BASE_URL}' WHERE path IN ('web/secure/base_url', 'web/unsecure/base_url')"
}

function clearBaseLinks()
{
    mysqlQuery "DELETE FROM ${TBL_PREFIX}core_config_data WHERE path IN ('web/unsecure/base_link_url', 'web/secure/base_link_url', 'web/unsecure/base_static_url', 'web/unsecure/base_media_url', 'web/secure/base_static_url', 'web/secure/base_media_url')"
}

function clearCookieDomain()
{
    mysqlQuery "DELETE FROM ${TBL_PREFIX}core_config_data WHERE path = 'web/cookie/cookie_domain'"
}

function clearSslFlag()
{
    mysqlQuery "UPDATE ${TBL_PREFIX}core_config_data AS e SET e.value = 0 WHERE e.path IN ('web/secure/use_in_adminhtm', 'web/secure/use_in_frontend')"
}

function clearCustomAdmin()
{
    mysqlQuery "DELETE FROM ${TBL_PREFIX}core_config_data WHERE path = 'admin/url/custom'"
    mysqlQuery "UPDATE ${TBL_PREFIX}core_config_data SET \`value\` = '0' WHERE path = 'admin/url/use_custom'"
    mysqlQuery "DELETE FROM ${TBL_PREFIX}core_config_data WHERE path = 'admin/url/custom_path'"
    mysqlQuery "UPDATE ${TBL_PREFIX}core_config_data SET \`value\` = '0' WHERE path = 'admin/url/use_custom_path'"

    mysqlQuery "UPDATE ${TBL_PREFIX}core_config_data SET \`value\` = '1' WHERE \`path\` = 'system/full_page_cache/caching_application'"
}

function resetAdminPassword()
{
    mysqlQuery "UPDATE ${TBL_PREFIX}admin_user SET email = '${ADMIN_EMAIL}' WHERE username = '${ADMIN_NAME}'"

    runCommand "${BIN_MAGE} admin:user:create \
        --admin-user='${ADMIN_NAME}' \
        --admin-password='${ADMIN_PASSWORD}' \
        --admin-email='${ADMIN_EMAIL}' \
        --admin-firstname='${ADMIN_FIRSTNAME}' \
        --admin-lastname='${ADMIN_LASTNAME}'"

    #  This does not overwrite 'extras' if admin user already exists.
#     mysqlQuery " \
#         INSERT IGNORE INTO ${TBL_PREFIX}admin_user \
#         SET \
#             firstname='${ADMIN_FIRSTNAME}', \
#             lastname='${ADMIN_LASTNAME}', \
#             email='${ADMIN_EMAIL}', \
#             username='${ADMIN_NAME}', \
#             password='${ADMIN_PASSWD_HASH}', \
#             extra='a:0:{}' \
#         ON DUPLICATE KEY UPDATE \
#             firstname=VALUES(firstname), \
#             lastname=VALUES(lastname), \
#             email=VALUES(email), \
#             password=VALUES(password)"
}

function overwriteOriginalFiles()
{
    if [ ! -f pub/static.php ]
    then
        runCommand "curl -s -o pub/static.php https://raw.githubusercontent.com/magento/magento2/2.1/pub/static.php"
    fi

    if [ -f .htaccess ] && [ ! -f .htaccess.merchant ]
    then
        runCommand "mv .htaccess .htaccess.merchant"
    fi
    runCommand "curl -s -o .htaccess https://raw.githubusercontent.com/magento/magento2/2.1/.htaccess"

    if [ -f pub/.htaccess ] && [ ! -f pub/.htaccess.merchant ]
    then
        runCommand "mv pub/.htaccess pub/.htaccess.merchant"
    fi
    runCommand "curl -s -o pub/.htaccess https://raw.githubusercontent.com/magento/magento2/2.1/pub/.htaccess"

    if [ -f pub/static/.htaccess ] && [ ! -f pub/static/.htaccess.merchant ]
    then
        runCommand "mv pub/static/.htaccess pub/static/.htaccess.merchant"
    fi
    runCommand "curl -s -o pub/static/.htaccess https://raw.githubusercontent.com/magento/magento2/2.1/pub/static/.htaccess"

    if [ -f pub/media/.htaccess ] && [ ! -f pub/media/.htaccess.merchant ]
    then
        runCommand "mv pub/media/.htaccess pub/media/.htaccess.merchant"
    fi
    runCommand "curl -s -o pub/media/.htaccess https://raw.githubusercontent.com/magento/magento2/2.1/pub/media/.htaccess"
}

function updateMagentoEnvFile()
{
    TBL_PREFIX=$(grep 'table_prefix' app/etc/env.php | head -n1 | sed "s/[a-z'_ ]*[=][>][ ]*[']//" | sed "s/['][,]//")

    _key="'key' => 'ec3b1c29111007ac5d9245fb696fb729',"
    _date="'date' => 'Fri, 27 Nov 2015 12:24:54 +0000',"
    _table_prefix="'table_prefix' => '${TBL_PREFIX}',"


    if [ -f app/etc/env.php ] && [ ! -f app/etc/env.php.merchant ]
    then
        runCommand "cp app/etc/env.php app/etc/env.php.merchant"
    fi

    if [ -f app/etc/env.php.merchant ]
    then
        if grep key app/etc/env.php.merchant | grep -q "[\'][,]"
        then
            _key=$(grep key app/etc/env.php.merchant | grep "[\'][,]")
        else
            _key=$(sed -n "/key/,/[\'][,]/p" app/etc/env.php.merchant)
        fi
        _date=$(grep date app/etc/env.php.merchant)
        _table_prefix=$(grep table_prefix app/etc/env.php.merchant)
    fi

    cat << EOF > app/etc/env.php
<?php
return array (
  'backend' =>
  array (
    'frontName' => '${BACKEND_FRONTNAME}',
  ),
  'queue' =>
  array (
    'amqp' =>
    array (
      'host' => '',
      'port' => '',
      'user' => '',
      'password' => '',
      'virtualhost' => '/',
      'ssl' => '',
    ),
  ),
  'db' =>
  array (
    'connection' =>
    array (
      'indexer' =>
      array (
        'host' => '${DB_HOST}',
        'dbname' => '${DB_NAME}',
        'username' => '${DB_USER}',
        'password' => '${DB_PASSWORD}',
        'model' => 'mysql4',
        'engine' => 'innodb',
        'initStatements' => 'SET NAMES utf8;',
        'active' => '1',
        'persistent' => NULL,
      ),
      'default' =>
      array (
        'host' => '${DB_HOST}',
        'dbname' => '${DB_NAME}',
        'username' => '${DB_USER}',
        'password' => '${DB_PASSWORD}',
        'model' => 'mysql4',
        'engine' => 'innodb',
        'initStatements' => 'SET NAMES utf8;',
        'active' => '1',
      ),
    ),
    ${_table_prefix}
  ),
  'install' =>
  array (
    ${_date}
  ),
  'crypt' =>
  array (
    ${_key}
  ),
  'session' =>
  array (
    'save' => 'files',
  ),
  'resource' =>
  array (
    'default_setup' =>
    array (
      'connection' => 'default',
    ),
  ),
  'x-frame-options' => 'SAMEORIGIN',
  'MAGE_MODE' => 'default',
  'cache_types' =>
  array (
    'config' => 1,
    'layout' => 1,
    'block_html' => 1,
    'collections' => 1,
    'reflection' => 1,
    'db_ddl' => 1,
    'eav' => 1,
    'full_page' => 1,
    'config_integration' => 1,
    'config_integration_api' => 1,
    'target_rule' => 1,
    'translate' => 1,
    'config_webservice' => 1,
  ),
);
EOF

_key=
_date=
_table_prefix=
}

function deployStaticContent()
{
    if [[ "$MAGE_MODE" == "dev" ]]
    then
        return
    fi

    runCommand "${BIN_MAGE} setup:static-content:deploy"
}

function compileDi()
{
    if [[ "$MAGE_MODE" == "dev" ]]
    then
        return
    fi
    runCommand "${BIN_MAGE} setup:di:compile"
}

function installSampleData()
{
    if php bin/magento --version | grep -q beta
    then
        _installSampleDataForBeta
    else
        _installSampleData
    fi
}

function _installSampleData()
{
    if ! php bin/magento | grep -q sampledata:deploy
    then
        printString "Your version does not support sample data"
        return
    fi

    if [ -f "${HOME}/.config/composer/auth.json" ]
    then
        if [ -d "var/composer_home" ]
        then
            runCommand "cp ${HOME}/.config/composer/auth.json var/composer_home/"
        fi
    fi

    if [ -f "${HOME}/.composer/auth.json" ]
    then
        if [ -d "var/composer_home" ]
        then
            runCommand "cp ${HOME}/.composer/auth.json var/composer_home/"
        fi
    fi


    runCommand "${BIN_MAGE} sampledata:deploy"
    runCommand "${BIN_COMPOSER} update"
    runCommand "${BIN_MAGE} setup:upgrade"

    if [ -f "var/composer_home/auth.json" ]
    then
        runCommand "rm var/composer_home/auth.json"
    fi
}

function _installSampleDataForBeta()
{
    runCommand "${BIN_COMPOSER} config repositories.magento composer http://packages.magento.com"
    runCommand "${BIN_COMPOSER} require magento/sample-data:~1.0.0-beta"
    runCommand "${BIN_MAGE} setup:upgrade"
    runCommand "${BIN_MAGE} sampledata:install admin"
}

function linkEnterpriseEdition()
{
    if [ "${SOURCE}" == 'composer' ]
    then
        return
    fi

    if [ "${EE_PATH}" ] && [ "$INSTALL_EE" ]
    then
        if [ ! -d "$EE_PATH" ]
        then
            printError "There is no Enterprise Edition directory ${EE_PATH}"
            printError "Use absolute or relative path to EE code base or [N] to skip it"
            exit
        fi
        runCommand "php ${EE_PATH}/dev/tools/build-ee.php --ce-source $(pwd) --ee-source ${EE_PATH}"
        runCommand "cp ${EE_PATH}/composer.json $(pwd)/"
        runCommand "cp ${EE_PATH}/composer.lock $(pwd)/"
    fi
}

function runComposerInstall()
{
    runCommand "${BIN_COMPOSER} install"
}

function install_magento()
{
    runCommand "rm -rf var/generation/*"

    runCommand "${BIN_MAGE} --no-interaction setup:uninstall"

    dropDB
    createNewDB

    CMD="${BIN_MAGE} setup:install \
    --base-url=${BASE_URL} \
    --db-host=${DB_HOST} \
    --db-name=${DB_NAME} \
    --db-user=${DB_USER} \
    --admin-firstname=${ADMIN_FIRSTNAME} \
    --admin-lastname=${ADMIN_LASTNAME} \
    --admin-email=${ADMIN_EMAIL} \
    --admin-user=${ADMIN_NAME} \
    --admin-password=${ADMIN_PASSWORD} \
    --language=${LANGUAGE} \
    --currency=${CURRENCY} \
    --timezone=${TIMEZONE} \
    --use-rewrites=1 \
    --backend-frontname=${BACKEND_FRONTNAME}"
    if [ "${DB_PASSWORD}" ]
    then
        CMD="${CMD} --db-password=${DB_PASSWORD}"
    fi
    runCommand "$CMD"
}

function addNewGit()
{
    # skip if already exists
    if [[ -e '.git' ]]
    then
        return
    fi

    printString "Wrapping deployment with local-only git repository."

    (

    # backup merchant's file
    if [[ -e '.gitignore' ]]
    then
        mv -f .gitignore .gitignore.merchant
    fi

    cat <<GIT_IGNORE_EOF > .gitignore
/media/
/var/
/.idea/
.svn/
*.gz
*.tgz
*.bz
*.bz2
*.tbz2
*.tbz
*.zip
*.tar
.DS_Store

GIT_IGNORE_EOF

    git init >/dev/null 2>&1

    local FIND_REGEX_TYPE=
    if [[ "$(uname)" = 'Darwin' ]]
    then
        FIND_REGEX_TYPE='find -E . -type f'
    else
        FIND_REGEX_TYPE='find . -type f -regextype posix-extended'
    fi

    $FIND_REGEX_TYPE ! -regex \
        '\./\.git/.*|\./media/.*|\./var/.*|.*\.svn/.*|\./\.idea/.*|.*\.gz|.*\.tgz|.*\.bz|.*\.bz2|.*\.tbz2|.*\.tbz|.*\.zip|.*\.tar|.*DS_Store' \
        -print0 | xargs -0 git add -f

    git commit -m 'initial merchant deployment' >/dev/null 2>&1

    )&
}

function downloadSourceCode()
{
    if [ "$(ls -A ./)" ]
    then
        printError "Can't download source code from ${SOURCE} since current directory isn't empty."
        printError "You can remove all files from current directory using next command:"
        printError "ls -A | xargs rm -rf"
        exit 1
    fi
    if [ "$SOURCE" == 'composer' ]
    then
        composerInstall
    fi

    if [ "$SOURCE" == 'git' ]
    then
        gitClone
    fi
}

function composerInstall()
{
    if [ "$INSTALL_EE" ]
    then
        runCommand "${BIN_COMPOSER} create-project --repository-url=https://repo.magento.com/ magento/project-enterprise-edition . ${MAGENTO_VERSION}"
    else
        runCommand "${BIN_COMPOSER} create-project --repository-url=https://repo.magento.com/ magento/project-community-edition . $MAGENTO_VERSION"
    fi
}

showComposerWizzard()
{
    if [ "$SOURCE" != 'composer' ]
    then
        return
    fi
    askValue "Composer Magento version" "${MAGENTO_VERSION}"
    MAGENTO_VERSION=${READVALUE}
    if askConfirmation "Do you want to install Enterprise Edition (y/N)"
    then
        INSTALL_EE=1
    fi

}

printComposerConfirmation()
{
    if [ "$SOURCE" != 'composer' ]
    then
        return
    fi
    printString "Magento code will be downloaded from composer"
    printString "Composer version: $MAGENTO_VERSION"
}

function showWizzardGit()
{
    if [ "$SOURCE" != 'git' ]
    then
        return
    fi
    askValue "Git CE repository" ${GIT_CE_REPO}
    GIT_CE_REPO=${READVALUE}
    askValue "Git EE repository" ${GIT_EE_REPO}
    GIT_EE_REPO=${READVALUE}
    askValue "Git branch" ${MAGENTO_VERSION}
    MAGENTO_VERSION=${READVALUE}
    if askConfirmation "Do you want to install Enterprise Edition (y/N)"
    then
        INSTALL_EE=1
    fi
}

function gitClone()
{
    if [[ -n "$NEW_BRANCH" ]]
    then
        NEW_BRANCH="-b $NEW_BRANCH"
    fi

    if [[ $USE_GIT_WORKTREE ]]
    then
        runCommand "cd $GIT_CE_REPO"
        runCommand "$BIN_GIT worktree add $NEW_BRANCH '$WORKING_DIRECTORY_PATH' $MAGENTO_VERSION"

        if [[ "$GIT_EE_REPO" ]] && [[ "$INSTALL_EE" ]]
        then
            runCommand "cd $GIT_EE_REPO"
            runCommand "$BIN_GIT worktree add $NEW_BRANCH '${WORKING_DIRECTORY_PATH}/${EE_PATH}' $MAGENTO_VERSION"
        fi

        runCommand "cd '$WORKING_DIRECTORY_PATH'"
    else
        runCommand "$BIN_GIT clone $GIT_CE_REPO ."
        runCommand "$BIN_GIT checkout $NEW_BRANCH $MAGENTO_VERSION"

        if [[ "$GIT_EE_REPO" ]] && [[ "$INSTALL_EE" ]]
        then
            runCommand "$BIN_GIT clone $GIT_EE_REPO $EE_PATH"
            runCommand "cd $EE_PATH"
            runCommand "$BIN_GIT checkout $NEW_BRANCH $MAGENTO_VERSION"
            runCommand "cd .."
        fi
    fi
}

function printGitConfirmation()
{
    if [ "$SOURCE" != 'git' ]
    then
        return
    fi
    printString "Magento code will be downloaded from GIT"
    printString "Git CE repository: ${GIT_CE_REPO}"
    printString "Git EE repository: ${GIT_EE_REPO}"
    printString "Git branch: ${MAGENTO_VERSION}"
}

function checkArgumentHasValue()
{
    if [ ! "$2" ]
    then
        printError "ERROR: $1 Argument is empty."
        printLine
        printUsage
        exit
    fi
}

function isInputNegative()
{
    if [[ $1 = [Nn][oO] ]] || [[ $1 = [Nn] ]] || [[ $1 = [0] ]]
    then
        return 0
    else
        return 1
    fi
}

function validateStep()
{
    local _step=$1
    local _steps="restore_db restore_code configure_db configure_files configure install_magento"
    if echo "$_steps" | grep -q "$_step"
    then
        if type -t "$_step" &>/dev/null
        then
            return 0
        fi
    fi
    return 1
}

function prepareSteps()
{
    local _step
    local _steps

    _steps=(${STEPS[@]//,/ })
    STEPS=
    for _step in "${_steps[@]}"
    do
        if validateStep "$_step"
        then
          addStep "$_step"
        fi
    done
}

function addStep()
{
    local _step=$1
    STEPS+=($_step)
}

function setProductionMode()
{
    runCommand "${BIN_MAGE} deploy:mode:set production"
}

function setFilesystemPermission()
{
    runCommand "chmod u+x ./bin/magento"
    runCommand "chmod -R 2777 ./var ./pub/media ./pub/static ./app/etc"
}

function afterInstall()
{
    if [[ "$MAGE_MODE" == "production" ]]
    then
        setProductionMode
    fi
    if [ ! "$(getRequest skipPostDeploy)" ] && [ -f "${CURRENT_DIR_NAME}/post-deploy" ]
    then
        printString "==> Run the post deploy ${CURRENT_DIR_NAME}/post-deploy"
        . "${CURRENT_DIR_NAME}/post-deploy";
        printString "==> Post deploy script has been finished"
    fi
    setFilesystemPermission
}

function executeSteps()
{
    local _steps=("$@")
    for step in "${_steps[@]}"
    do
        if [ "${step}" ]
        then
            if [[ "$VERBOSE" -eq 1 ]]
            then
                printf '=> '
            fi
            runCommand "${step}"
        fi
    done
}

function printUsage()
{
    cat <<EOF
$(basename "$0") is designed to simplify the installation process of Magento 2
and deployment of client dumps created by Magento 2 Support Extension.

Usage: $(basename "$0") [options]
Options:
    -h, --help                           Get this help.
    -s, --source (git, composer)         Get source code.
    -v, --version                        Magento Version from Composer or GIT Branch
    -b, --new-branch [MDVA-123]          New branch name if using work tree. Parameter is optional.
                                             If empty then "MDVA-<directory name>" will be used.
    -d, --sample-data                    Install sample data.
    --ee                                 Install Enterprise Edition.
    -f, --force                          Install/Restore without any confirmations.
    --mode (dev, prod)                   Magento Mode. Dev mode does not generate static & di content.
    --quiet                              Quiet mode. Suppress output all commands
    --skip-post-deploy                   Skip the post deploy script if it is exist
    --step (restore_db restore_code configure_db configure_files configure install_magento)
                                         Specify step through comma without spaces.
                                         - Example: $(basename "$0") --step restore_db,configure_db
    --restore-table                      Restore only the specific table from DB dumps
    --debug                              Enable debug mode
    _________________________________________________________________________________________________
    -e, --ee-path (/path/to/ee)          (DEPRECATED use --ee flag) Path to Enterprise Edition.
EOF
}

function processOptions()
{
    while [[ $# -gt 0 ]]
    do
        case "$1" in
            -s|--source)
                checkArgumentHasValue "$1" "$2"
                SOURCE="$2"
                shift
            ;;
            -d|--sample-data)
                USE_SAMPLE_DATA=1
            ;;
            -e|--ee-path)
                checkArgumentHasValue "$1" "$2"
                EE_PATH="$2"
                INSTALL_EE=1
                shift
            ;;
            --ee)
                INSTALL_EE=1
            ;;
            -b|--new-branch)
                checkArgumentHasValue "$1" "$2"
                NEW_BRANCH="$2"
                if [[ "${NEW_BRANCH:0:1}" == "-" || -z "${NEW_BRANCH}" ]]
                then
                    NEW_BRANCH='MDVA-'${CURRENT_DIR_NAME}
                fi
            ;;
            -v|--version)
                checkArgumentHasValue "$1" "$2"
                MAGENTO_VERSION="$2"
                shift
            ;;
            --mode)
                checkArgumentHasValue "$1" "$2"
                MAGE_MODE=$2
                shift
            ;;
            -f|--force)
                FORCE=1
                USE_WIZARD=0
            ;;
            --quiet)
                VERBOSE=0
            ;;
            --skip-post-deploy)
                setRequest skipPostDeploy 1
            ;;
            -h|--help)
                printUsage
                exit
            ;;
            --code-dump)
                checkArgumentHasValue "$1" "$2"
                setRequest codedump "$2"
                shift
            ;;
            --db-dump)
                checkArgumentHasValue "$1" "$2"
                setRequest dbdump "$2"
                shift
            ;;
            --restore-table)
                checkArgumentHasValue "$1" "$2"
                setRequest restoreTableName "$2"
                shift
            ;;
            --step)
                checkArgumentHasValue "$1" "$2"
                STEPS=($2)
                shift
            ;;
            --debug)
              set -o xtrace
            ;;
        esac
        shift
    done
}

################################################################################
# Action Controllers
################################################################################
function magentoInstallAction()
{
    if [[ "${SOURCE}" ]]
    then
        if [ "$(ls -A)" ] && askConfirmation "Current directory is not empty. Do you want to clean current Directory (y/N)"
        then
            runCommand "ls -A | xargs rm -rf"
        fi
        addStep "downloadSourceCode"
    fi
    addStep "linkEnterpriseEdition"
    addStep "runComposerInstall"
    addStep "install_magento"
    if [[ "${USE_SAMPLE_DATA}" ]]
    then
        addStep "installSampleData"
    fi
}

function magentoDeployDumpsAction()
{
    addStep "restore_code"
    addStep "configure_files"
    addStep "addNewGit"
    addStep "restore_db"
    addStep "configure_db"
    addStep "validateDeploymentFromDumps"
}

function restoreTableAction()
{
    runCommand "{ echo 'SET FOREIGN_KEY_CHECKS=0;';
       echo 'TRUNCATE ${DB_NAME}.${TBL_PREFIX}$(getRequest restoreTableName);';
       zgrep 'INSERT INTO \`$(getRequest restoreTableName)\`' $(getDbDumpFilename); }
       | ${BIN_MYSQL} -h${DB_HOST} -u${DB_USER} --password=\"${DB_PASSWORD}\" --force $DB_NAME"
}

function magentoCustomStepsAction()
{
    prepareSteps
}

################################################################################
# Main
################################################################################

function main()
{
    loadConfigFile $(getConfigFiles)
    processOptions "$@"
    initQuietMode
    printString "Current Directory: ${WORKING_DIRECTORY_PATH}"
    printString "Configuration loaded from: $(getConfigFiles)"
    checkForTools

    # Set timezone default after checking for tools and if not already set.
    if [[ -z "$TIMEZONE" ]]
    then
        TIMEZONE=$(php -r 'echo date_default_timezone_get();')
    fi

    showWizard

    if [[ -n "$DB_PASSWORD" ]]
    then
        P_DB_PASS="-p$DB_PASSWORD"
    fi

    START_TIME=$(date +%s)
    if [[ "${STEPS[@]}" ]]
    then
        magentoCustomStepsAction
    elif foundSupportBackupFiles
    then
        magentoDeployDumpsAction
    else
        magentoInstallAction
    fi
    addStep "afterInstall"

    executeSteps "${STEPS[@]}"

    END_TIME=$(date +%s)
    SUMMARY_TIME=$((((END_TIME - START_TIME)) / 60))
    printString "$(basename \"$0\") took $SUMMARY_TIME minutes to complete install/deploy process"

    printLine
    printString "${BASE_URL}"
    printString "${BASE_URL}${BACKEND_FRONTNAME}"
    printString "User: ${ADMIN_NAME}"
    printString "Pass: ${ADMIN_PASSWORD}"
    printLine

#     promptSaveConfig
}

main "${@}"

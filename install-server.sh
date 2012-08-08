#! /bin/sh
set -e -x

# Database settings
FMS_DB_PASS=$(head -c 32 /dev/urandom | base64)
# this should be the username of a exsisting 
# account that can se su-ed to:
FMS_DB_USER="www-data"
FMS_DB_NAME="fms"

# Random salt as secret for admin
RANDOMSALT=$(head -c 32 /dev/urandom | base64)

BASE="/root/FixMyStreet"
# Wether or not to use the squeeze+testing-pacakgelist. 0: don't use. 1: use
PLUSS_TESTING=1 # really no need to change

add_apt_repo() {
	if [ "$(grep 'http://ftp.no.debian.org/debian testing' /etc/apt/sources.list | wc -l)" -ne "1" ]; then
		echo "\ndeb http://ftp.no.debian.org/debian testing main contrib non-free" >> /etc/apt/sources.list
	        echo "\ndeb http://backports.debian.org/debian-backports squeeze-backports main" >> /etc/apt/sources.list
	fi
	if [ "$(grep '^Pin: release a=testing' /etc/apt/sources.list | wc -l)" -ne "1" ]; then
		echo "Package: *\nPin: release a=stable\nPin-Priority: 600\n" >> /etc/apt/preferences
		echo "Package: *\nPin: release a=squeeze-backports\nPin-Priority: 200\n" >> /etc/apt/preferences
		echo "Package: *\nPin: release a=testing\nPin-Priority: 50\n" >> /etc/apt/preferences
	fi
	apt-get update
}

setup_folders_git_checkout() {
	apt-get install -y git
	if [ ! -d $BASE ]; then
	    mkdir $BASE
	fi
	cd $BASE
	if [ ! -d "fixmystreet" ]; then
	    git clone --recursive https://github.com/mysociety/fixmystreet.git
	else
	    echo "Will assume that code is already cloned"
	fi
	cd fixmystreet
}

generate_locales() {
	# Generate required locales
	if [ "$(locale -a | grep '^en_GB.utf8$' | wc -l)" -eq "1" ]; then
	    echo "en_GB.utf8 activated and generated"
	else
	    echo "en_GB.utf8 not generated"
	    if [ "$(grep '^en_GB.UTF-8 UTF-8' /etc/locale.gen | wc -l)" -eq "1" ]; then
	        echo "'en_GB.UTF-8 UTF-8' already in /etc/locale.gen we will only generate"
	    else
		echo "Appending 'en_GB.UTF-8 UTF-8' and 'cy_GB.UTF-8 UTF-8'"
		echo "to /etc/locale.gen for generation"
		echo "\nen_GB.UTF-8 UTF-8\ncy_GB.UTF-8 UTF-8" >> /etc/locale.gen
	    fi
	    echo "Generating new locales"
    	    locale-gen
	fi
}

pgsql_createuser() {
    dbuser="$1"
    dbpassword="$2"
    su postgres -c "createuser -SDRl $dbuser"
    su postgres -c "psql -c \"alter user \\\"$dbuser\\\" with password '$dbpassword';\""
}
pgsql_remove_db() {
    dbname="$1"
    su postgres -c "dropdb $dbname"
}
pgsql_remove_user() {
    dbuser="$1"
    su postgres -c "dropuser $dbuser"
}
setup_psql() {
	pgsql_remove_db "$FMS_DB_NAME" || true
	pgsql_remove_user "$FMS_DB_USER" || true
	pgsql_createuser "$FMS_DB_USER" "$FMS_DB_PASS"
	su postgres -c "createdb -E UTF8 --owner $FMS_DB_USER $FMS_DB_NAME; createlang plpgsql $FMS_DB_NAME"
	if ! echo "\q" | su $FMS_DB_USER -c "psql $FMS_DB_NAME"; then
		echo "Failed to connect to postgresql/$FMS_DB_NAME as $FMS_DB_USER"
		exit 1;
	fi
	cat $BASE/fixmystreet/db/schema.sql               | su $FMS_DB_USER -c "psql -d $FMS_DB_NAME"
        cat $BASE/fixmystreet/db/alert_types.sql          | su $FMS_DB_USER -c "psql -d $FMS_DB_NAME"
	echo "INSERT INTO secret VALUES ('$RANDOMSALT');" | su $FMS_DB_USER -c "psql -d $FMS_DB_NAME"
}

install_packages() {
	echo "Installing required packages"
	if [ $PLUSS_TESTING -eq 0 ]; then
		xargs -a conf/packages.debian-squeeze apt-get -y install
		# installing compass from pinned testing 
		# will remove libhaml-ruby libhaml-ruby1.8
		apt-get -y install ruby-compass ruby-haml
	else
		xargs -a conf/packages.debian-squeeze+testing apt-get -y install
	fi
	./bin/install_perl_modules
}

make_config() {
	# These settings are to minimice the number of errors in a test-run
	# CONTACT_EMAIL must be fms-DO-NOT-REPLY@example.org for some tests
	# MAPIT_URL must be UK (maybe non-fake) for some tests
	# fixmystreet cobrand must be activated for tests
	cat ./conf/general.yml-example | sed\
	 -e "s*^CONTACT_EMAIL: 'team@example.org'*CONTACT_EMAIL: 'fms-DO-NOT-REPLY@example.org'*"\
	 -e "s*^BASE_URL: 'http://www.example.org'*BASE_URL: 'http://localhost:3000'*"\
	 -e "s*^MAPIT_URL: ''*MAPIT_URL: 'http://mapit.mysociety.org/'*"\
	 -e "s*^  - cobrand_one*  - fixmystreet: 'localhost'*"\
	 -e "s*^  - cobrand_two: 'hostname_substring2'*  - fixmystreet*"\
	 -e "s#^FMS_DB_PASS.*\$#FMS_DB_PASS: '$FMS_DB_PASS'#"\
	 -e "s#^FMS_DB_NAME.*\$#FMS_DB_NAME: '$FMS_DB_NAME'#"\
	 -e "s#^FMS_DB_USER.*\$#FMS_DB_USER: '$FMS_DB_USER'#"\
	> ./conf/general.yml
}

make_css() {
	./bin/make_css
}

generate_po() {
	# Generate all po-files for test
	./bin/cron-wrapper ./bin/make_emptyhomes_po 
	./bin/cron-wrapper ./bin/make_emptyhomes_welsh_po 
	# Generate all mo-files
	commonlib/bin/gettext-makemo FixMyStreet
}

test_run() { 
	# Start server
	#APP_SERVER_PID=$(mktemp)
	#./bin/cron-wrapper ./script/fixmystreet_app_server.pl --pidfile $APP_SERVER_PID  --background
	# Run tests
	./bin/cron-wrapper prove -r t
	# Stop server
	#kill -9 `cat $APP_SERVER_PID`
	#cat $APP_SERVER_PID
	#rm $APP_SERVER_PID
}

footer() {
	echo "Suggested commands: (if you are here, tests have completed successfully)"
	echo "./bin/cron-wrapper ./script/fixmystreet_app_server.pl -d --fork"
	echo "./bin/cron-wrapper ./bin/cron-wrapper prove -r t"
	echo "./bin/cron-wrapper ./bin/cron-wrapper prove -r t 2>&1 &> complete_logfile"
}

add_apt_repo
generate_locales
setup_folders_git_checkout
install_packages
setup_psql
make_config
make_css
generate_po
test_run
footer


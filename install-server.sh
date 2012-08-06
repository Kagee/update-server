#! /bin/sh

set -e

DBPWD=$(head -c 32 /dev/urandom | base64)
RANDOMSALT=$(head -c 32 /dev/urandom | base64)

#if [ "$(grep '^deb http://debian.mysociety.org squeeze' /etc/apt/sources.list | wc -l)" -ne "1" ]
#then
#	echo "\ndeb http://debian.mysociety.org squeeze main" >> /etc/apt/sources.list
#	echo "\ndeb-src http://debian.mysociety.org squeeze main" >> /etc/apt/sources.list
#fi

if [ "$(grep 'http://ftp.no.debian.org/debian testing' /etc/apt/sources.list | wc -l)" -ne "1" ]
then
	echo "\ndeb http://ftp.no.debian.org/debian testing main contrib non-free" >> /etc/apt/sources.list
fi

if [ "$(grep '^Pin: release a=testing' /etc/apt/sources.list | wc -l)" -ne "1" ]
then
    echo "Package: *\nPin: release a=stable\nPin-Priority: 950\n" >> /etc/apt/preferences
    echo "Package: *\nPin: release a=testing\nPin-Priority: 900\n" >> /etc/apt/preferences
fi

apt-get update

apt-get install -y git

if [ ! -d "FixMyStreet" ]; then
    mkdir FixMyStreet
fi
cd FixMyStreet

if [ ! -d "fixmystreet" ]; then
    git clone --recursive https://github.com/mysociety/fixmystreet.git
else
    echo "Will assume that code is already cloned"
fi
cd fixmystreet

# Generate required locales
if [ "$(locale -a | grep '^en_GB.utf8$' | wc -l)" -eq "1" ]
then
    echo "en_GB.utf8 activated and generated"
else
    echo "en_GB.utf8 not generated"
    if [ "$(grep '^en_GB.UTF-8 UTF-8' /etc/locale.gen | wc -l)" -eq "1" ]
    then
        echo "'en_GB.UTF-8 UTF-8' already in /etc/locale.gen we will only generate"
    else
        echo "Appending 'en_GB.UTF-8 UTF-8' and 'cy_GB.UTF-8 UTF-8'"
	echo "to /etc/locale.gen for generation"
        echo "\nen_GB.UTF-8 UTF-8\ncy_GB.UTF-8 UTF-8" >> /etc/locale.gen
    fi
    echo "Generating new locales"
    locale-gen
fi

apt-get -y install postgresql-8.4

#TODO: Remove when script complete
echo "DROP DATABASE fms; DROP USER FMS;" | su postgres -c "psql --echo-all"

echo "CREATE USER fms WITH PASSWORD '$DBPWD'; CREATE DATABASE fms WITH OWNER fms;" | su postgres -c "psql --echo-all"

if ! echo "\q" | psql -d fms -U fms
then
    # psql: FATAL:  Ident authentication failed for user "fms"
    echo "Adding 'local fms fms trust' to /etc/postgresql/8.4/main/pg_hba.conf"
    cp /etc/postgresql/8.4/main/pg_hba.conf /etc/postgresql/8.4/main/pg_hba.conf.fms
    echo "local fms fms trust\n" > /etc/postgresql/8.4/main/pg_hba.conf
    cat /etc/postgresql/8.4/main/pg_hba.conf.fms >> /etc/postgresql/8.4/main/pg_hba.conf
    rm /etc/postgresql/8.4/main/pg_hba.conf.fms
    /etc/init.d/postgresql restart
else
    echo "Can connect to psql using fms"
fi

echo "CREATE LANGUAGE plpgsql;" | psql -d fms -U fms

echo "Importing schemas"

psql -d fms -U fms < db/schema.sql
psql -d fms -U fms < db/alert_types.sql

echo "Inserting secret"
echo "INSERT INTO secret VALUES ('$RANDOMSALT');" | psql -d fms -U fms

echo "Installing required packages"

# xargs -a conf/packages.debian-squeeze apt-get -y install
# This package is no-working in stable and installed by cartoon anyway
grep -v libstatistics-distributions-perl conf/packages.debian-squeeze | xargs apt-get install -y

#echo "Installing compass using gem"
#gem install compass

# installing compass from testing will remove libhaml-ruby libhaml-ruby1.8
# install ruby-haml to compensate
apt-get -y install ruby-compass ruby-haml


# perl Image:Magick
# apt-get install perlmagick
# Already installed?

# Why is not make installed? (cartoon requires make)
apt-get -y install make

./bin/install_perl_modules

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
 -e "s*^FMS_DB_PASS: ''*FMS_DB_PASS: '$DBPWD'*"\
> ./conf/general.yml

./bin/make_css

./bin/cron-wrapper ./make_emptyhomes_po
./bin/cron-wrapper ./make_emptyhomes_welsh_po

# Unsure if this should be run
commonlib/bin/gettext-makemo FixMyStreet

# missing module for admin/summary
./bin/cron-wrapper ./local/bin/carton install Template::Plugin::DateTime::Format

echo "Why dont you run some of these commands:"
echo "LC_ALL=en_GB.utf8 ./bin/cron-wrapper ./script/fixmystreet_app_server.pl -d --fork"
echo "LC_ALL=en_GB.utf8 ./bin/cron-wrapper ./bin/cron-wrapper prove -r t"
echo "LC_ALL=en_GB.utf8 ./bin/cron-wrapper ./bin/cron-wrapper prove -r t 2>&1 &> complete_logfile"


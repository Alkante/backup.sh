#!/bin/bash


usage()
{
echo "Usage: `basename $0` [mysql] [postgres] [files] [ldap] [xenserver] [docker_mysql] [docker_postgres] [docker_mongo] [prometheus]

-h | --help : Afficher cette aide
-t | --test : Test du script sans effectuer les sauvegardes
-1 | --one-backup : Une seule backup sera en place
-s | --screen : sortie standard du script en console (sinon dans \$LOG)
mysql : Sauvegarder les bases Mysql
mariadb : Sauvegarder les bases Mariadb
postgres : Sauvegarder les bases Postgres
mongo : Sauvegarder les bases Mongo
ldap : Sauvegarder les annuaires LDAP
files : Faire la sauvegarde des fichiers des sites
xenserver: dump pool database + LVM metadata
prometheus: Créer et sauvegarder un snapshot Prometheus
docker_mysql : Sauvegarder les bases Mysql des docker listés dans ${SCRIPTDIR}/backuprc_docker_mysql
docker_postgres : Sauvegarder les bases Postgres des docker listés dans ${SCRIPTDIR}/backuprc_docker_postgres
                  Format de backuprc_docker_postgres : <CONTAINER_NAME>
                                            et aussi : <CONTAINER_NAME>:<pgdefaultuser>:<pgdefaultdatabase>
docker_mongo : Sauvegarder les bases Mongo des docker listés dans ${SCRIPTDIR}/backuprc_docker_mongo
docker_ldap : Sauvegarder les bases LDAP des docker listés dans ${SCRIPTDIR}/backuprc_docker_ldap
"
}

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
#################variables par défaut, à surcharger avec backuprc
DATE=`date '+%y%m%d-%H%M%S'`
ONEBACKUP=false

# Mail
DEST="CHANGEME@EXAMPLE.INVALID"
RETURNPATH="${DEST}"
SENDMAIL_OPTIONS="-t -f\"${RETURNPATH}\""

# Hostname
HOSTNAME_FQDN=`hostname -f`
HOSTNAME_SHORT=`hostname -s`

#repertoire courant
SCRIPTDIR=`dirname $(readlink -f $0)`
SCRIPTNAME=`basename $(readlink -f $0)`
#repertoire des logs
LOGDIR="${SCRIPTDIR}/log"
LOCKDIR="${SCRIPTDIR}/${SCRIPTNAME%.*}.lock"

#variables bases
DATABASES_DEST="/home/backup/bases"
DATABASES_TMP_DIR="back_${DATE}"
DATABASES_EXCLUDE="^$|^postgres|^template"
#argument de la commande find pour la purge des dumps plus vieux que:
# 3h =>clean_argument="-mmin +180"
#8 jours:
clean_argument="-mtime +8"

#variables mysql
MYSQL_OPT="-u root -S /tmp/mysql.sock --password=xxxx"
MYSQL_OPT="-u root -S /var/run/mysqld/mysqld.sock --password=xxxx"
docker_all_MYSQL_OPT="-u root -S /var/run/mysqld/mysqld.sock"
mysqlbin=`which mysql 2> /dev/null`
mysqldumpbin=`which mysqldump  2> /dev/null`
mariadbbin=`which mariadb 2> /dev/null`
mariadbdumpbin=`which mariadb-dump  2> /dev/null`

#variables postgres
psqlbin=`which psql  2> /dev/null`
[ -n "${psqlbin}" ] && psqlversion=`${psqlbin} -V | head -n 1 | awk '{ print $NF }' | awk -F "." '{ print $1$2 }'`
pgdumpbin=`which pg_dump  2> /dev/null`
pgdumpall=`which pg_dumpall  2> /dev/null`
pgdefaultuser=postgres
pgdefaultdatabase=postgres
#par défaut backup full tous les jours.
#si full_dayofweek est renseigné, backup full une fois par mois. Format attendu : 1(lundi) à 7(dimanche)
full_dayofweek=""
#les autres jours pg_dump excluera/incluera des tables/schema sous la forme suivante (pipe comme séparateur base.schema.table):
#table est prioritaire sur schema (schema sera ignoré)
#PG_INC_SCHEMA="base1.schema1|base2.schema3"
#PG_EXC_SCHEMA="base1.schema1|base2.schema3"
#PG_INC_TABLE="base1.schema1.table2|base2.schema3.table1"
#PG_EXC_TABLE="base1.schema1.table2|base2.schema3.table1"

# docker vars
dockerbin=`which docker 2> /dev/null`

#variables rsync
# HOMEWWW_DIR="/var/www"
FILES_DEST="/home/backup/sites"
FILES_DEST_0="${FILES_DEST}/backup.0"
EXCLUDE="${FILES_DEST}/rsync_exclude"
RSYNC_OPT="-a --links --exclude-from=${EXCLUDE}"
#nb jour backup files
nbfiles="8"

#variables rapport
REPORTDIR="/var/www/html"

#nb jour clean log
nbclean="8"


#################variables backuprc
[ -e "${SCRIPTDIR}/backuprc" ] && . "${SCRIPTDIR}/backuprc"

#################init variables
REPORT="${REPORTDIR}/rapport_`date '+%y%m%d'`.txt"
[ -f ${REPORT} ] && rm ${REPORT}
LOG="${LOGDIR}/${SCRIPTNAME%.*}_${DATE}.log"
[ -d ${LOGDIR} ] || mkdir -p `dirname $LOG`
#presentation des tailles conversion des Ko
size_giga_value="1048576"
size_mega_value="1024"
size_kilo_value="1"
today_dayofweek=`date '+%u'`
today_dayofmonth=`date '+%d'`
#1 pas de mail / 0 envoi du mail
do_mail="1"

echolog()
{
echo "`date '+%b %d %H:%M:%S'`  ${1}"
}

sendMail()
{
(
echo "From: root@${HOSTNAME_FQDN}"
echo "To: ${DEST}"
echo "Subject: ${SCRIPTNAME} sur ${HOSTNAME_SHORT}"
echo "MIME-Version: 1.0"
echo "Content-Type: text/plain; charset=UTF8"
[ -f ${LOG} ] && cat ${LOG}
#for pj in `ls -1 ${LOGDIR}/${SCRIPTNAME}_${DATE}_rsync*`; do uuencode $pj $pj; done
) | /usr/sbin/sendmail ${SENDMAIL_OPTIONS}
}

lock()
{
mkdir "${LOCKDIR}" 2> /dev/null && trap 'rm -rf ${LOCKDIR}; exit' 0 2
}
lockCheck()
{
lock || { echolog "Erreur ${SCRIPTNAME} est déjà en cours d'exécution, fin du script"; do_mail="0"; sendMail; exit 1;}
}

dump_postgres()
{
echolog "Début de l'export Postgres"
dbs=`su - postgres -c "$psqlbin -U $pgdefaultuser -tA -P pager=off -c \"SELECT datname FROM pg_database;\" $pgdefaultdatabase" |egrep -v "${DATABASES_EXCLUDE}"`
for db in ${dbs}
do
    echolog "  base : ${db}"
    if [ "$test" != "1" ] ; then
        PG_OPT=""
        if [ -z "$full_dayofweek" ] || ([ -n "$full_dayofweek" ] && [ "$today_dayofweek" -eq "$full_dayofweek" ] && [ "$today_dayofmonth" -le 07 ])
            then
                #si une variable $full_dayofweek existe (=si on veut un full que certains jours) ET si c'est le bon jour de la semaine ET si c'est le premier correspondant dans le mois
                #ALORS full backup. Pas de PG_OPT.
                echolog "Performing full backup"
                su - postgres -c "$pgdumpbin -C -Fc ${db}" > ${DATABASES_TMP_DIR}/PGSQL${BACKUP_TAGFILE}_${db}.dmp
            else
                #SINON passage des arguments PG_OPT pour ne pas tout sauvegarder (note : PG_OPT peut être vide et génèrera un full backup...)
               #4blocs pour inclure OU exclure des schemas OU des tables : options stockées dans PG_OPT
                if [ `echo  "${PG_INC_SCHEMA}" | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_INC_SCHEMA} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-n "$i " "}}'`
                fi
                if  [ `echo  "${PG_EXC_SCHEMA}" | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_EXC_SCHEMA} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-N "$i " "}}'`
                fi
                if [ `echo  "${PG_INC_TABLE}"  | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_INC_TABLE} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-t "$i " "}}'`
                fi
                if [ `echo  "${PG_EXC_TABLE}"  | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_EXC_TABLE} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-T "$i " "}}'`
                fi
                echolog "Performing backup with PG_OPT = $PG_OPT"
                su - postgres -c "$pgdumpbin -C -Fc $PG_OPT ${db}" > ${DATABASES_TMP_DIR}/PGSQL${BACKUP_TAGFILE}_${db}.dmp
        fi
        [ $? -ne 0 ] && echo "Flag dump ${db} NOK" && do_mail="0"
        echo
    fi
done
case $psqlversion in
   1[1-2][0-9]-*)
      su - postgres -c "$psqlbin -U $pgdefaultuser -t -c \"SELECT distinct 'mkdir -p ''' || pg_tablespace_location(oid) || '''' FROM pg_tablespace t where t.spcname<>'pg_default' and t.spcname<>'pg_global';\" $pgdefaultdatabase" > ${DATABASES_TMP_DIR}/create_pgdir.sh
      ;;
   9[2-9])
      su - postgres -c "$psqlbin -U $pgdefaultuser -t -c \"SELECT distinct 'mkdir -p ''' || pg_tablespace_location(oid) || '''' FROM pg_tablespace t where t.spcname<>'pg_default' and t.spcname<>'pg_global';\" $pgdefaultdatabase" > ${DATABASES_TMP_DIR}/create_pgdir.sh
      ;;
   90|91|[7-8]*)
      su - postgres -c "$psqlbin -U $pgdefaultuser -t -c \"SELECT distinct 'mkdir -p ''' || t.spclocation || '''' FROM pg_catalog.pg_tablespace t where t.spcname<>'pg_default' and t.spcname<>'pg_global';\" $pgdefaultdatabase" > ${DATABASES_TMP_DIR}/create_pgdir.sh
      ;;
esac
su - postgres -c "$pgdumpall -U $pgdefaultuser -l $pgdefaultdatabase --globals-only" > ${DATABASES_TMP_DIR}/PGSQL${BACKUP_TAGFILE}_privileges.dmp
[ $? -ne 0 ] && echo "Flag dump $pgdumpall NOK" && do_mail="0"
echolog "Fin de l'export"
}


dump_mysql()
{
echolog "Début de l'export Mysql"
fulldbs=`echo "show databases" | $mysqlbin ${MYSQL_OPT} -N`
[ $? -ne 0 ] && echo "Connexion mysql NOK" && do_mail="0" && return
dbs=`echo "show databases" | $mysqlbin ${MYSQL_OPT} -N |egrep -v "${DATABASES_EXCLUDE}"`
for db in ${dbs}
do
  echolog "  base : ${db}"
  [ "$test" != "1" ] && $mysqldumpbin ${MYSQL_OPT} -f --opt --databases ${db} > ${DATABASES_TMP_DIR}/MYSQL${BACKUP_TAGFILE}_${db}
  if [ $? -ne 0 ]
    then
      echo "Flag dump ${db} NOK" && do_mail="0"
    else
      gzip ${DATABASES_TMP_DIR}/MYSQL${BACKUP_TAGFILE}_${db}
      if [ $? -ne 0 ]
        then
          echo "Flag gzip dump ${db} NOK" && do_mail="0"
      fi
  fi
done
$mysqlbin ${MYSQL_OPT} --skip-column-names -A -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | $mysqlbin ${MYSQL_OPT} --skip-column-names  -A | sed 's/$/;/g' > ${DATABASES_TMP_DIR}/MYSQL${BACKUP_TAGFILE}_privileges.dmp
echolog "Fin de l'export"
}

dump_mariadb()
{
echolog "Début de l'export Mariadb"
fulldbs=`echo "show databases" | $mariadbbin ${MYSQL_OPT} -N`
[ $? -ne 0 ] && echo "Connexion mariadb NOK" && do_mail="0" && return
dbs=`echo "show databases" | $mariadbbin ${MYSQL_OPT} -N |egrep -v "${DATABASES_EXCLUDE}"`
for db in ${dbs}
do
  echolog "  base : ${db}"
  [ "$test" != "1" ] && $mariadbdumpbin ${MYSQL_OPT} -f --opt --databases ${db} > ${DATABASES_TMP_DIR}/MYSQL${BACKUP_TAGFILE}_${db}
  if [ $? -ne 0 ]
    then
      echo "Flag dump ${db} NOK" && do_mail="0"
    else
      gzip ${DATABASES_TMP_DIR}/MYSQL${BACKUP_TAGFILE}_${db}
      if [ $? -ne 0 ]
        then
          echo "Flag gzip dump ${db} NOK" && do_mail="0"
      fi
  fi
done
$mariadbbin ${MYSQL_OPT} --skip-column-names -A -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | $mariadbbin ${MYSQL_OPT} --skip-column-names  -A | sed 's/$/;/g' > ${DATABASES_TMP_DIR}/MYSQL${BACKUP_TAGFILE}_privileges.dmp
echolog "Fin de l'export"
}

dump_mongo()
{
echolog "Début de l'export Mongo"
mongodumpbin=`which mongodump  2> /dev/null`
[ $? -eq 0 ] && mongodump --out ${DATABASES_TMP_DIR}/
[ $? -ne 0 ] && echo "Flag dump NOK" && do_mail="0"
echolog "Fin de l'export"
}

dump_ldap()
{
echolog "Début de l'export LDAP"
ldapdumpbin=`which slapcat  2> /dev/null`
if [ $? -eq 0 ]
    then
        $ldapdumpbin -b cn=config -l "${DATABASES_TMP_DIR}/LDAP_cn=config.ldif"
        [ $? -ne 0 ] && echo "Flag dump cn=config NOK" && do_mail="0"
        for base in `$ldapdumpbin -b cn=config | egrep "^olcSuffix" | awk -F ":"  '{ print $2}'`; do
            echolog "Backup $base"
            $ldapdumpbin -b "$base" -l "${DATABASES_TMP_DIR}/LDAP${BACKUP_TAGFILE}_${base}.ldif"
            [ $? -ne 0 ] && echo "Flag dump ${base} NOK" && do_mail="0"
        done
    else echolog "Backup NOK" && do_mail="0"
fi
echolog "Fin de l'export"
}

dump_prometheus()
{
which jq > /dev/null 2>&1
if [ $? -eq 0 ] ; then
    if [ -z ${PROMETHEUS_SNAPSHOTS_DIR?} ]; then
    echolog "PROMETHEUS_SNAPSHOTS_DIR non renseigné, backup impossible"&& do_mail="0"
    else
        if [ -z ${PROMETHEUS_URL?} ]; then
        echolog "PROMETHEUS_URL non renseigné, backup impossible"&& do_mail="0"
        else
            echolog "Début du snapshot Prometheus"
            curl -XPOST ${PROMETHEUS_URL}/api/v1/admin/tsdb/snapshot >/tmp/backup_prometheus.txt
            if [ $? -eq 0  ] ; then
                grep success /tmp/backup_prometheus.txt
                if [ $? -eq 0  ] ; then
                    snapshot=$(cat /tmp/backup_prometheus.txt |jq '.data.name' |tr -d '"')
                    tar -czvf ${DATABASES_TMP_DIR}/prometheus_${BACKUP_TAGFILE}.tgz ${PROMETHEUS_SNAPSHOTS_DIR}/$snapshot/
                    rm -rf ${PROMETHEUS_SNAPSHOTS_DIR}/$snapshot
                else
                    echo "Création snapshot Prometheus NOK" && do_mail="0"
                fi
            else
                echo "Création snapshot Prometheus NOK" && do_mail="0"
            fi
        fi
    fi
else
    echolog "jq non installé, dump Prometheus impossible" && do_mail="0"
fi
echolog "Fin de l'export"
}
dump_xenserver()
{
which xe > /dev/null 2>&1
if [ $? -eq 0 ] ; then
    echolog "Début du dump Xenserver"
    xe pool-dump-database file-name=${DATABASES_TMP_DIR}/XEN${BACKUP_TAGFILE}_pool.dmp
    [ $? -ne 0 ] && echo "Flag dump Xen NOK" && do_mail="0"
fi
echolog "Début du dump metadata LVM"
/sbin/vgcfgbackup -f ${DATABASES_TMP_DIR}/LVM${BACKUP_TAGFILE}_%s.dmp
[ $? -ne 0 ] && echo "Flag dump LVM NOK" && do_mail="0"
echolog "Fin de l'export"
}
dump_mongo_one_docker()
{
echolog "Début de l'export Mongo du docker $1"
docker_mongodumpbin=`$dockerbin exec $1 which mongodump  2> /dev/null`
[ $? -eq 0 ] && $dockerbin exec $1 $docker_mongodumpbin -u $2 -p $3 --archive  > ${DATABASES_TMP_DIR}/docker_$1/mongo${BACKUP_TAGFILE}_db.dmp
[ $? -ne 0 ] && echo "Flag dump NOK" && do_mail="0"
gzip ${DATABASES_TMP_DIR}/docker_$1/mongo${BACKUP_TAGFILE}_db.dmp

echolog "Fin de l'export de $1"
}
dump_postgres_one_docker()
{
# Vars
docker_psqlbin=`$dockerbin exec $1 which psql  2> /dev/null`
[ -n "${docker_psqlbin}" ] && docker_psqlversion=`$dockerbin exec -u postgres $1 ${psqlbin} -V | head -n 1 | awk '{ print $NF }' | awk -F "." '{ print $1$2 }'`
docker_pgdumpbin=`$dockerbin exec $1 which pg_dump  2> /dev/null`
docker_pgdumpall=`$dockerbin exec $1 which pg_dumpall  2> /dev/null`

echolog "Début de l'export Postgres du docker $1"
dbs=`$dockerbin exec -u postgres $1 $docker_psqlbin -U $2 -tA -P pager=off -c "SELECT datname FROM pg_database;" $3 |egrep -v "${DATABASES_EXCLUDE}"`
for db in ${dbs}
do
    echolog "  base : ${db}"
    if [ "$test" != "1" ] ; then
        PG_OPT=""
        if [ -z "$full_dayofweek" ] || ([ -n "$full_dayofweek" ] && [ "$today_dayofweek" -eq "$full_dayofweek" ] && [ "$today_dayofmonth" -le 07 ])
            then
                #si une variable $full_dayofweek existe (=si on veut un full que certains jours) ET si c'est le bon jour de la semaine ET si c'est le premier correspondant dans le mois
                #ALORS full backup. Pas de PG_OPT.
                echolog "Performing $1 full backup"
                $dockerbin exec -u postgres $1 $docker_pgdumpbin -U $2 -C -Fc ${db} > ${DATABASES_TMP_DIR}/docker_$1/PGSQL${BACKUP_TAGFILE}_${db}.dmp
            else
                #SINON passage des arguments PG_OPT pour ne pas tout sauvegarder (note : PG_OPT peut être vide et génèrera un full backup...)
               #4blocs pour inclure OU exclure des schemas OU des tables : options stockées dans PG_OPT
                if [ `echo  "${PG_INC_SCHEMA}" | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_INC_SCHEMA} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-n "$i " "}}'`
                fi
                if  [ `echo  "${PG_EXC_SCHEMA}" | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_EXC_SCHEMA} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-N "$i " "}}'`
                fi
                if [ `echo  "${PG_INC_TABLE}"  | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_INC_TABLE} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-t "$i " "}}'`
                fi
                if [ `echo  "${PG_EXC_TABLE}"  | egrep "${db}\."` ] ; then
                    PG_OPT=`echo ${PG_EXC_TABLE} | awk -F "|" '{for(i=1;i<=NF;++i)if($i~/^'$db'\./) {gsub(/^'$db'\./,"",$i); printf "-T "$i " "}}'`
                fi
                echolog "Performing $1 backup with PG_OPT = $PG_OPT"
                $dockerbin exec -u postgres $1 $docker_pgdumpbin -U $2 -C -Fc $PG_OPT ${db} > ${DATABASES_TMP_DIR}/docker_$1/PGSQL${BACKUP_TAGFILE}_${db}.dmp
        fi
        [ $? -ne 0 ] && echo "Flag dump $1 ${db} NOK" && do_mail="0"
        echo
    fi
done
#echo "$docker_psqlversion" >> /tmp/test
case $docker_psqlversion in
   1[1-2][0-9]-*)
      #echo "version ok " >> /tmp/test
      $dockerbin exec -u postgres $1 $docker_psqlbin -U $2 -t -c "SELECT distinct 'mkdir -p ''' || pg_tablespace_location(oid) || '''' FROM pg_tablespace t where t.spcname<>'pg_default' and t.spcname<>'pg_global';" $3 > ${DATABASES_TMP_DIR}/docker_$1/create_pgdir.sh
      ;;
   9[2-9])
      $dockerbin exec -u postgres $1 $docker_psqlbin -U $2 -t -c "SELECT distinct 'mkdir -p ''' || pg_tablespace_location(oid) || '''' FROM pg_tablespace t where t.spcname<>'pg_default' and t.spcname<>'pg_global';" $3 > ${DATABASES_TMP_DIR}/docker_$1/create_pgdir.sh
      ;;
   90|91|[7-8]*)
      $dockerbin exec -u postgres $1 $docker_psqlbin -U $2 -t -c "SELECT distinct 'mkdir -p ''' || t.spclocation || '''' FROM pg_catalog.pg_tablespace t where t.spcname<>'pg_default' and t.spcname<>'pg_global';" $3 > ${DATABASES_TMP_DIR}/docker_$1/create_pgdir.sh
      ;;
esac
$dockerbin exec -u postgres $1 $docker_pgdumpall -U $2 -l $3 --globals-only > ${DATABASES_TMP_DIR}/docker_$1/PGSQL${BACKUP_TAGFILE}_privileges.dmp
[ $? -ne 0 ] && echo "Flag dump $1 $docker_pgdumpall NOK" && do_mail="0"
echolog "Fin de l'export de $1"
}

dump_docker_postgres()
{
echolog "Début de l'export Postgres des docker"
if [ -e "${SCRIPTDIR}/backuprc_docker_postgres" ] ; then
    while IFS=: read -r container container_pgdefaultuser container_pgdefaultdatabase; do
	if [ -z "$container_pgdefaultuser" ]; then
	    container_pgdefaultuser=$pgdefaultuser
	fi
        if [ -z "$container_pgdefaultdatabase" ]; then
            container_pgdefaultdatabase=$pgdefaultdatabase
        fi
        if [ "$(docker ps -aq -f status=running -f name=$container)" ]; then
            mkdir ${DATABASES_TMP_DIR}/docker_$container
            dump_postgres_one_docker $container $container_pgdefaultuser $container_pgdefaultdatabase
        else
            echo "Container $container not running"
            do_mail="0"
        fi
    done <${SCRIPTDIR}/backuprc_docker_postgres
else
    echo "${SCRIPTDIR}/backuprc_docker_postgres not exist"
    do_mail="0"
fi
echolog "Fin de l'export des docker postgres"
}


dump_docker_mongo()
{
echolog "Début de l'export Mongo des docker"
if [ -e "${SCRIPTDIR}/backuprc_docker_mongo" ] ; then
    while IFS=: read -r container container_user container_password; do
        if [ "$(docker ps -aq -f status=running -f name=$container)" ]; then
            mkdir ${DATABASES_TMP_DIR}/docker_$container
            dump_mongo_one_docker $container $container_user $container_password
        else
            echo "Container $container not running"
            do_mail="0"
        fi
    done <${SCRIPTDIR}/backuprc_docker_mongo
else
    echo "${SCRIPTDIR}/backuprc_docker_mongo not exist"
    do_mail="0"
fi
echolog "Fin de l'export des docker mongo"
}

dump_mysql_one_docker()
{
#variables mysql
docker_MYSQL_OPT="--password=$2"
docker_MYSQL_OPT="${docker_all_MYSQL_OPT} --password=$2"
docker_mysqlbin=`$dockerbin exec $1 which mysql 2> /dev/null`
docker_mysqldumpbin=`$dockerbin exec $1 which mysqldump  2> /dev/null`

echolog "Début de l'export Mysql $1"
fulldbs=`echo "show databases" | $dockerbin exec $1 $docker_mysqlbin ${docker_MYSQL_OPT} -N`
[ $? -ne 0 ] && echo "Connexion mysql $1 NOK" && do_mail="0" && return
dbs=`echo "show databases" | $dockerbin exec -i $1 $docker_mysqlbin ${docker_MYSQL_OPT} -N |egrep -v "${DATABASES_EXCLUDE}"`
for db in ${dbs}
do
  echolog "  base : ${db}"
  [ "$test" != "1" ] && $dockerbin exec $1 $docker_mysqldumpbin ${docker_MYSQL_OPT} -f --opt --databases ${db} > ${DATABASES_TMP_DIR}/docker_$1/MYSQL${BACKUP_TAGFILE}_${db}
  if [ $? -ne 0 ]
    then
      echo "Flag dump $1 ${db} NOK" && do_mail="0"
    else
      gzip ${DATABASES_TMP_DIR}/docker_$1/MYSQL${BACKUP_TAGFILE}_${db}
      if [ $? -ne 0 ]
        then
          echo "Flag gzip dump ${db} NOK" && do_mail="0"
      fi
  fi
done
$dockerbin exec $1 $docker_mysqlbin ${docker_MYSQL_OPT} --skip-column-names -A -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | $dockerbin exec -i $1 $docker_mysqlbin ${docker_MYSQL_OPT} --skip-column-names  -A | sed 's/$/;/g' > ${DATABASES_TMP_DIR}/docker_$1/MYSQL${BACKUP_TAGFILE}_privileges.dmp
echolog "Fin de l'export de $1"
}


dump_docker_mysql()
{
echolog "Début de l'export Mysql des docker"
if [ -e "${SCRIPTDIR}/backuprc_docker_mysql" ] ; then
    while IFS=: read -r container container_password; do
        if [ "$(docker ps -aq -f status=running -f name=$container)" ]; then
            mkdir ${DATABASES_TMP_DIR}/docker_$container
            dump_mysql_one_docker $container $container_password
        else
            echo "Container $container not running"
            do_mail="0"
        fi
    done <${SCRIPTDIR}/backuprc_docker_mysql
else
    echo "${SCRIPTDIR}/backuprc_docker_mysql not exist"
    do_mail="0"
fi
echolog "Fin de l'export des docker mysql"
}

dump_mariadb_one_docker()
{
#variables mariadb
docker_MYSQL_OPT="--password=$2"
docker_MYSQL_OPT="${docker_all_MYSQL_OPT} --password=$2"
docker_mariadbbin=`$dockerbin exec $1 which mariadb 2> /dev/null`
docker_mariadbdumpbin=`$dockerbin exec $1 which mariadb-dump  2> /dev/null`

echolog "Début de l'export Mariadb $1"
fulldbs=`echo "show databases" | $dockerbin exec $1 $docker_mariadbbin ${docker_MYSQL_OPT} -N`
[ $? -ne 0 ] && echo "Connexion mariadb $1 NOK" && do_mail="0" && return
dbs=`echo "show databases" | $dockerbin exec -i $1 $docker_mariadbbin ${docker_MYSQL_OPT} -N |egrep -v "${DATABASES_EXCLUDE}"`
for db in ${dbs}
do
  echolog "  base : ${db}"
  [ "$test" != "1" ] && $dockerbin exec $1 $docker_mariadbdumpbin ${docker_MYSQL_OPT} -f --opt --databases ${db} > ${DATABASES_TMP_DIR}/docker_$1/MYSQL${BACKUP_TAGFILE}_${db}
  if [ $? -ne 0 ]
    then
      echo "Flag dump $1 ${db} NOK" && do_mail="0"
    else
      gzip ${DATABASES_TMP_DIR}/docker_$1/MYSQL${BACKUP_TAGFILE}_${db}
      if [ $? -ne 0 ]
        then
          echo "Flag gzip dump ${db} NOK" && do_mail="0"
      fi
  fi
done
$dockerbin exec $1 $docker_mariadbbin ${docker_MYSQL_OPT} --skip-column-names -A -e"SELECT CONCAT('SHOW GRANTS FOR ''',user,'''@''',host,''';') FROM mysql.user WHERE user<>''" | $dockerbin exec -i $1 $docker_mariadbbin ${docker_MYSQL_OPT} --skip-column-names  -A | sed 's/$/;/g' > ${DATABASES_TMP_DIR}/docker_$1/MYSQL${BACKUP_TAGFILE}_privileges.dmp
echolog "Fin de l'export de $1"
}


dump_docker_mariadb()
{
echolog "Début de l'export Mariadb des docker"
if [ -e "${SCRIPTDIR}/backuprc_docker_mariadb" ] ; then
    while IFS=: read -r container container_password; do
        if [ "$(docker ps -aq -f status=running -f name=$container)" ]; then
            mkdir ${DATABASES_TMP_DIR}/docker_$container
            dump_mariadb_one_docker $container $container_password
        else
            echo "Container $container not running"
            do_mail="0"
        fi
    done <${SCRIPTDIR}/backuprc_docker_mariadb
else
    echo "${SCRIPTDIR}/backuprc_docker_mariadb not exist"
    do_mail="0"
fi
echolog "Fin de l'export des docker mariadb"
}

dump_ldap_one_docker()
{
echolog "Début de l'export LDAP du docker $1"
docker_ldapdumpbin=`$dockerbin exec $1 which slapcat  2> /dev/null`
if [ $? -eq 0 ]
    then
        $dockerbin exec $1 $docker_ldapdumpbin -b cn=config > "${DATABASES_TMP_DIR}/docker_$1/LDAP_cn=config.ldif"
        [ $? -ne 0 ] && echo "Flag dump cn=config NOK" && do_mail="0"
        for base in `$dockerbin exec $1 $docker_ldapdumpbin -b cn=config | egrep "^olcSuffix" | awk -F ":"  '{ print $2}'`; do
            echolog "Backup $base"
            $dockerbin exec $1 $docker_ldapdumpbin -b "$base" > "${DATABASES_TMP_DIR}/docker_$1/LDAP${BACKUP_TAGFILE}_${base}.ldif"
            [ $? -ne 0 ] && echo "Flag dump ${base} NOK" && do_mail="0"
        done
    else echolog "Backup NOK" && do_mail="0"
fi
echolog "Fin de l'export de $1"
}

dump_docker_ldap()
{
echolog "Début de l'export LDAP des docker"
if [ -e "${SCRIPTDIR}/backuprc_docker_ldap" ] ; then
    while read container; do
        if [ "$(docker ps -aq -f status=running -f name=$container)" ]; then
            mkdir ${DATABASES_TMP_DIR}/docker_$container
            dump_ldap_one_docker $container
        else
            echo "Container $container not running"
            do_mail="0"
        fi
    done <${SCRIPTDIR}/backuprc_docker_ldap
else
    echo "${SCRIPTDIR}/backuprc_docker_ldap not exist"
    do_mail="0"
fi
echolog "Fin de l'export des docker LDAP"
}


dump_bases()
{
[ -e "${DATABASES_DEST}" ] || mkdir -p "${DATABASES_DEST}"
cd ${DATABASES_DEST}
[ -L latest ] && rm "latest"
mkdir -p ${DATABASES_TMP_DIR}

[ "${mysql}" = "1" ] && dump_mysql
[ "${mariadb}" = "1" ] && dump_mariadb
[ "${postgres}" = "1" ] && dump_postgres
[ "${mongo}" = "1" ] && dump_mongo
[ "${ldap}" = "1" ] && dump_ldap
[ "${xenserver}" = "1" ] && dump_xenserver
[ "${prometheus}" = "1" ] && dump_prometheus
[ "${docker_mysql}" = "1" ] && dump_docker_mysql
[ "${docker_mariadb}" = "1" ] && dump_docker_mariadb
[ "${docker_postgres}" = "1" ] && dump_docker_postgres
[ "${docker_mongo}" = "1" ] && dump_docker_mongo
[ "${docker_ldap}" = "1" ] && dump_docker_ldap

ln -s "${DATABASES_TMP_DIR}" "latest"
}



backup_sites()
{
[ ! -f ${EXCLUDE} ] && echolog "exceptions rsync non definies" && exit 1
if [ ! -d ${FILES_DEST} ] ; then
   echolog "Flag destination NOK"
   else
      #creation des repertoires de backup si besoin initialisation
      for ((a=0; a <= ${nbfiles} ; a++)); do [ -d "${FILES_DEST}/backup.$a" ] || mkdir -p ${FILES_DEST}/backup.$a; done
      if [ $? -ne 0 ]
         then echolog "Flag creation des répertoires NOK"
         else
            #rotation des backups : backup.0 devient backup.1 etc... jusqu'a $nbfiles
            rm -rf ${FILES_DEST}/backup.${nbfiles}
            for ((a=${nbfiles}; a >= 1 ; a--)); do mv ${FILES_DEST}/backup.$(($a-1)) ${FILES_DEST}/backup.$a; done
            if [ $? -ne 0 ]
                  then echolog "Flag rotation des répertoires NOK"
                  else
                     mkdir ${FILES_DEST_0}
                     echolog "Début de synchro"
                     #synchro HOMEWWW_DIR vers $FILES_DEST/backup.0 avec création dans backup.O de hards links si le fichier n'a pas change dans backup.1
                     [ "$test" = "1" ] && RSYNC_TEST="-n"
                     rsync ${RSYNC_OPT} ${RSYNC_TEST} --link-dest=${FILES_DEST}/backup.1/ ${HOMEWWW_DIR}/ ${FILES_DEST_0}
                     [ $? -eq 0 ] || echolog "Flag synchronisation NOK"
                     echolog "Fin de synchro"
            fi
      fi
      du -h --max-depth 1 ${FILES_DEST}/ |grep -v log|sort -dk2
fi
}


rapport_bases()
{
if [ -e "${DATABASES_DEST}" ]
   then
      size=`du -s ${DATABASES_DEST}/latest/| cut -f 1`
      [ $size -lt $size_giga_value ] && { size_unit=M && size_unit_value=$size_mega_value && scale=0;} || { size_unit=G && size_unit_value=$size_giga_value && scale=1;}
      [ $size -lt $size_mega_value ] && { size_unit=K && size_unit_value=$size_kilo_value && scale=0;}
      size=`echo "scale=$scale;$size/$size_unit_value"|bc -l`
      nb=`find ${DATABASES_DEST}/ -maxdepth 1 -name "back_*" -mmin -1200 -type d |wc -l`
      totsize=`du -s ${DATABASES_DEST}/ | cut -f 1`
      [ $totsize -lt $size_giga_value ] && { totsize_unit=M && size_unit_value=$size_mega_value && scale=0;} || { totsize_unit=G && size_unit_value=$size_giga_value && scale=1;}
      [ $totsize -lt $size_mega_value ] && { totsize_unit=K && size_unit_value=$size_kilo_value && scale=0;}
      totsize=`echo "scale=$scale;$totsize/$size_unit_value"|bc -l`
fi
}

rapport_sites()
{
#rapport fichiers
if [ -e "${FILES_DEST_0}" ]
   then
        nbfiles=`find ${FILES_DEST_0} -mtime -1| wc -l`
        totsizefiles=`echo "scale=2;\`du -s ${FILES_DEST_0}/ | cut -f 1\`/$size_unit"|bc -l`
fi
}

rapport()
{
[ "$bases" = "1" ]  && rapport_bases
[ -n "${size}" ] || size="NULL"
[ -n "${nb}" ] || nb="NULL"
[ -n "${totsize}" ] || totsize="NULL"
echo -en "${HOSTNAME_SHORT} ${size}${size_unit} ${totsize}${totsize_unit} ${nb} " > ${REPORT}

[ "$files" = "1" ] && rapport_sites
[ -e "${FILES_DEST_0}" ] || nbfiles="NULL"
[ -n "${totsizefiles}" ] || totsizefiles="NULL"
echo -en "${nbfiles} ${totsizefiles}" >> ${REPORT}

echo >> ${REPORT}
}


clean()
{
if ! $ONEBACKUP
then
  echolog "Cleaning ${DATABASES_DEST}/ with ${clean_argument} :"
  # suppression des anciennes sauvegardes:
  [ "$bases" = "1" ] && find ${DATABASES_DEST}/back_* -maxdepth 0 ${clean_argument} -print -exec rm -rf {} \;
fi
#suppression des rapports et les logs:
[ -d "${REPORTDIR}" ] && find ${REPORTDIR}/rapport_* -maxdepth 1 -mtime +"${nbclean}" -exec rm -f {} \;
find ${LOGDIR}/ -name "${SCRIPTNAME%.*}_*.log" -type f -mtime +"${nbclean}" -exec rm -f {} \;
}

mainjob()
{
lockCheck
clean
[ "$bases" = "1" ] && dump_bases
[ "$files" = "1" ] && backup_sites
[ -d "${REPORTDIR}" ] && rapport
[ "${do_mail}" -eq "0" ] && echolog sendmail && sendMail
}


[ $# -eq "0" ] && usage && exit 0
while [ "$1" != "" ]; do
    case $1 in
        mysql )
                bases=1;mysql=1
                ;;
        mariadb )
                bases=1;mariadb=1
                ;;
        postgres )
                bases=1;postgres=1
                ;;
        mongo )
                bases=1;mongo=1
                ;;
        ldap )
                bases=1;ldap=1
                ;;
        xenserver )
                bases=1;xenserver=1
                ;;
        prometheus )
                bases=1;prometheus=1
                ;;
        files )
                files=1
                ;;
        docker_mysql )
                bases=1;docker_mysql=1
                ;;
        docker_mariadb )
                bases=1;docker_mariadb=1
                ;;
        docker_postgres )
                bases=1;docker_postgres=1
                ;;
        docker_mongo )
                bases=1;docker_mongo=1
                ;;
        docker_ldap )
                bases=1;docker_ldap=1
                ;;
        -t | --test )
                test=1
                ;;
        -1 | --one-backup )
                ONEBACKUP=true
                DATABASES_TMP_DIR="back_latest"
                ;;
        -T | --tag )
                BACKUP_TAGFILE=$2
                shift 1
                ;;
        -s | --screen )
                screen=1
                ;;
        -h | --help )
                usage
                exit
                ;;
        * )     usage
                exit 1
                ;;
    esac
    shift
done


if [ -z "${screen}" ]
  then
    exec 6>&1 7>&2 && exec >> ${LOG} 2>&1
    mainjob
    exec 1>&6 6>&- 2>&7 7>&-
  else
    mainjob
fi

exit 0
